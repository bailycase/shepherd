import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// Commit from review (MobileCommit, iPadCommit boards): the phone's sheet over the changes, and
// the iPad's popover from Commit… beside the docked review and in the full-screen one. The host
// answers the commit's reads (the info and a drafted message, an operation's status); a running
// or finished commit is staged on this device's store, so no screen asks the host to commit.
extension FixtureCatalog {
    static var commit: [FixtureScreen] {
        let ref = FixtureData.ref(FixtureData.preview)
        let thread = MobileRoute.thread(ref)
        let changes = MobileRoute.review(.changes(ref, file: nil))
        return [
            FixtureScreen(name: "commit", hosts: CommitFixture.hosts(), routes: [thread, changes], presented: .review(.commit(ref)),
                          prepare: CommitFixture.drafted),
            FixtureScreen(name: "commit-written", hosts: CommitFixture.hosts(drafts: false), routes: [thread, changes],
                          presented: .review(.commit(ref)), prepare: CommitFixture.writtenWithOneUnticked),
            FixtureScreen(name: "commit-edited", hosts: CommitFixture.hosts(), routes: [thread, changes], presented: .review(.commit(ref)),
                          prepare: CommitFixture.editedWithOneUnticked),
            FixtureScreen(name: "commit-working", hosts: CommitFixture.hosts(working: true), routes: [thread, changes],
                          presented: .review(.commit(ref)), prepare: CommitFixture.drafted),
            FixtureScreen(name: "commit-running", hosts: CommitFixture.hosts(operation: CommitFixture.running), routes: [thread, changes],
                          presented: .review(.commit(ref)), prepare: { app in await CommitFixture.staged(app, CommitFixture.running) }),
            FixtureScreen(name: "commit-done", hosts: CommitFixture.hosts(operation: CommitFixture.done), routes: [thread, changes],
                          presented: .review(.commit(ref)), prepare: { app in await CommitFixture.staged(app, CommitFixture.done) }),
            FixtureScreen(name: "commit-pad", hosts: CommitFixture.hosts(), routes: [thread, changes], prepare: { app in
                await CommitFixture.popover(app)
            }),
            FixtureScreen(name: "commit-pad-full", hosts: CommitFixture.hosts(), routes: [thread, changes], prepare: { app in
                ReviewStores.shared.store(for: ref).padLayout = .full
                await CommitFixture.popover(app)
            }),
        ]
    }
}

enum CommitFixture {
    static let files = [
        RemoteCommitFile(path: "Sources/ShepherdApp/DesktopNativeThreadView.swift", status: "M", added: 58, removed: 41, fingerprint: "a"),
        RemoteCommitFile(path: "App/iOS/FleetView.swift", status: "M", added: 9, removed: 7, fingerprint: "b"),
        RemoteCommitFile(path: "Tests/ShepherdAppTests/NativePresentationTests.swift", status: "A", added: 30, removed: 0, fingerprint: "c"),
    ]

    static func info(working: Bool = false, drafts: Bool = true) -> RemoteCommitInfo {
        let plain = reviewCommitFallbackMessage(files)
        return RemoteCommitInfo(repository: "/Users/dev/Shepherd", branch: "main", head: "abc", upstream: "origin/main", pushRemote: "origin",
                                defaultBranch: "main", files: files, title: plain.title, body: plain.body, draftsMessage: drafts,
                                agentWorking: working, blocked: nil)
    }

    static let title = "Show commands and paths in tool rows"
    static let body = "Tool rows now preview the command or path instead of \u{201C}complete\u{201D}. Adds NativePresentationTests to cover the preview text on macOS and iOS."

    static let operationID = UUID(uuidString: "C0000000-0000-4000-8000-0000000000C1")!
    static let running = RemoteWorktreeOperation(id: operationID, progress: [
        "check the checkout: on main", "commit 3 files: committed 1a2b3c4", "push to origin/main: working…",
    ])
    static let done = RemoteWorktreeOperation(id: operationID, finished: true, progress: [
        "check the checkout: on main", "commit 3 files: committed 1a2b3c4", "push to origin/main: pushed",
    ])

    /// The review's hosts, with Studio also answering the commit's reads for the preview agent.
    static func hosts(working: Bool = false, drafts: Bool = true, operation: RemoteWorktreeOperation? = nil) -> [FixtureHostData] {
        var hosts = ReviewFixture.hosts()
        let review = hosts[0].reply
        hosts[0].reply = { request in
            guard case .agentQuery(let id, let agentID, let query) = request, agentID == FixtureData.preview else { return review?(request) }
            switch query {
            case .commitInfo:
                return .agentResult(id: id, result: .commitInfo(info(working: working, drafts: drafts)))
            case .commitMessage:
                return .agentResult(id: id, result: .commitMessage(title: title, body: body, drafted: true))
            case .worktreeStatus(let requested) where requested == operation?.id:
                return .agentResult(id: id, result: .worktreeOperation(operation!))
            default:
                return review?(request)
            }
        }
        return hosts
    }

    @MainActor static func store(_ app: MobileApp) -> ReviewCommitStore {
        CommitStores.shared.store(for: FixtureData.ref(FixtureData.preview), hosts: app.hosts)
    }

    /// Waits for the host's info and its drafted message.
    @MainActor static func drafted(_ app: MobileApp) async {
        let store = store(app)
        await ReviewFixture.until { store.stage == .form && store.drafted && !store.drafting }
    }

    /// A host that drafts nothing: the message written from the file list, following the ticked
    /// files once one is unticked.
    @MainActor static func writtenWithOneUnticked(_ app: MobileApp) async {
        let store = store(app)
        await ReviewFixture.until { store.stage == .form }
        store.toggle("App/iOS/FleetView.swift")
    }

    /// The drafted message edited, then a file it was drafted for unticked: the message stays and
    /// says it may mention it.
    @MainActor static func editedWithOneUnticked(_ app: MobileApp) async {
        await drafted(app)
        let store = store(app)
        store.body += " FleetView keeps its rows."
        store.toggle("App/iOS/FleetView.swift")
    }

    /// The commit on screen, then `operation` as the host reports it.
    @MainActor static func staged(_ app: MobileApp, _ operation: RemoteWorktreeOperation) async {
        await drafted(app)
        store(app).adopt(operation)
    }

    /// Opens the iPad popover from Commit… once the review's diff is in.
    @MainActor static func popover(_ app: MobileApp) async {
        await ReviewFixture.loaded(ReviewStores.shared.store(for: FixtureData.ref(FixtureData.preview)))
        CommitStores.shared.popover = FixtureData.ref(FixtureData.preview)
        await drafted(app)
    }
}
