import Foundation
import Observation
import Sentry
import ShepherdProtocol
import Synchronization

/// Sentry stays here. Callers supply fixed events and numbers, never errors, paths or prose.
@MainActor
@Observable
final class ShepherdDiagnostics {
    static let shared = ShepherdDiagnostics()
    enum Activity: String {
        case appStarted = "app.started"
        case threadSelected = "thread.selected"
        case processExited = "process.exited"
    }

    enum Failure: String {
        case agentStartFailed = "agent.start_failed"
        case memoryPressure = "resources.memory_pressure"
        case orphanProcesses = "resources.orphan_processes"
    }

    var configured: Bool { endpoint != nil }
    private(set) var isActive = false
    private let endpoint: String?
    private let defaults: UserDefaults
    private let root: URL
    private let configuration: URLSessionConfiguration
    private let gate: DiagnosticsGate
    @ObservationIgnored private var didStart = false
    @ObservationIgnored private var session: URLSession?
    @ObservationIgnored private var options: Options?
    @ObservationIgnored private var samplingTask: Task<Void, Never>?
    @ObservationIgnored private var pressureSource: (any DispatchSourceMemoryPressure)?
    @ObservationIgnored private var pressure = 0.0
    @ObservationIgnored private var samples: [[String: Double]] = []
    @ObservationIgnored private var sampleCount = 0
    @ObservationIgnored private var lastAnomaly: [Failure: TimeInterval] = [:]
    private let traces = DiagnosticsTraces()

    nonisolated static let resourceKeys: Set<String> = [
        "app.rss_bytes", "app.footprint_bytes", "app.cpu_seconds", "pi.count", "pi.rss_bytes", "pi.cpu_seconds",
        "terminal.count", "terminal.rss_bytes", "terminal.cpu_seconds", "descendants.count", "descendants.rss_bytes", "descendants.cpu_seconds",
        "orphans.count", "orphans.rss_bytes", "orphans.cpu_seconds", "process_scan.truncated", "process_scan.failed",
        "pi.max_rss_bytes", "terminal.max_rss_bytes", "descendants.max_rss_bytes", "orphans.max_rss_bytes",
        "process_scan.unreadable", "sessions.active", "sessions.idle", "sessions.total",
        "rpc.buffer_bytes", "transcript.rows", "system.memory_bytes", "system.pressure", "sample.uptime_seconds"
    ]
    nonisolated static let operations: Set<String> = [
        "agent.start", "agent.stop", "history.refresh", "agent.turn", "model.response", "tool.read", "tool.bash",
        "tool.write", "tool.edit", "tool.mcp", "tool.other", "context.compact"
    ]

    init(dsn: String? = Bundle.main.infoDictionary?["ShepherdSentryDSN"] as? String,
         store: UserDefaults = .standard,
         cacheRoot: URL = ShepherdPaths.supportDirectory().appendingPathComponent("diagnostics", isDirectory: true),
         sessionConfiguration: URLSessionConfiguration = .ephemeral) {
        endpoint = Self.dsn(dsn)
        defaults = store
        root = cacheRoot
        configuration = sessionConfiguration
        gate = DiagnosticsGate(store: store)
    }

    func start(settings: AppSettings, resourceSampler: (@Sendable () async -> [String: Double])? = nil) {
        guard !didStart else { return }
        didStart = true
        // Crash replay runs asynchronously against the SDK's current global hub. Never restart
        // it in-process after revocation: an old report could otherwise reach a new client.
        settings.onDiagnosticsChange = { [weak self] enabled in
            if !enabled { self?.stop() }
        }
        guard settings.shareDiagnostics, let endpoint else { stop(); return }
        let cacheID = defaults.string(forKey: "shepherd.diagnostics.cacheID").flatMap(UUID.init(uuidString:)) ?? UUID()
        defaults.set(cacheID.uuidString, forKey: "shepherd.diagnostics.cacheID")
        let directory = root.appendingPathComponent(cacheID.uuidString, isDirectory: true)
        // Enumeration can resolve support-path aliases; identify the active cache by its name.
        // Only our own diagnostics directories, never session or configuration files.
        if let retired = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            for url in retired where url.lastPathComponent != cacheID.uuidString { try? FileManager.default.removeItem(at: url) }
        }
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.protocolClasses = [RevokedDiagnosticsRequest.self] + (configuration.protocolClasses ?? [])
        let transport = URLSession(configuration: configuration)
        session = transport
        gate.setEnabled(true)
        let sdk = Self.makeOptions(dsn: endpoint, cache: directory, session: transport)
        sdk.beforeSend = { [gate, traces] event in
            // SDK 9 sends transactions through beforeSend too (beforeSendTransaction is v10-only).
            if let transaction = event as? Transaction {
                guard gate.isEnabled else { return nil }
                return traces.sanitized(transaction)
            }
            let kind: DiagnosticsGate.Kind = event.tags?["shepherd.failure"]?.hasPrefix("resources.") == true ? .anomaly : .error
            guard gate.accept(kind: kind) else { return nil }
            return Self.sanitized(event)
        }
        let installation = defaults.string(forKey: "shepherd.diagnostics.installation").flatMap(UUID.init(uuidString:)) ?? UUID()
        defaults.set(installation.uuidString, forKey: "shepherd.diagnostics.installation")
        sdk.initialScope = { scope in
            scope.setTag(value: installation.uuidString, key: "shepherd.installation")
            scope.setTag(value: UUID().uuidString, key: "shepherd.run")
            return scope
        }
        options = sdk
        SentrySDK.start(options: sdk)
        isActive = SentrySDK.isEnabled
        record(.appStarted)
        if let resourceSampler, isActive { startSampling(resourceSampler) }
    }

    private func startSampling(_ sampler: @escaping @Sendable () async -> [String: Double]) {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self, self.isActive, let data = self.pressureSource?.data else { return }
            self.pressure = data.contains(.critical) ? 2 : data.contains(.warning) ? 1 : 0
            guard var values = self.samples.last else { return }
            values["system.pressure"] = self.pressure
            self.recordResources(values)
        }
        pressureSource = source
        source.resume()
        samplingTask = Task { [weak self] in
            var budget = DiagnosticsSamplingBudget(startedAt: ProcessInfo.processInfo.systemUptime)
            while !Task.isCancelled, self?.isActive == true, budget.take(at: ProcessInfo.processInfo.systemUptime) {
                let values = await sampler()
                guard !Task.isCancelled, self?.isActive == true else { return }
                self?.recordResources(values)
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
            self?.pressureSource?.cancel()
            self?.pressureSource = nil
        }
    }

    /// Callers provide aggregates, never process names, identifiers, paths, or command lines.
    func recordResources(_ values: [String: Double]) {
        guard isActive else { return }
        var values = Self.resourceValues(values)
        guard !values.isEmpty, gate.accept(kind: .sample) else { return }
        values["sample.uptime_seconds"] = ProcessInfo.processInfo.systemUptime
        values["system.pressure"] = max(values["system.pressure"] ?? 0, pressure)
        samples.append(values)
        if samples.count > 10 { samples.removeFirst(samples.count - 10) }
        let context: [String: Any] = ["samples": samples]
        SentrySDK.configureScope { $0.setContext(value: context, key: "shepherd.resources") }
        if values["system.pressure", default: 0] > 0 { reportAnomaly(.memoryPressure) }
        if values["orphans.count", default: 0] > 0 { reportAnomaly(.orphanProcesses) }
        sampleCount += 1
        // Samples stay local each minute; one numeric transaction every ten samples bounds uploads.
        guard sampleCount % 10 == 1, gate.accept(kind: .resource) else { return }
        sendTrace("resources.sample", seconds: 0, values: values)
    }

    func recordDuration(_ operation: String, seconds: Double) {
        guard isActive, Self.operations.contains(operation), seconds.isFinite, seconds >= 0,
              seconds <= 86_400, gate.accept(kind: .duration, operation: operation) else { return }
        sendTrace(operation, seconds: seconds, values: ["duration.seconds": seconds])
    }

    private func sendTrace(_ operation: String, seconds: Double, values: [String: Double]) {
        let span = SentrySDK.startTransaction(name: operation, operation: "shepherd." + operation, bindToScope: false)
        span.startTimestamp = Date().addingTimeInterval(-seconds)
        for (key, value) in values { span.setMeasurement(name: key, value: NSNumber(value: value)) }
        traces.register(span, operation: operation)
        span.finish()
    }

    private func reportAnomaly(_ failure: Failure) {
        let now = ProcessInfo.processInfo.systemUptime
        guard lastAnomaly[failure].map({ now - $0 >= 600 }) ?? true else { return }
        lastAnomaly[failure] = now
        capture(failure)
    }

    nonisolated static func resourceValues(_ values: [String: Double]) -> [String: Double] {
        values.filter { resourceKeys.contains($0.key) && $0.value.isFinite && $0.value >= 0 }
    }

    private func stop() {
        gate.setEnabled(false)
        samplingTask?.cancel()
        samplingTask = nil
        pressureSource?.cancel()
        pressureSource = nil
        samples.removeAll()
        lastAnomaly.removeAll()
        traces.removeAll()
        options?.enabled = false
        if options != nil {
            RevokedDiagnosticsRequest.revoke()
            session?.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
            SentrySDK.close()
        }
        // ponytail: one revoked session lives until process exit. Invalidating it crashes late
        // SDK callbacks that still create tasks; the protocol rejects them without a socket.
        options = nil
        isActive = false
        // A late SDK write stays in the retired directory and cannot cross into renewed consent.
        defaults.removeObject(forKey: "shepherd.diagnostics.cacheID")
        try? FileManager.default.removeItem(at: root)
    }

    func record(_ activity: Activity, code: Int32? = nil) {
        guard options != nil else { return }
        let crumb = Breadcrumb(level: .info, category: "shepherd")
        crumb.message = activity.rawValue
        if let code { crumb.setData(value: code, key: "exit_code") }
        SentrySDK.addBreadcrumb(crumb)
    }

    func capture(_ failure: Failure, code: Int32? = nil) {
        guard options != nil else { return }
        SentrySDK.capture(message: failure.rawValue) { scope in
            scope.setLevel(.error)
            scope.setTag(value: failure.rawValue, key: "shepherd.failure")
            if let code { scope.setTag(value: String(code), key: "exit_code") }
        }
    }

    nonisolated static func dsn(_ value: String?) -> String? {
        guard let value, let url = URLComponents(string: value), url.scheme == "https",
              let host = url.host, host.hasSuffix(".sentry.io"),
              let key = url.user, !key.isEmpty, url.password == nil,
              url.query == nil, url.fragment == nil, url.port == nil,
              let project = url.path.split(separator: "/").last,
              !project.isEmpty, project.allSatisfy(\.isNumber) else { return nil }
        return value
    }

    nonisolated static func makeOptions(dsn: String, cache: URL, session: URLSession) -> Options {
        let options = Options()
        options.dsn = dsn
        options.cacheDirectoryPath = cache.path
        options.urlSession = session
        options.maxCacheItems = 10
        options.maxBreadcrumbs = 32
        options.shutdownTimeInterval = 0
        options.sendDefaultPii = false
        options.enableMemoryIntrospection = false
        options.enableUncaughtNSExceptionReporting = true
        options.enableAutoBreadcrumbTracking = false
        options.enableNetworkBreadcrumbs = false
        options.enableCaptureFailedRequests = false
        options.enableNetworkTracking = false
        options.enableFileIOTracing = false
        options.enableAutoPerformanceTracing = false
        options.enableAutoSessionTracking = false
        options.enableWatchdogTerminationTracking = false
        options.enableAppHangTracking = true
        options.appHangTimeoutInterval = 5
        options.enableMetricKit = false
        options.enableLogs = false
        options.enableMetrics = false
        options.beforeSendLog = { _ in nil }
        options.beforeSendMetric = { _ in nil }
        options.sendClientReports = false
        // Only explicitly registered, budgeted transactions survive beforeSend.
        options.tracesSampleRate = 1
        options.enableCoreDataTracing = false
        options.environment = ShepherdEdition.current.rawValue
        return options
    }

    /// Rebuild the event rather than forwarding SDK-added context or arbitrary exception text.
    /// Keep image UUIDs/addresses for symbolication; never upload memory contents or source lines.
    /// The SDK's local native crash cache can contain raw stack bytes before this filter runs.
    nonisolated static func sanitized(_ source: Event) -> Event {
        let event = Event(level: source.level)
        event.eventId = source.eventId
        event.timestamp = source.timestamp
        event.releaseName = source.releaseName
        event.dist = source.dist
        event.environment = source.environment
        event.sdk = source.sdk
        event.platform = "cocoa"
        if let failure = source.tags?["shepherd.failure"], Failure(rawValue: failure) != nil {
            event.message = SentryMessage(formatted: failure)
            event.tags = ["shepherd.failure": failure]
            if let code = source.tags?["exit_code"], Int32(code) != nil { event.tags?["exit_code"] = code }
        }
        for key in ["shepherd.installation", "shepherd.run"] {
            if let value = source.tags?[key], let id = UUID(uuidString: value) {
                if event.tags == nil { event.tags = [:] }
                event.tags?[key] = id.uuidString
            }
        }
        event.context = [:]
        for (name, keys) in ["os": ["name", "version", "build", "kernel_version"],
                             "device": ["arch", "model", "family", "memory_size", "free_memory", "processor_count"]] {
            event.context?[name] = source.context?[name]?.filter { keys.contains($0.key) }
        }
        if let values = source.context?["shepherd.resources"]?["samples"] as? [[String: Double]] {
            event.context?["shepherd.resources"] = ["samples": values.suffix(10).map(Self.resourceValues)]
        }
        event.exceptions = Array((source.exceptions ?? []).prefix(8)).map { original in
            let knownTypes = ["EXC_BAD_ACCESS", "EXC_BAD_INSTRUCTION", "EXC_ARITHMETIC", "EXC_BREAKPOINT",
                              "EXC_CRASH", "EXC_RESOURCE", "SIGABRT", "SIGTRAP", "SIGSEGV", "SIGBUS", "SIGILL",
                              "NSInvalidArgumentException", "NSRangeException", "NSInternalInconsistencyException",
                              "App Hanging", "App Hang Fully Blocked", "App Hang Non Fully Blocked",
                              "Fatal App Hang Fully Blocked", "Fatal App Hang Non Fully Blocked"]
            let type = original.type.flatMap { knownTypes.contains($0) ? $0 : nil } ?? "Native crash"
            let exception = Exception(value: nil, type: type)
            exception.threadId = original.threadId
            exception.stacktrace = clean(original.stacktrace)
            if let original = original.mechanism {
                let type = ["mach", "signal", "nsexception", "cpp_exception", "AppHang"].contains(original.type) ? original.type : "generic"
                let mechanism = Mechanism(type: type)
                mechanism.handled = original.handled
                exception.mechanism = mechanism
            }
            return exception
        }
        let threads = source.threads ?? []
        let ordered = threads.filter { $0.crashed == true } + threads.filter { $0.crashed != true }
        event.threads = Array(ordered.prefix(128)).map { original in
            let thread = SentryThread(threadId: original.threadId)
            thread.crashed = original.crashed
            thread.current = original.current
            thread.isMain = original.isMain
            thread.stacktrace = clean(original.stacktrace)
            return thread
        }
        event.stacktrace = clean(source.stacktrace)
        event.debugMeta = Array((source.debugMeta ?? []).prefix(512)).map { original in
            let image = DebugMeta()
            image.debugID = original.debugID
            image.type = original.type
            image.imageSize = original.imageSize
            image.imageAddress = original.imageAddress
            image.imageVmAddress = original.imageVmAddress
            image.codeFile = original.codeFile.map { URL(fileURLWithPath: $0).lastPathComponent }
            return image
        }
        event.breadcrumbs = (source.breadcrumbs ?? []).suffix(32).compactMap { original in
            guard original.category == "shepherd", let message = original.message,
                  Activity(rawValue: message) != nil else { return nil }
            let crumb = Breadcrumb(level: .info, category: "shepherd")
            crumb.message = message
            crumb.timestamp = original.timestamp
            if let code = original.data?["exit_code"] as? Int32 { crumb.setData(value: code, key: "exit_code") }
            return crumb
        }
        return event
    }

    nonisolated private static func clean(_ stack: SentryStacktrace?) -> SentryStacktrace? {
        guard let stack else { return nil }
        // Sentry orders frames oldest first. Retain the faulting end of deep/recursive stacks.
        let frames = stack.frames.suffix(256).map { original in
            let frame = Frame()
            frame.instructionAddress = original.instructionAddress
            frame.symbolAddress = original.symbolAddress
            frame.imageAddress = original.imageAddress
            frame.inApp = original.inApp
            frame.function = original.function.map { String($0.prefix(512)) }
            frame.package = original.package.map { URL(fileURLWithPath: $0).lastPathComponent }
            return frame
        }
        return SentryStacktrace(frames: Array(frames), registers: [:])
    }
}

/// Installed only on Sentry's session. Late SDK work must fail without touching the network.
private final class RevokedDiagnosticsRequest: URLProtocol, @unchecked Sendable {
    private static let revoked = Mutex(false)

    static func revoke() { revoked.withLock { $0 = true } }
    override class func canInit(with request: URLRequest) -> Bool { revoked.withLock { $0 } }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.cancelled)) }
    override func stopLoading() {}
}

/// Shared by SDK callbacks. Consent and the daily budget apply before an event enters its cache.
final class DiagnosticsGate: @unchecked Sendable {
    static let dailyLimit = 50
    private let lock = NSLock()
    private let store: UserDefaults
    private var enabled = false

    init(store: UserDefaults) { self.store = store }

    func setEnabled(_ value: Bool) { lock.withLock { enabled = value } }

    enum Kind: String, CaseIterable {
        case error, resource, duration, anomaly, sample
        var limit: Int {
            switch self { case .error: 50; case .resource: 144; case .duration: 256; case .anomaly: 24; case .sample: 1440 }
        }
        var prefix: String { self == .error ? "shepherd.diagnostics" : "shepherd.diagnostics." + rawValue }
    }

    var isEnabled: Bool { lock.withLock { enabled } }

    func accept(kind: Kind = .error, now: Date = Date(), operation: String? = nil) -> Bool {
        lock.withLock {
            guard enabled else { return false }
            let day = Int(now.timeIntervalSince1970 / 86_400)
            let prefix = kind.prefix
            if store.integer(forKey: prefix + ".day") != day {
                store.set(day, forKey: prefix + ".day")
                store.set(0, forKey: prefix + ".count")
            }
            let count = store.integer(forKey: prefix + ".count")
            guard count < kind.limit else { return false }
            if kind == .duration {
                guard let operation, ShepherdDiagnostics.operations.contains(operation) else { return false }
                let hour = Int(now.timeIntervalSince1970 / 3600)
                if store.integer(forKey: prefix + ".hour") != hour {
                    store.set(hour, forKey: prefix + ".hour")
                    store.set([String: Int](), forKey: prefix + ".operations")
                }
                var counts = store.dictionary(forKey: prefix + ".operations") as? [String: Int] ?? [:]
                // A busy startup cannot spend tomorrow's evidence in its first few minutes.
                guard counts.values.reduce(0, +) < 10, counts[operation, default: 0] < 2 else { return false }
                counts[operation, default: 0] += 1
                store.set(counts, forKey: prefix + ".operations")
            }
            store.set(count + 1, forKey: prefix + ".count")
            return true
        }
    }
}

/// No persisted task resumes after a restart. One launch samples for at most one day.
struct DiagnosticsSamplingBudget {
    static let limit = 1440
    let startedAt: TimeInterval
    private(set) var count = 0

    mutating func take(at uptime: TimeInterval) -> Bool {
        guard uptime.isFinite, uptime >= startedAt, uptime - startedAt < 86_400, count < Self.limit else { return false }
        count += 1
        return true
    }
}

/// Transactions have an internal root span that Event's setters cannot sanitize. Keep only our
/// own handles so the callback can scrub that root too; never accept a third-party transaction.
private final class DiagnosticsTraces: @unchecked Sendable {
    private struct Pending {
        let span: any Span
        let operation: String
        let createdAt: TimeInterval
    }
    private let lock = NSLock()
    private var pending: [String: Pending] = [:]

    func register(_ span: any Span, operation: String) {
        lock.withLock {
            let now = ProcessInfo.processInfo.systemUptime
            pending = pending.filter { now - $0.value.createdAt < 30 }
            guard pending.count < 32 else { return }
            pending[span.traceId.sentryIdString] = Pending(span: span, operation: operation, createdAt: now)
        }
    }

    func removeAll() { lock.withLock { pending.removeAll() } }

    func sanitized(_ source: Transaction) -> Transaction? {
        let serialized = source.serialize()
        guard let contexts = serialized["contexts"] as? [String: Any],
              let trace = contexts["trace"] as? [String: Any], let id = trace["trace_id"] as? String,
              let own = lock.withLock({ pending.removeValue(forKey: id) }),
              ProcessInfo.processInfo.systemUptime - own.createdAt < 30,
              serialized["transaction"] as? String == own.operation else { return nil }
        let measurements = serialized["measurements"] as? [String: [String: Any]] ?? [:]
        let allowed = ShepherdDiagnostics.resourceKeys.union(["duration.seconds"])
        guard measurements.allSatisfy({ name, item in
            guard allowed.contains(name), let number = item["value"] as? NSNumber else { return false }
            return number.doubleValue.isFinite && number.doubleValue >= 0
        }) else { return nil }
        let clean = ShepherdDiagnostics.sanitized(source)
        for key in own.span.data.keys { own.span.removeData(key: key) }
        for key in own.span.tags.keys { own.span.removeTag(key: key) }
        own.span.spanDescription = own.operation
        own.span.operation = "shepherd." + own.operation
        source.tags = clean.tags
        source.context = clean.context
        source.extra = nil
        source.user = nil
        source.request = nil
        source.message = nil
        source.error = nil
        source.logger = nil
        source.serverName = nil
        source.modules = nil
        source.fingerprint = nil
        source.exceptions = nil
        source.stacktrace = nil
        source.threads = nil
        source.debugMeta = nil
        source.breadcrumbs = clean.breadcrumbs
        source.spans = []
        return source
    }
}
