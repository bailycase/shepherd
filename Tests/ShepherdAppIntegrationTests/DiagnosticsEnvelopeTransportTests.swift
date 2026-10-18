import Foundation
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

@Suite("Diagnostics envelope transport", .integrationTimeLimit)
struct DiagnosticsEnvelopeTransportTests {
    @Test func injectedTransportsStayIsolatedAndBothCancellationAndRevocationReachForwardedTasks() async throws {
        let first = URLSessionConfiguration.ephemeral
        first.protocolClasses = [EnvelopeRejectRequest.self, EnvelopeRecordingTransport.self]
        first.httpAdditionalHeaders = ["X-Test-Configuration": "first"]
        let context = DiagnosticsEnvelopeProtocol.configure(on: first, release: "Shepherd@1.2+3", environment: "nightly", allowProfiles: true)
        let session = URLSession(configuration: first)
        defer { context.revoke(); session.invalidateAndCancel() }
        let second = URLSessionConfiguration.ephemeral
        second.protocolClasses = [EnvelopeRejectRequest.self, EnvelopeRecordingTransport.self]
        second.httpAdditionalHeaders = ["X-Test-Configuration": "second"]
        let otherContext = DiagnosticsEnvelopeProtocol.configure(on: second, release: "Shepherd@4.5+6", environment: "dev", allowProfiles: true)
        let otherSession = URLSession(configuration: second)
        defer { otherContext.revoke(); otherSession.invalidateAndCancel() }

        let payload: [String: Any] = ["version": "2", "chunk_id": String(repeating: "a", count: 32),
                                    "profiler_id": String(repeating: "b", count: 32), "release": "PRIVATE_RELEASE", "environment": "PRIVATE_ENVIRONMENT",
                                    "profile": ["frames": [["instruction_addr": "0x1234", "function": "PRIVATE_SYMBOL"]],
                                                "stacks": [[0]], "thread_metadata": ["42": ["name": "PRIVATE_THREAD"]],
                                                "samples": [["timestamp": 1, "thread_id": "42", "stack_id": 0],
                                                            ["timestamp": 2, "thread_id": "42", "stack_id": 0]]]]
        let data = try JSONSerialization.data(withJSONObject: payload)
        var request = URLRequest(url: URL(string: "https://diagnostics.invalid/first")!)
        request.httpMethod = "POST"
        request.httpBody = Data("{\"trace\":{\"user_segment\":\"PRIVATE_SCOPE\"}}\n{\"type\":\"profile_chunk\",\"length\":\(data.count)}\n".utf8) + data
        _ = try await session.data(for: request)
        let captured = try #require(EnvelopeRecordingTransport.requests.withValue { $0.last })
        #expect(captured.value(forHTTPHeaderField: "X-Test-Configuration") == "first")
        #expect(captured.value(forHTTPHeaderField: DiagnosticsEnvelopeProtocol.contextHeader) == nil)
        #expect(!String(decoding: captured.httpBody ?? Data(), as: UTF8.self).contains("PRIVATE"))
        #expect(String(decoding: captured.httpBody ?? Data(), as: UTF8.self).contains("0x1234"))
        #expect(String(decoding: captured.httpBody ?? Data(), as: UTF8.self).contains("Shepherd@1.2+3"))
        #expect(String(decoding: captured.httpBody ?? Data(), as: UTF8.self).contains("nightly"))
        request.url = URL(string: "https://diagnostics.invalid/second")!
        _ = try await otherSession.data(for: request)
        #expect(EnvelopeRecordingTransport.requests.withValue { $0.last?.value(forHTTPHeaderField: "X-Test-Configuration") } == "second")
        let otherBody = String(decoding: EnvelopeRecordingTransport.requests.withValue { $0.last?.httpBody } ?? Data(), as: UTF8.self)
        #expect(otherBody.contains("Shepherd@4.5+6") && otherBody.contains("dev") && !otherBody.contains("Shepherd@1.2+3"))

        let beforeRejected = EnvelopeRecordingTransport.requests.withValue { $0.count }
        request.setValue("yes", forHTTPHeaderField: "X-Reject")
        do { _ = try await session.data(for: request); Issue.record("Forwarding lost the injected revocation guard") }
        catch { #expect((error as? URLError)?.code == .cancelled) }
        #expect(EnvelopeRecordingTransport.requests.withValue { $0.count } == beforeRejected)
        request.setValue(nil, forHTTPHeaderField: "X-Reject")

        request.url = URL(string: "https://diagnostics.invalid/hold")!
        let task = session.dataTask(with: request)
        task.resume()
        try await eventually("the child request to reach the fake transport") {
            EnvelopeRecordingTransport.requests.withValue { $0.last?.url?.path == "/hold" }
        }
        session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        try await eventually("outer cancellation to cancel the forwarded request") { EnvelopeRecordingTransport.cancellations.withValue { $0 > 0 } }

        let count = EnvelopeRecordingTransport.requests.withValue { $0.count }
        let cancelledBeforeRevoke = EnvelopeRecordingTransport.cancellations.withValue { $0 }
        let pending = session.dataTask(with: request)
        pending.resume()
        try await eventually("another held child request") { EnvelopeRecordingTransport.requests.withValue { $0.count > count } }
        context.revoke()
        try await eventually("context revocation to cancel the child session") {
            EnvelopeRecordingTransport.cancellations.withValue { $0 > cancelledBeforeRevoke }
        }
        let beforeLate = EnvelopeRecordingTransport.requests.withValue { $0.count }
        do { _ = try await session.data(for: request); Issue.record("Late work escaped the revoked context") }
        catch { #expect((error as? URLError)?.code == .cancelled) }
        #expect(EnvelopeRecordingTransport.requests.withValue { $0.count } == beforeLate)
        request.url = URL(string: "https://diagnostics.invalid/still-consented")!
        _ = try await otherSession.data(for: request)
        #expect(EnvelopeRecordingTransport.requests.withValue { $0.last?.value(forHTTPHeaderField: "X-Test-Configuration") } == "second")

        let defaultConfiguration = URLSessionConfiguration.ephemeral
        defaultConfiguration.protocolClasses = [EnvelopeRecordingTransport.self]
        let defaultContext = DiagnosticsEnvelopeProtocol.configure(on: defaultConfiguration)
        let defaultSession = URLSession(configuration: defaultConfiguration)
        defer { defaultContext.revoke(); defaultSession.invalidateAndCancel() }
        let beforeUnapproved = EnvelopeRecordingTransport.requests.withValue { $0.count }
        do { _ = try await defaultSession.data(for: request); Issue.record("A cached profile escaped without approval") } catch {}
        #expect(EnvelopeRecordingTransport.requests.withValue { $0.count } == beforeUnapproved)
        var nonProfile = request
        nonProfile.httpBody = Data("{}\n{\"type\":\"session\",\"length\":2}\n{}".utf8)
        _ = try await defaultSession.data(for: nonProfile)
        #expect(EnvelopeRecordingTransport.requests.withValue { $0.count } == beforeUnapproved + 1)

        var attachmentOnly = request
        attachmentOnly.httpBody = Data("{}\n{\"type\":\"attachment\",\"length\":7,\"filename\":\"PRIVATE_FILE\"}\nPRIVATE".utf8)
        let beforeAttachment = EnvelopeRecordingTransport.requests.withValue { $0.count }
        let (_, discarded) = try await defaultSession.data(for: attachmentOnly)
        #expect((discarded as? HTTPURLResponse)?.statusCode == 200, "discarded data is consumed rather than retried")
        #expect(EnvelopeRecordingTransport.requests.withValue { $0.count } == beforeAttachment)

        let beforeMalformed = EnvelopeRecordingTransport.requests.withValue { $0.count }
        request.httpBody = Data("malformed profile".utf8)
        do { _ = try await otherSession.data(for: request); Issue.record("Malformed content escaped filtering") } catch {}
        #expect(EnvelopeRecordingTransport.requests.withValue { $0.count } == beforeMalformed)
    }
}

/// The fallback accepts every request, including bugs: these tests cannot open a socket.
private final class EnvelopeRecordingTransport: URLProtocol, @unchecked Sendable {
    static let requests = Locked<[URLRequest]>([])
    static let cancellations = Locked(0)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while body.count < DiagnosticsEnvelopeFilter.maximumExpandedBytes {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            captured.httpBodyStream = nil
            captured.httpBody = body
        }
        Self.requests.withValue { $0.append(captured) }
        guard request.url?.path != "/hold" else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.cancellations.withValue { $0 += 1 } }
}

private final class EnvelopeRejectRequest: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.value(forHTTPHeaderField: "X-Reject") != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.cancelled)) }
    override func stopLoading() {}
}
