import Foundation
import ShepherdSessions
import Testing
@testable import ShepherdApp

/// Settings ▸ Remote says why the listener couldn't start in one plain sentence; the error
/// itself is only the line's tooltip.
@Suite("Remote listener failures")
struct RemoteListenerFailureTests {
    @Test(arguments: [
        (EADDRINUSE, "Couldn't start: port 7433 is already in use."),
        (EACCES, "Couldn't start: port 7433 needs administrator rights."),
        (EADDRNOTAVAIL, "Couldn't start: this Mac has no network address to serve on."),
        (EHOSTUNREACH, "Couldn't start: this Mac didn't let Shepherd use port 7433."),
    ] as [(Int32, String)])
    func aBindFailureReadsAsOneSentence(code: Int32, sentence: String) {
        let error = SessionServerError.system(call: "bind", errno: code)
        let failure = RemoteListenerFailure(error, port: 7433)
        #expect(failure.sentence == sentence)
        #expect(!failure.sentence.contains("errno"))
        #expect(failure.detail == String(describing: error))
    }

    @Test func aTokenFileFailureNamesTheFileRatherThanTheCall() {
        let chmod = RemoteListenerFailure(SessionServerError.system(call: "chmod", errno: EPERM), port: 7433)
        #expect(chmod.sentence == "Couldn't start: Shepherd couldn't protect its token file.")
        let write = RemoteListenerFailure(CocoaError(.fileWriteNoPermission), port: 7433)
        #expect(write.sentence == "Couldn't start: Shepherd couldn't read or write its token file.")
    }

    @Test func anythingElseStillReadsAsASentence() {
        let failure = RemoteListenerFailure(SessionServerError.conflict("remote listener already running"), port: 7434)
        #expect(failure.sentence == "Couldn't start the listener.")
        #expect(failure.detail.contains("already running"))
    }
}
