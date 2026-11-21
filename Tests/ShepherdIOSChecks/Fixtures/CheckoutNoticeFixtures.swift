import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// A dispatched thread's result as the host frames it (AgentMessageFraming + FleetDispatch.resultMessage), with the
// checkout notice at its end. Made up names only.
extension FixtureCatalog {
    static var checkoutNotice: [FixtureScreen] {
        typealias F = FixtureData
        let result = "[from: Checkout notes on Build Mac, an agent, not the user. Reply with agent_send only if this asks for a reply.] "
            + "Result from Checkout notes on Build Mac:\nUpdated the checkout notes.\n\n"
            + "Branch fleet/checkout-notes: 0 commits ahead of origin/main, not on origin, 0 files changed (+0 -0). "
            + "Uncommitted in the checkout on Build Mac: 1 file (1 modified). Counts include any edits sent with the dispatch."
        let snapshot = ThreadFixtures.rpc(F.snapshot([
            F.user("c1", "Update the checkout notes on Build Mac and tell me when it's done.", at: 0),
            F.assistant("c2", "Sent to Build Mac. I'll pick up its result when it reports back.", at: 5_000),
            F.user("c3", result, at: 90_000),
            F.assistant("c4", "Build Mac finished: the notes changed in its checkout but nothing is committed yet.", at: 95_000),
        ]))
        return [FixtureScreen(name: "thread-checkout-notice", hosts: ThreadFixtures.hosts(preview: snapshot), routes: [.thread(F.ref(F.preview))])]
    }
}
