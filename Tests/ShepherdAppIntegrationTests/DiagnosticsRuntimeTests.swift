import Foundation
@preconcurrency import Sentry
import ShepherdProtocol
import ShepherdTestSupport
import Testing
import zlib
@testable import ShepherdApp

@Suite("Diagnostics runtime", .integrationTimeLimit)
struct DiagnosticsRuntimeTests {
    @Test func reportsAreSanitizedOnTheWireAndRevocationCancelsPendingUploads() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent, \.standardErrorContent]) {
            await completingScenario { try await Self.uploadAndRevoke() }
        }
        if let result, !result.standardErrorContent.isEmpty {
            print(String(decoding: result.standardErrorContent, as: UTF8.self))
        }
        expectScenarioCompleted(result)
    }

    @Test func aRealNativeProfileUsesTheFilteredTransportAndOneDailyCapture() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent, \.standardErrorContent]) {
            await completingScenario { try await Self.profileOnce() }
        }
        if let result, !result.standardErrorContent.isEmpty {
            print(String(decoding: result.standardErrorContent, as: UTF8.self))
        }
        expectScenarioCompleted(result)
    }

    @MainActor private static func profileOnce() async throws {
        let defaults = ScratchDefaults()
        let settings = AppSettings(store: defaults)
        settings.shareDiagnostics = true
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DiagnosticsTransport.self]
        let root = try makeScratchDirectory().appendingPathComponent("diagnostics")
        let diagnostics = ShepherdDiagnostics(dsn: "https://key@o1.ingest.sentry.io/1", store: defaults,
            cacheRoot: root, sessionConfiguration: configuration, releaseName: "shepherd-profile-tests@1.0+1",
            profilingEnabled: true)
        diagnostics.start(settings: settings)
        defer { settings.shareDiagnostics = false }
        #expect(diagnostics.isActive)
        #expect(defaults.integer(forKey: "shepherd.diagnostics.profile.count") == 0, "startup never resumes a profile")
        diagnostics.capture(.orphanProcesses)
        #expect(defaults.integer(forKey: "shepherd.diagnostics.profile.count") == 1)
        SentrySDK.configureScope { scope in
            scope.setEnvironment("PRIVATE_PROFILE_SENTINEL")
            scope.setExtra(value: "PRIVATE_PROFILE_SENTINEL", key: "secret")
        }
        try await eventuallyOnMain("the SDK's single native profile chunk", timeout: .seconds(90), poll: .milliseconds(100)) {
            try !items(ofType: "profile_chunk").isEmpty
        }
        let chunks = try items(ofType: "profile_chunk")
        #expect(chunks.count == 1)
        let chunk = try #require(chunks.first)
        #expect(chunk["release"] as? String == "shepherd-profile-tests@1.0+1")
        #expect(chunk["environment"] as? String == ShepherdEdition.current.rawValue)
        let profile = try #require(chunk["profile"] as? [String: Any])
        #expect((profile["samples"] as? [Any])?.isEmpty == false)
        #expect((profile["frames"] as? [Any])?.isEmpty == false)
        let measurements = try #require(chunk["measurements"] as? [String: Any])
        #expect(measurements["memory_footprint"] != nil && measurements["cpu_usage"] != nil)
        #expect(try DiagnosticsTransport.state.bodies.map(uncompressed).allSatisfy { !$0.contains("PRIVATE_PROFILE_SENTINEL") })
        let restarted = DiagnosticsGate(store: defaults)
        restarted.setEnabled(true)
        #expect(!restarted.accept(kind: .profile), "a restart cannot bypass the daily capture limit")
        settings.shareDiagnostics = false
        #expect(!diagnostics.isActive && !SentrySDK.isEnabled)
    }

    @Test func consentAndConfigurationAreBothRequired() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario {
                try await Self.inert(configured: true)
                try await Self.inert(configured: false)
            }
        }
        expectScenarioCompleted(result)
    }

    @MainActor private static func inert(configured: Bool) throws {
        let defaults = ScratchDefaults()
        let settings = AppSettings(store: defaults)
        settings.shareDiagnostics = !configured
        let root = try makeScratchDirectory().appendingPathComponent("diagnostics")
        let diagnostics = ShepherdDiagnostics(dsn: configured ? "https://key@o1.ingest.sentry.io/1" : nil,
                                              store: defaults, cacheRoot: root)
        diagnostics.start(settings: settings)
        #expect(!diagnostics.isActive && !SentrySDK.isEnabled)
        settings.shareDiagnostics = true
        diagnostics.start(settings: settings)
        #expect(!diagnostics.isActive && !SentrySDK.isEnabled, "consent waits for a new app launch")
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @MainActor private static func uploadAndRevoke() async throws {
        let defaults = ScratchDefaults()
        let settings = AppSettings(store: defaults)
        settings.shareDiagnostics = true
        let scratch = try makeScratchDirectory()
        let backing = scratch.appendingPathComponent("backing", isDirectory: true)
        try FileManager.default.createDirectory(at: backing, withIntermediateDirectories: true)
        let support = scratch.appendingPathComponent("aliased-support", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: support, withDestinationURL: backing)
        let root = support.appendingPathComponent("diagnostics", isDirectory: true)
        let cacheID = UUID()
        defaults.set(cacheID.uuidString, forKey: "shepherd.diagnostics.cacheID")
        let active = root.appendingPathComponent(cacheID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
        let pending = active.appendingPathComponent("pending-report")
        let previousReport = Data("cached private report".utf8)
        try previousReport.write(to: pending)
        let retired = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: retired, withIntermediateDirectories: true)
        try Data("retired private report".utf8).write(to: retired.appendingPathComponent("report"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DiagnosticsTransport.self]
        let diagnostics = ShepherdDiagnostics(dsn: "https://key@o1.ingest.sentry.io/1", store: defaults,
                                              cacheRoot: root, sessionConfiguration: configuration,
                                              releaseName: "shepherd-diagnostics-tests@1.0+1")
        let sampleReply = Locked<CheckedContinuation<[String: Double], Never>?>(nil)
        diagnostics.start(settings: settings, resourceSampler: {
            await withCheckedContinuation { continuation in sampleReply.withValue { $0 = continuation } }
        })
        defer {
            settings.shareDiagnostics = false
            sampleReply.withValue { reply in reply?.resume(returning: [:]); reply = nil }
        }
        try await eventuallyOnMain("the resource sampler to start") { sampleReply.withValue { $0 != nil } }
        #expect(diagnostics.isActive && SentrySDK.isEnabled)
        #expect(!FileManager.default.fileExists(atPath: retired.path))
        #expect(defaults.string(forKey: "shepherd.diagnostics.cacheID") == cacheID.uuidString)
        #expect(FileManager.default.contents(atPath: pending.path) == previousReport,
                "launching through a symlink must preserve the pending crash cache")
        SentrySDK.configureScope { scope in
            scope.addAttachment(Attachment(data: Data("PRIVATE_ATTACHMENT_SENTINEL".utf8), filename: "PRIVATE_FILENAME_SENTINEL.txt"))
            scope.setExtra(value: "PRIVATE_PROMPT_SENTINEL", key: "prompt")
            scope.setTag(value: "PRIVATE_PROMPT_SENTINEL", key: "project")
            scope.setTag(value: "PRIVATE_PROMPT_SENTINEL", key: "failure.category")
            scope.setAttribute(value: "PRIVATE_PROMPT_SENTINEL", key: "tool.kind")
            scope.setAttribute(value: "PRIVATE_PROMPT_SENTINEL", key: "prompt")
            scope.setAttribute(value: "PRIVATE_PROMPT_SENTINEL", key: "exit_code")
            scope.setAttribute(value: "forged", key: "shepherd.private_emission")
            let user = User(userId: "PRIVATE_PROMPT_SENTINEL")
            user.email = "PRIVATE_PROMPT_SENTINEL"
            scope.setUser(user)
        }
        diagnostics.record(.threadSelected)
        diagnostics.capture(.agentStartFailed, code: 2, details: .init(startupKind: .extensionFailed))
        try await eventuallyOnMain("the fake transport to receive a report") { try items(ofType: "event").count == 1 }
        let first = try #require(items(ofType: "event").first)
        let envelope = String(decoding: try JSONSerialization.data(withJSONObject: first), as: UTF8.self)
        #expect(envelope.contains("agent.start_failed") && envelope.contains("thread.selected"))
        #expect(envelope.contains("shepherd.installation") && envelope.contains("shepherd.run"))
        let tags = try #require(first["tags"] as? [String: String])
        #expect(tags["startup.kind"] == "extensionFailed")
        #expect(tags["startup.stage"] == "initialization")
        #expect(tags["failure.category"] == nil)
        #expect(!envelope.contains("PRIVATE_PROMPT_SENTINEL"))
        #expect(try items(ofType: "attachment").isEmpty)
        #expect(!envelope.contains("PRIVATE_ATTACHMENT_SENTINEL") && !envelope.contains("PRIVATE_FILENAME_SENTINEL"))

        diagnostics.recordResources(["app.rss_bytes": 1234, "sessions.total": 2, "PRIVATE_PROMPT_SENTINEL": 123,
                                     "pi.rss_bytes": .infinity, "pi.count": -1])
        diagnostics.recordDuration("agent.start", seconds: 2)
        defaults.set(DiagnosticsGate.Kind.duration.limit, forKey: "shepherd.diagnostics.duration.count")
        diagnostics.recordDuration("agent.start", seconds: 4)
        diagnostics.recordDuration("PRIVATE_PROMPT_SENTINEL", seconds: 1)
        diagnostics.recordDuration("agent.start", seconds: .nan)
        SentrySDK.startTransaction(name: "PRIVATE_PROMPT_SENTINEL", operation: "unowned").finish()
        try await eventuallyOnMain("two allowlisted performance transactions") { try items(ofType: "transaction").count == 2 }
        let performance = try items(ofType: "transaction").map {
            String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self)
        }
        #expect(performance.allSatisfy { !$0.contains("PRIVATE_PROMPT_SENTINEL") })
        #expect(performance.contains { $0.contains("resources.sample") && $0.contains("app.rss_bytes") && $0.contains("1234") })
        #expect(performance.contains { $0.contains("agent.start") && $0.contains("duration.seconds") })
        for data in performance {
            for line in data.split(separator: "\n") {
                guard let payload = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      payload["transaction"] as? String == "agent.start" else { continue }
                let end = try #require(payload["timestamp"] as? Double)
                let start = try #require(payload["start_timestamp"] as? Double)
                #expect(end - start >= 1.9 && end - start < 3)
            }
        }

        diagnostics.record(.processExited, code: 9)
        let outcomes: [ShepherdDiagnostics.Activity] = [.modelFailed, .toolFailed, .modelRetry, .compactionFailed, .extensionFailed]
        for outcome in outcomes {
            let details: DiagnosticFailureDetails = outcome == .toolFailed
                ? .init(category: .other, toolKind: .mcp)
                : outcome == .modelFailed || outcome == .compactionFailed ? .init(category: .rateLimit) : .init()
            diagnostics.record(outcome, details: details)
        }
        // Public names (and a forged ownership attribute) must not authorize SDK callers.
        SentrySDK.logger.info("app.started", attributes: ["prompt": "PRIVATE_PROMPT_SENTINEL", "shepherd.private_emission": "forged"])
        SentrySDK.logger.error("PRIVATE_PROMPT_SENTINEL")
        SentrySDK.metrics.gauge(key: "shepherd.app.rss_bytes", value: 987654321,
                                attributes: ["prompt": "PRIVATE_PROMPT_SENTINEL", "shepherd.private_emission": "forged"])
        SentrySDK.metrics.count(key: "shepherd.app.started", value: 987654321)
        SentrySDK.metrics.distribution(key: "shepherd.agent.start.duration", value: 987654321, unit: .second)
        SentrySDK.startSession()
        SentrySDK.endSession()
        await Task.detached { SentrySDK.flush(timeout: 5) }.value
        let logs = try telemetryItems(ofType: "log")
        let metrics = try telemetryItems(ofType: "trace_metric")
        #expect(logs.count == 4 + outcomes.count)
        for outcome in outcomes {
            #expect(logs.contains { $0["body"] as? String == outcome.rawValue && $0["level"] as? String == "warn" })
            #expect(metrics.contains { $0["name"] as? String == "shepherd." + outcome.rawValue && $0["value"] as? Int == 1 })
        }
        for (body, key, value) in [
            ("agent.start_failed", "startup.kind", "extensionFailed"),
            ("agent.start_failed", "startup.stage", "initialization"),
            ("model.failed", "failure.category", "rateLimit"),
            ("context.compact_failed", "failure.category", "rateLimit"),
            ("tool.failed", "tool.kind", "mcp")
        ] {
            let log = try #require(logs.first { $0["body"] as? String == body })
            let attributes = try #require(log["attributes"] as? [String: [String: Any]])
            #expect(attributes[key]?["value"] as? String == value)
        }
        #expect(logs.filter { $0["body"] as? String == "app.started" }.count == 1)
        #expect(logs.contains { $0["body"] as? String == "process.exited" && $0["level"] as? String == "warn" })
        #expect(logs.contains { $0["body"] as? String == "agent.start_failed" && $0["level"] as? String == "error" })
        #expect(metrics.contains { $0["name"] as? String == "shepherd.app.rss_bytes" && $0["type"] as? String == "gauge" && $0["value"] as? Int == 1234 && $0["unit"] as? String == "byte" })
        #expect(metrics.contains { $0["name"] as? String == "shepherd.agent.start.duration" && $0["type"] as? String == "distribution" && $0["value"] as? Int == 2 && $0["unit"] as? String == "second" })
        #expect(metrics.contains { $0["name"] as? String == "shepherd.agent.start.duration" && $0["value"] as? Int == 4 },
                "duration metrics remain available after the independent trace budget is exhausted")
        #expect(metrics.contains { $0["name"] as? String == "shepherd.app.started" && $0["type"] as? String == "counter" && $0["value"] as? Int == 1 })
        #expect(!metrics.contains { $0["value"] as? Int == 987654321 })
        let metadataKeys: Set<String> = ["sentry.release", "sentry.environment", "shepherd.installation", "shepherd.run"]
        var runs = Set<String>()
        for item in logs + metrics {
            let attributes = try #require(item["attributes"] as? [String: [String: Any]])
            #expect(Set(attributes.keys).isSubset(of: metadataKeys.union(["exit_code", "failure.category", "tool.kind", "startup.kind", "startup.stage"])))
            #expect(attributes["sentry.release"]?["value"] as? String == "shepherd-diagnostics-tests@1.0+1")
            #expect(attributes["sentry.environment"]?["value"] as? String == ShepherdEdition.current.rawValue)
            let run = try #require(attributes["shepherd.run"]?["value"] as? String)
            #expect(UUID(uuidString: run) != nil)
            #expect((attributes["shepherd.installation"]?["value"] as? String).flatMap(UUID.init(uuidString:)) != nil)
            runs.insert(run)
            #expect(item["span_id"] == nil)
        }
        #expect(runs.count == 1, "logs and metrics can be correlated without user identity or session contents")
        let sessions = try items(ofType: "session")
        #expect(sessions.contains { $0["status"] as? String == "exited" })
        for session in sessions {
            #expect((session["sid"] as? String).flatMap(UUID.init(uuidString:)) != nil)
            #expect((session["did"] as? String).flatMap(UUID.init(uuidString:)) != nil)
            let attrs = try #require(session["attrs"] as? [String: Any])
            #expect(Set(attrs.keys).isSubset(of: ["release", "environment"]))
            #expect(attrs["release"] as? String == "shepherd-diagnostics-tests@1.0+1")
            #expect(attrs["environment"] as? String == ShepherdEdition.current.rawValue)
            #expect(Set(session.keys).isSubset(of: ["sid", "did", "init", "started", "timestamp", "duration", "status", "errors", "seq", "attrs", "abnormal_mechanism"]))
        }
        #expect(try items(ofType: "attachment").isEmpty)
        #expect(try DiagnosticsTransport.state.bodies.map(uncompressed).allSatisfy {
            !$0.contains("PRIVATE_PROMPT_SENTINEL") && !$0.contains("shepherd.private_emission")
                && !$0.contains("PRIVATE_ATTACHMENT_SENTINEL") && !$0.contains("PRIVATE_FILENAME_SENTINEL")
        })

        // The unit tests consume full budgets; the real SDK checks the last allowed emission.
        defaults.set(DiagnosticsGate.Kind.log.limit - 1, forKey: "shepherd.diagnostics.log.count")
        defaults.set(DiagnosticsGate.Kind.metric.limit - 1, forKey: "shepherd.diagnostics.metric.count")
        for _ in 0..<3 { diagnostics.record(.threadSelected) }
        await Task.detached { SentrySDK.flush(timeout: 5) }.value
        #expect(try telemetryItems(ofType: "log").count == logs.count + 1)
        #expect(try telemetryItems(ofType: "trace_metric").count == metrics.count + 1)
        #expect(defaults.integer(forKey: "shepherd.diagnostics.log.count") == DiagnosticsGate.Kind.log.limit)
        #expect(defaults.integer(forKey: "shepherd.diagnostics.metric.count") == DiagnosticsGate.Kind.metric.limit)

        defaults.set(0, forKey: "shepherd.diagnostics.metric.count")
        defaults.set(DiagnosticsGate.Kind.durationMetric.limit, forKey: "shepherd.diagnostics.durationMetric.count")
        defaults.set(DiagnosticsGate.Kind.activityMetric.limit, forKey: "shepherd.diagnostics.activityMetric.count")
        diagnostics.recordDuration("agent.start", seconds: 5)
        diagnostics.record(.threadSelected)
        for _ in 0..<10 { diagnostics.recordResources(["app.rss_bytes": 9876]) }
        await Task.detached { SentrySDK.flush(timeout: 5) }.value
        #expect(defaults.integer(forKey: "shepherd.diagnostics.metric.count") == 3,
                "exhausted activity and duration budgets preserve the resource time series")
        #expect(try telemetryItems(ofType: "trace_metric").contains { $0["name"] as? String == "shepherd.app.rss_bytes" && $0["value"] as? Int == 9876 })

        DiagnosticsTransport.state.hold()
        diagnostics.capture(.agentStartFailed, code: 3)
        try await eventuallyOnMain("a pending upload") { try items(ofType: "event").count == 2 }
        let recent = String(decoding: try JSONSerialization.data(withJSONObject: #require(items(ofType: "event").last)), as: UTF8.self)
        let requestsBeforeRevocation = DiagnosticsTransport.state.bodies.count
        #expect(recent.contains("shepherd.resources") && recent.contains("app.rss_bytes"))
        #expect(!recent.contains("PRIVATE_PROMPT_SENTINEL"))
        let stoppedBefore = DiagnosticsTransport.state.stopped
        // Leave budget available so opt-out, not exhaustion, must block subsequent emissions.
        defaults.set(0, forKey: "shepherd.diagnostics.log.count")
        defaults.set(0, forKey: "shepherd.diagnostics.metric.count")
        defaults.set(0, forKey: "shepherd.diagnostics.durationMetric.count")
        defaults.set(0, forKey: "shepherd.diagnostics.activityMetric.count")
        settings.shareDiagnostics = false
        sampleReply.withValue { reply in
            reply?.resume(returning: ["app.rss_bytes": 9999, "PRIVATE_PROMPT_SENTINEL": 1])
            reply = nil
        }
        #expect(!diagnostics.isActive && !SentrySDK.isEnabled)
        #expect(defaults.string(forKey: "shepherd.diagnostics.cacheID") == nil)
        #expect(!FileManager.default.fileExists(atPath: backing.appendingPathComponent("diagnostics").path))
        try await eventuallyOnMain("the pending URLSession task to cancel") { DiagnosticsTransport.state.stopped > stoppedBefore }
        settings.shareDiagnostics = true
        diagnostics.start(settings: settings)
        diagnostics.capture(.agentStartFailed, code: 4)
        diagnostics.recordResources(["app.rss_bytes": 9999])
        diagnostics.recordDuration("agent.stop", seconds: 1)
        diagnostics.record(.threadSelected)
        SentrySDK.logger.info("app.started")
        SentrySDK.metrics.count(key: "shepherd.app.started")
        SentrySDK.startSession()
        SentrySDK.endSession()
        #expect(!diagnostics.isActive && !SentrySDK.isEnabled, "off/on must not restart asynchronous crash replay")
        // Exercise the same protocol configuration as a late SDK request after shutdown.
        // The fake transport is still the fallback, so even a broken guard cannot reach a socket.
        let late = URLSession(configuration: configuration)
        defer { late.invalidateAndCancel() }
        do {
            _ = try await late.data(from: URL(string: "https://o1.ingest.sentry.io/api/1/envelope/")!)
            Issue.record("A request escaped revoked consent")
        } catch {
            #expect((error as? URLError)?.code == .cancelled)
        }
        #expect(DiagnosticsTransport.state.bodies.count == requestsBeforeRevocation)
        #expect(defaults.integer(forKey: "shepherd.diagnostics.log.count") == 0)
        #expect(defaults.integer(forKey: "shepherd.diagnostics.metric.count") == 0)
    }

    private static func telemetryItems(ofType type: String) throws -> [[String: Any]] {
        try items(ofType: type).flatMap { payload in
            try #require(payload["items"] as? [[String: Any]])
        }
    }

    /// Read the actual envelope item type and byte length, not whole-request counts or substrings.
    private static func items(ofType type: String) throws -> [[String: Any]] {
        var result: [[String: Any]] = []
        for body in DiagnosticsTransport.state.bodies {
            let data = Data(try uncompressed(body).utf8)
            var offset = data.startIndex
            func line() throws -> Data {
                let end = try #require(data[offset...].firstIndex(of: 10))
                defer { offset = end + 1 }
                return data.subdata(in: offset..<end)
            }
            _ = try line() // Envelope header.
            while offset < data.endIndex {
                let header = try #require(JSONSerialization.jsonObject(with: line()) as? [String: Any])
                let length = try #require(header["length"] as? Int)
                try #require(length >= 0 && length <= data.endIndex - offset)
                let payload = data.subdata(in: offset..<(offset + length))
                offset += length
                if offset < data.endIndex, data[offset] == 10 { offset += 1 }
                if header["type"] as? String == type {
                    result.append(try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any]))
                }
            }
        }
        return result
    }

    private static func uncompressed(_ data: Data) throws -> String {
        guard data.starts(with: [0x1f, 0x8b]) else { return String(decoding: data, as: UTF8.self) }
        var stream = z_stream()
        try #require(inflateInit2_(&stream, 47, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK)
        defer { inflateEnd(&stream) }
        var output = [UInt8](repeating: 0, count: DiagnosticsEnvelopeFilter.maximumExpandedBytes)
        let result = data.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { destination in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress)
                stream.avail_in = uInt(input.count)
                stream.next_out = destination.bindMemory(to: UInt8.self).baseAddress
                stream.avail_out = uInt(destination.count)
                return inflate(&stream, Z_FINISH)
            }
        }
        try #require(result == Z_STREAM_END)
        return String(decoding: output.prefix(Int(stream.total_out)), as: UTF8.self)
    }
}

/// All requests are intercepted, including unexpected SDK traffic. Nothing reaches a socket.
private final class DiagnosticsTransport: URLProtocol, @unchecked Sendable {
    static let state = Recording()

    final class Recording: @unchecked Sendable {
        private let lock = NSLock()
        private var captured: [Data] = []
        private var cancellations = 0
        private var holding = false
        var bodies: [Data] { lock.withLock { captured } }
        var stopped: Int { lock.withLock { cancellations } }
        func hold() { lock.withLock { holding = true } }
        func append(_ data: Data) -> Bool { lock.withLock { captured.append(data); return holding } }
        func cancel() { lock.withLock { cancellations += 1 } }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while body.count < DiagnosticsEnvelopeFilter.maximumExpandedBytes {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        guard !Self.state.append(body) else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { Self.state.cancel() }
}
