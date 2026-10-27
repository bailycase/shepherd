import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// iPhone Duo's side pane and laptop pose (DuoOpenSidePane, DuoSidePaneTabs, DuoClosedThreadMenu, DuoLaptop, DuoLaptopOpen). Run them
// posed (`run-simulator.sh -f`): `duo-subagents` and `duo-terminal` open (the pane's tabs), `duo-unfold` closed (it unfolds itself),
// `duo-laptop` book held in landscape (the inner display upright, the fold across: the laptop pose).
extension FixtureCatalog {
    static var duo: [FixtureScreen] {
        let review = FixtureData.ref(FixtureData.preview)
        let live = SubagentFixtures.ref(SubagentFixtures.restyle)
        return [
            FixtureScreen(name: "duo-subagents", hosts: SubagentFixtures.hosts(), routes: [.thread(live), .subagents(.list(live))]),
            FixtureScreen(name: "duo-subagent-run", hosts: SubagentFixtures.hosts(),
                          routes: [.thread(live), .subagents(.run(live, runID: SubagentFixtures.worker))]),
            FixtureScreen(name: "duo-terminal", hosts: TerminalFixture.hosts(), routes: [.thread(review)],
                          prepare: { app in await TerminalFixture.show(review, in: app) }),
            FixtureScreen(name: "duo-files", hosts: ReviewFixture.hosts(), routes: [.thread(review), .sidePane(.files(review))]),
            // Closed on Subagents, then unfolded: the pushed screen becomes the open pane's tab beside the thread.
            FixtureScreen(name: "duo-unfold", hosts: SubagentFixtures.hosts(), routes: [.thread(live), .subagents(.list(live))],
                          prepare: { app in await DuoFixtures.unfold(app, thread: live) }),
            // Laptop pose: the arrangement, a draft in its composer; then laid flat, the same thread and draft, its composer a card.
            FixtureScreen(name: "duo-laptop", hosts: ReviewFixture.hosts(), routes: [.thread(review)],
                          prepare: { app in await DuoFixtures.laptop(app, thread: review, flatten: false) }),
            FixtureScreen(name: "duo-laptop-open", hosts: ReviewFixture.hosts(), routes: [.thread(review)],
                          prepare: { app in await DuoFixtures.laptop(app, thread: review, flatten: true) }),
        ]
    }
}

@MainActor
enum DuoFixtures {
    static let draft = "Also render the large size, and keep the Working count when nothing needs you"

    static func unfold(_ app: MobileApp, thread: AgentRef) async {
        let navigator = app.navigator
        FixtureCheck.report("FIXTURE CHECK \(navigator.layout == .phone && navigator.homePath.last == .subagents(.list(thread)) ? "ok" : "FAILED"): closed, Subagents is pushed over the thread")
        print("FIXTURE POSE open")
        fflush(stdout)
        await FixtureCheck.wait("the inner display's layout", seconds: 20) { navigator.layout == .pad }
        let pane = navigator.sidePane
        let shown = navigator.padSelection == thread && navigator.padPath.isEmpty && pane.isOpen && pane.tab == .subagents
        FixtureCheck.report("FIXTURE CHECK \(shown ? "ok" : "FAILED"): unfolded, Subagents is the open pane's tab beside the thread")
    }

    static func laptop(_ app: MobileApp, thread: AgentRef, flatten: Bool) async {
        let navigator = app.navigator
        await FixtureCheck.wait("the laptop arrangement", seconds: 20) { navigator.sidePane.arranged == thread }
        app.threads.store(for: thread).draft = draft
        FixtureCheck.report("FIXTURE CHECK ok: the laptop pose arranges the open thread")
        guard flatten else { return }
        print("FIXTURE POSE open")
        fflush(stdout)
        try? await Task.sleep(for: .seconds(3))
        let kept = navigator.sidePane.arranged == thread && app.threads.store(for: thread).draft == draft
        FixtureCheck.report("FIXTURE CHECK \(kept ? "ok" : "FAILED"): laid flat, the arrangement and its draft stay")
    }
}
