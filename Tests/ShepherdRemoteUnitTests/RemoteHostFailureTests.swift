import Darwin
import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdRemote

/// How a failed connection reads on the Mac's remote hosts and the iOS client's host cards, and
/// whether the client keeps trying on its own.
@Suite("Remote host failure")
struct RemoteHostFailureTests {
    @Test(arguments: [
        (RemoteHostClientError.system(call: "connect", errno: ECONNREFUSED), RemoteHostFailure.Kind.unreachable, true),
        (.system(call: "connect", errno: EHOSTUNREACH), .unreachable, true),
        (.system(call: "connect", errno: ETIMEDOUT), .unreachable, true),
        (.resolveFailed(host: "mini.local"), .unreachable, true),
        (.timeout, .unreachable, true),
        (.disconnected, .lost, true),
        (.system(call: "connect", errno: EISCONN), .other, true),
        (.rejected(code: "unauthenticated", message: "hello required"), .other, true),
        (.rejected(code: RemoteProtocol.unauthorizedCode, message: "bad token"), .tokenRefused, false),
        (.rejected(code: RemoteProtocol.versionMismatchCode, message: "host speaks protocol \(RemoteProtocol.version + 1)"),
         .versionMismatch(hostNewer: true), false),
        (.rejected(code: RemoteProtocol.versionMismatchCode, message: "host speaks protocol \(RemoteProtocol.version - 1)"),
         .versionMismatch(hostNewer: false), false),
        (.rejected(code: RemoteProtocol.versionMismatchCode, message: "another protocol"), .versionMismatch(hostNewer: nil), false),
    ] as [(RemoteHostClientError, RemoteHostFailure.Kind, Bool)])
    func aConnectErrorSaysWhyAndWhetherRetryingCanHelp(error: RemoteHostClientError, kind: RemoteHostFailure.Kind, retries: Bool) {
        let failure = RemoteHostFailure(error)
        #expect(failure.kind == kind)
        #expect(failure.retries == retries)
        #expect(failure.detail == error.description, "the client's own reason stays available")
    }

    @Test func aDroppedConnectionRetries() {
        let failure = RemoteHostFailure(disconnect: "host closed the connection")
        #expect(failure.kind == .lost)
        #expect(failure.retries)
        #expect(failure.detail == "host closed the connection")
    }

    @Test func anErrorFromOutsideTheClientIsKeptAsItsDetail() {
        let failure = RemoteHostFailure(CocoaError(.fileReadNoPermission))
        #expect(failure.kind == .other)
        #expect(failure.retries)
    }

    @Test(arguments: [RemoteHostFailure.Kind.tokenMissing, .tokenUnreadable])
    func aTokenTheClientCannotSendWaitsForTheUser(kind: RemoteHostFailure.Kind) {
        #expect(!RemoteHostFailure(kind: kind, detail: "").retries)
    }

    /// The sentence names the host and never shows the client's technical reason.
    @Test(arguments: [RemoteHostFailure.Kind.unreachable, .lost, .tokenRefused, .versionMismatch(hostNewer: true),
                      .versionMismatch(hostNewer: false), .versionMismatch(hostNewer: nil), .other])
    func theMessageNamesTheHostWithoutTheTechnicalReason(kind: RemoteHostFailure.Kind) {
        let failure = RemoteHostFailure(kind: kind, detail: "connect failed: Connection refused (errno 61)")
        let message = failure.message(host: "QA Mac")
        #expect(message.contains("QA Mac"))
        #expect(!message.contains("errno"))
    }

    @Test func eachWayOfFailingReadsDifferently() {
        let kinds: [RemoteHostFailure.Kind] = [.unreachable, .lost, .tokenRefused, .versionMismatch(hostNewer: true),
                                               .versionMismatch(hostNewer: false), .versionMismatch(hostNewer: nil),
                                               .tokenMissing, .tokenUnreadable, .other]
        let messages = Set(kinds.map { RemoteHostFailure(kind: $0, detail: "").message(host: "QA Mac") })
        #expect(messages.count == kinds.count)
        let headlines = [RemoteHostFailure.Kind.unreachable, .tokenRefused, .versionMismatch(hostNewer: nil), .tokenMissing, .tokenUnreadable]
            .map(\.headline)
        #expect(Set(headlines).count == headlines.count)
        #expect(RemoteHostFailure.Kind.lost.headline == RemoteHostFailure.Kind.unreachable.headline)
    }

    @Test(arguments: [("host speaks protocol 3", 3 as Int?), ("host speaks protocol", nil), ("", nil)])
    func theHostsVersionIsReadFromItsRefusal(message: String, version: Int?) {
        #expect(RemoteHostFailure.hostVersion(message) == version)
    }
}
