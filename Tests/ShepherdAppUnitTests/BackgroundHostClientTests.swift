import Darwin
import Testing
@testable import ShepherdApp
import ShepherdSessions

/// Who owns the workspace when the app may be the background host's client.
@Suite("Background host start")
struct BackgroundHostClientTests {
    @Test func theStartPicksTheHostThenTheAppAndWaitsOutAHostStarting() throws {
        var owned = 0
        #expect(try BackgroundHostClient.choose(answers: { true }, own: { owned += 1 }, wait: {}) == .host)
        #expect(owned == 0, "the app never takes the lock from a host that answers")
        #expect(try BackgroundHostClient.choose(answers: { false }, own: { owned += 1 }, wait: {}) == .app)
        #expect(owned == 1)

        // The lock is held but the socket is silent: asked again until it answers.
        var asked = 0
        let inUse = SessionServerError.system(call: "bind", errno: EADDRINUSE)
        #expect(try BackgroundHostClient.choose(answers: { asked += 1; return asked == 3 }, own: { throw inUse }, wait: {}) == .host)
        #expect(throws: BackgroundHostClient.HostStarting.self) {
            try BackgroundHostClient.choose(answers: { false }, own: { throw inUse }, wait: {}, attempts: 2)
        }
        // With the service on, a host launchd is still starting is waited for before the app owns anything.
        asked = 0
        #expect(try BackgroundHostClient.choose(answers: { asked += 1; return asked == 4 }, own: { owned += 1 }, wait: {}, waitFirst: true) == .host)
        #expect(owned == 1, "the app never took the lock")
        #expect(try BackgroundHostClient.choose(answers: { false }, own: { owned += 1 }, wait: {}, attempts: 2, waitFirst: true) == .app)
        #expect(owned == 2, "a host that never answers leaves the app in process")
        // Any other start failure is the app's own, as before.
        #expect(throws: SessionServerError.self) {
            try BackgroundHostClient.choose(answers: { false }, own: { throw SessionServerError.system(call: "listen", errno: EACCES) }, wait: {})
        }
    }
}
