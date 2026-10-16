import Foundation
import Sentry
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
                                              cacheRoot: root, sessionConfiguration: configuration)
        diagnostics.start(settings: settings)
        defer { settings.shareDiagnostics = false }
        #expect(diagnostics.isActive && SentrySDK.isEnabled)
        #expect(!FileManager.default.fileExists(atPath: retired.path))
        #expect(defaults.string(forKey: "shepherd.diagnostics.cacheID") == cacheID.uuidString)
        #expect(FileManager.default.contents(atPath: pending.path) == previousReport,
                "launching through a symlink must preserve the pending crash cache")
        SentrySDK.configureScope { scope in
            scope.setExtra(value: "PRIVATE_PROMPT_SENTINEL", key: "prompt")
            scope.setTag(value: "PRIVATE_PROMPT_SENTINEL", key: "project")
        }
        diagnostics.record(.threadSelected)
        diagnostics.capture(.agentStartFailed, code: 2)
        try await eventuallyOnMain("the fake transport to receive a report") { DiagnosticsTransport.state.bodies.count == 1 }
        let first = try #require(DiagnosticsTransport.state.bodies.first)
        let envelope = try uncompressed(first)
        #expect(envelope.contains("agent.start_failed") && envelope.contains("thread.selected"))
        #expect(envelope.contains("shepherd.installation") && envelope.contains("shepherd.run"))
        #expect(!envelope.contains("PRIVATE_PROMPT_SENTINEL"))

        DiagnosticsTransport.state.hold()
        diagnostics.capture(.agentStartFailed, code: 3)
        try await eventuallyOnMain("a pending upload") { DiagnosticsTransport.state.bodies.count == 2 }
        let stoppedBefore = DiagnosticsTransport.state.stopped
        settings.shareDiagnostics = false
        #expect(!diagnostics.isActive && !SentrySDK.isEnabled)
        #expect(defaults.string(forKey: "shepherd.diagnostics.cacheID") == nil)
        #expect(!FileManager.default.fileExists(atPath: backing.appendingPathComponent("diagnostics").path))
        try await eventuallyOnMain("the pending URLSession task to cancel") { DiagnosticsTransport.state.stopped > stoppedBefore }
        settings.shareDiagnostics = true
        diagnostics.start(settings: settings)
        diagnostics.capture(.agentStartFailed, code: 4)
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
        #expect(DiagnosticsTransport.state.bodies.count == 2)
    }

    private static func uncompressed(_ data: Data) throws -> String {
        guard data.starts(with: [0x1f, 0x8b]) else { return String(decoding: data, as: UTF8.self) }
        var stream = z_stream()
        try #require(inflateInit2_(&stream, 47, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK)
        defer { inflateEnd(&stream) }
        var output = [UInt8](repeating: 0, count: 1024 * 1024)
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
            while body.count < 1024 * 1024 {
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
