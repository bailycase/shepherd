import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

extension FixtureCatalog {
    /// Thread links (ThreadLinkA) on the phone and iPad: the sent message links a thread, the reply names Studio's other threads as chips (a gone one is its words),
    /// and "@" in the composer offers "Link a thread".
    static var threadLinks: [FixtureScreen] {
        let thread = FixtureData.ref(FixtureData.preview)
        return [
            FixtureScreen(name: "thread-links", hosts: ThreadFixtures.hosts(preview: ThreadLinkFixture.snapshot()), routes: [.thread(thread)]),
            FixtureScreen(name: "thread-links-mention", hosts: ThreadFixtures.hosts(preview: ThreadLinkFixture.snapshot()), routes: [.thread(thread)],
                          prepare: ThreadLinkFixture.mention),
        ]
    }
}

enum ThreadLinkFixture {
    typealias F = FixtureData

    /// The reply names the host's threads by id, as agent_list gives them.
    static func snapshot() -> NativeThreadSnapshot {
        F.snapshot([
            // What the @ picker writes, sent: a chip in the bubble; the rest as typed.
            F.user("m1", "Before you change the review pane, check what [Dock review pane](shepherd-thread://\(F.dock.rawValue)) "
                + "and the other threads are doing. **Don't** fight them."),
            F.assistant("m2", """
                [the extensions thread](shepherd-thread://\(F.extensions.rawValue)) is changing the pane's toolbar right now, so I'll \
                rebase on its branch once it lands.

                [dock](shepherd-thread://\(F.dock.rawValue)) is waiting on you to pick which checkout to keep, and \
                [the deletion fix](shepherd-thread://\(F.deletion.rawValue)) is done. [An old thread](shepherd-thread://agent-gone) \
                is gone, so its link is just words.
                """, at: 60_000),
        ])
    }

    /// "@re" typed: the threads whose titles hold it.
    @MainActor static func mention(_ app: MobileApp) async {
        let store = app.threads.store(for: F.ref(F.preview))
        await FixtureWindows.wait("the thread", seconds: 20) { !store.rows.isEmpty }
        store.draft = "Before you touch the pane, check @re"
        try? await Task.sleep(for: .seconds(1))
    }
}
