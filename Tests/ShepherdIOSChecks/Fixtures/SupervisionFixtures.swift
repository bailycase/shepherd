import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

extension FixtureCatalog {
    static var supervision: [FixtureScreen] {
        let ref = FixtureData.ref(FixtureData.preview)
        let waiting = FixtureData.ref(FixtureData.dock)
        return [
            FixtureScreen(name: "supervision-home", hosts: supervisionHosts(), prepare: { app in
                if app.navigator.layout == .pad { app.navigator.padColumns = .detailOnly }
                await HomeFeed.of(app.hosts).refresh()
                if HomeFeed.of(app.hosts).supervisionQueues.review.first?.agentRef != ref {
                    FixtureCheck.fail("The oldest changed Done thread is not first in the review queue")
                }
                if app.navigator.layout == .pad { await OverviewFitCheck.run(app) }
            }),
            FixtureScreen(name: "supervision-inbox", hosts: supervisionHosts(), routes: [.home(.needsYou)], prepare: { app in
                await HomeFeed.of(app.hosts).refresh()
            }),
            FixtureScreen(name: "supervision-thread", hosts: supervisionHosts(), routes: [.home(.needsYou)], prepare: { app in
                await HomeFeed.of(app.hosts).refresh()
                app.navigator.openNextNeedingYou(hosts: app.hosts)
                if app.navigator.selectedThread != waiting { FixtureCheck.fail("Next did not open the oldest blocked thread") }
            }),
            FixtureScreen(name: "supervision-review", hosts: supervisionHosts(), prepare: { app in
                await openReview(app, ref: ref)
                // Exercise advancement without a host mutation; keep the first review on screen for the render.
                let other = FixtureData.ref(FixtureData.deletion)
                if app.navigator.finishQueuedReview(other, hosts: app.hosts) || app.navigator.selectedThread != ref {
                    FixtureCheck.fail("An unrelated completion advanced the review queue")
                }
                let navigator = app.navigator
                if navigator.layout == .phone {
                    // The NavigationStack binding changes directly on a back-swipe.
                    navigator.homePath.removeLast()
                } else {
                    navigator.sidePane.isOpen = false
                }
                ReviewHooks.open(thread: ref, file: nil, navigator: navigator)
                if navigator.finishQueuedReview(ref, hosts: app.hosts) || navigator.selectedThread != ref {
                    FixtureCheck.fail("Reopening Changes manually advanced an abandoned review queue")
                }
                if navigator.layout == .phone { navigator.homePath.removeLast() }
                app.navigator.openReviewQueue(hosts: app.hosts)
                let queued = navigator.queuedReview
                let path = navigator[path: navigator.tab]
                let targets = HomeFeed.of(app.hosts).supervisionQueues.review
                let advanced = navigator.finishQueuedReview(ref, hosts: app.hosts)
                if !advanced || navigator.selectedThread != other || navigator.queuedReview != other {
                    FixtureCheck.fail("Finishing review did not advance: queued=\(String(describing: queued)), phonePath=\(path), targets=\(targets), selected=\(String(describing: navigator.selectedThread))")
                }
                app.navigator.popToRoot()
                app.navigator.open(.thread(ref))
                ReviewHooks.open(thread: ref, file: nil, navigator: app.navigator)
            }),
            FixtureScreen(name: "supervision-commit", hosts: supervisionHosts(), prepare: { app in
                await openReview(app, ref: ref)
                if app.navigator.layout == .pad { app.navigator.commitPopover = ref }
                else { app.navigator.present(.review(.commit(ref))) }
                await CommitFixture.drafted(app)
            }),
        ]
    }

    private static func openReview(_ app: MobileApp, ref: AgentRef) async {
        await HomeFeed.of(app.hosts).refresh()
        app.navigator.openReviewQueue(hosts: app.hosts)
        if app.navigator.selectedThread != ref { FixtureCheck.fail("Review queue did not open its oldest thread") }
        await ReviewFixture.loaded(ChangesFixture.store)
    }

    private static func supervisionHosts() -> [FixtureHostData] {
        var host = ChangesFixture.hosts()[0]
        let space = Space(name: "acme-web", path: "/fixture/acme-web")
        host.name = "Demo Mac"
        host.state.spaces = [space]
        host.state.automations = []
        // Keep the fixture read-only when the queue jumps away from a completed thread.
        host.capabilities = host.defaultCapabilities.filter { $0 != RemoteProtocol.completionSeenCapability }
        let names: [AgentID: String] = [
            FixtureData.preview: "Add refund events", FixtureData.extensions: "Confirm cache policy",
            FixtureData.dock: "Approve rollout plan", FixtureData.deletion: "Tighten retry limits",
        ]
        let now = Date().timeIntervalSince1970 * 1000
        for index in host.state.agents.indices {
            var agent = host.state.agents[index]
            agent.spaceID = space.id
            agent.name = names[agent.id] ?? agent.name
            if agent.id == FixtureData.preview || agent.id == FixtureData.deletion {
                agent.status = .done
                agent.checkout = AgentCheckout(branch: agent.worktreeBranch ?? "main", changedFiles: agent.id == FixtureData.preview ? 5 : 2)
                agent.lastActiveAt = now - (agent.id == FixtureData.preview ? 240_000 : 60_000)
                agent.completedAt = agent.lastActiveAt
                if var thread = host.threads[agent.id], let old = thread.messages.last?.timestamp, let active = agent.lastActiveAt {
                    let delta = active - old
                    thread.messages = thread.messages.map { message in
                        var message = message
                        message.timestamp = message.timestamp.map { $0 + delta }
                        message.startedAt = message.startedAt.map { $0 + delta }
                        return message
                    }
                    host.threads[agent.id] = thread
                }
            } else {
                agent.status = .blocked
                agent.lastActiveAt = now - (agent.id == FixtureData.dock ? 600_000 : 120_000)
                agent.waitingOn = agent.id == FixtureData.dock ? "Approve a gradual rollout?" : "Which cache policy should we use?"
                let offset = (agent.lastActiveAt ?? now) - FixtureData.start
                host.threads[agent.id] = FixtureData.snapshot([
                    FixtureData.user("request", "Prepare the next release for acme-web.", at: offset - 1000),
                    FixtureData.assistant("proposal", agent.waitingOn ?? "Ready when you are.", at: offset),
                ])
            }
            host.state.agents[index] = agent
        }
        return [host]
    }
}
