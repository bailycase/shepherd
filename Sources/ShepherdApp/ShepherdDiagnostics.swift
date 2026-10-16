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

    func start(settings: AppSettings) {
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
        sdk.beforeSend = { [gate] event in
            guard gate.accept() else { return nil }
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
    }

    private func stop() {
        gate.setEnabled(false)
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
        options.enableAppHangTracking = false
        options.enableMetricKit = false
        options.enableLogs = false
        options.enableMetrics = false
        options.sendClientReports = false
        options.tracesSampleRate = 0
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
        event.exceptions = Array((source.exceptions ?? []).prefix(8)).map { original in
            let knownTypes = ["EXC_BAD_ACCESS", "EXC_BAD_INSTRUCTION", "EXC_ARITHMETIC", "EXC_BREAKPOINT",
                              "EXC_CRASH", "EXC_RESOURCE", "SIGABRT", "SIGTRAP", "SIGSEGV", "SIGBUS", "SIGILL",
                              "NSInvalidArgumentException", "NSRangeException", "NSInternalInconsistencyException"]
            let type = original.type.flatMap { knownTypes.contains($0) ? $0 : nil } ?? "Native crash"
            let exception = Exception(value: nil, type: type)
            exception.threadId = original.threadId
            exception.stacktrace = clean(original.stacktrace)
            if let original = original.mechanism {
                let type = ["mach", "signal", "nsexception", "cpp_exception"].contains(original.type) ? original.type : "generic"
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

    func accept(now: Date = Date()) -> Bool {
        lock.withLock {
            guard enabled else { return false }
            let day = Int(now.timeIntervalSince1970 / 86_400)
            if store.integer(forKey: "shepherd.diagnostics.day") != day {
                store.set(day, forKey: "shepherd.diagnostics.day")
                store.set(0, forKey: "shepherd.diagnostics.count")
            }
            let count = store.integer(forKey: "shepherd.diagnostics.count")
            guard count < Self.dailyLimit else { return false }
            store.set(count + 1, forKey: "shepherd.diagnostics.count")
            return true
        }
    }
}
