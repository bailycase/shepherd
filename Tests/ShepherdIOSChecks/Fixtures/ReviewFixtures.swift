import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// Review track's screens: the changes, the diff reader, the iPad review docked and full screen
// (unified and side by side), and Finalize. The host answers the review's reads (the diff, the
// worktree checks and info, an operation's status); every screen state beyond that (comments,
// viewed files, a selected line, a running operation) is set on this device's stores.
extension FixtureCatalog {
    static var review: [FixtureScreen] {
        let ref = FixtureData.ref(FixtureData.preview)
        let thread = MobileRoute.thread(ref)
        let changes = MobileRoute.review(.changes(ref, file: nil))
        return [
            FixtureScreen(name: "review", hosts: ReviewFixture.hosts(), routes: [thread, changes], prepare: ReviewFixture.annotate),
            FixtureScreen(name: "diff", hosts: ReviewFixture.hosts(),
                          routes: [thread, changes, .review(.diff(ref, path: ReviewFixture.fleet))], prepare: { app in
                              await ReviewFixture.annotate(app)
                              await ReviewFixture.selectLine(app)
                          }),
            FixtureScreen(name: "review-comment", hosts: ReviewFixture.hosts(),
                          routes: [thread, changes, .review(.diff(ref, path: ReviewFixture.fleet))], prepare: { app in
                              await ReviewFixture.annotate(app)
                              await ReviewFixture.selectLine(app, draft: "Keep the row's padding at 12.")
                          }),
            FixtureScreen(name: "review-full", hosts: ReviewFixture.hosts(), routes: [thread, changes], prepare: { app in
                await ReviewFixture.annotate(app)
                ReviewStores.shared.store(for: ref).padLayout = .full
            }),
            FixtureScreen(name: "review-split", hosts: ReviewFixture.hosts(), routes: [thread, changes], prepare: { app in
                await ReviewFixture.annotate(app)
                let store = ReviewStores.shared.store(for: ref)
                store.padLayout = .full
                store.diffStyle = .split
            }),
            FixtureScreen(name: "review-pr", hosts: ReviewFixture.hosts(), routes: [thread, changes], prepare: { app in
                let store = ReviewStores.shared.store(for: ref)
                await ReviewFixture.loaded(store)
                store.pullRequest = true
                await ReviewFixture.until { store.filesArePR && !store.loading }
            }),
            FixtureScreen(name: "review-empty", hosts: ReviewFixture.hosts(files: []), routes: [thread, changes]),
            FixtureScreen(name: "review-worktree", hosts: ReviewFixture.hosts(worktree: true), routes: [thread, changes],
                          prepare: ReviewFixture.annotate),
            FixtureScreen(name: "finalize", hosts: ReviewFixture.hosts(worktree: true), routes: [thread, changes],
                          presented: .review(.finalize(ref)), prepare: { _ in
                              let store = ReviewStores.shared.store(for: ref).finalize
                              await ReviewFixture.until { store.stage == .form && store.includedCommits != nil && !store.generating }
                          }),
            FixtureScreen(name: "finalize-setup", hosts: ReviewFixture.hosts(worktree: true, checksPass: false), routes: [thread, changes],
                          presented: .review(.finalize(ref)), prepare: { _ in
                              let store = ReviewStores.shared.store(for: ref).finalize
                              await ReviewFixture.until { store.stage == .setup }
                          }),
            FixtureScreen(name: "finalize-running", hosts: ReviewFixture.hosts(worktree: true, operation: ReviewFixture.running),
                          routes: [thread, changes], presented: .review(.finalize(ref)), prepare: { _ in
                              ReviewStores.shared.store(for: ref).finalize.adopt(ReviewFixture.running)
                          }),
            FixtureScreen(name: "finalize-done", hosts: ReviewFixture.hosts(worktree: true, operation: ReviewFixture.done),
                          routes: [thread, changes], presented: .review(.finalize(ref)), prepare: { _ in
                              ReviewStores.shared.store(for: ref).finalize.adopt(ReviewFixture.done)
                          }),
        ]
    }
}

enum ReviewFixture {
    static let fleet = "App/iOS/FleetView.swift"
    static let branch = "feat/live-preview"

    /// The boards' change: the thread view's labels, FleetView's host rows, the iOS thread view,
    /// and a new test file.
    static let diff = """
    diff --git a/Sources/ShepherdApp/DesktopNativeThreadView.swift b/Sources/ShepherdApp/DesktopNativeThreadView.swift
    --- a/Sources/ShepherdApp/DesktopNativeThreadView.swift
    +++ b/Sources/ShepherdApp/DesktopNativeThreadView.swift
    @@ -88,9 +88,7 @@ struct DesktopNativeThreadView: View {
         var body: some View {
             VStack(alignment: .leading, spacing: 12) {
    -            Text(message.role == "user" ? "You" : "Agent")
    -                .font(.caption.weight(.semibold))
    -                .foregroundStyle(.secondary)
    +            // Speaker labels are gone: fills tell the turns apart.
                 content
                     .textSelection(.enabled)
             }
    @@ -141,6 +139,9 @@ struct DesktopNativeThreadView: View {
         private func toolRow(_ call: ToolCall) -> some View {
             HStack(spacing: 8) {
                 Image(systemName: call.symbol)
    -            Text("complete")
    +            Text(call.preview ?? call.name)
    +                .font(.system(.caption, design: .monospaced))
    +                .lineLimit(1)
             }
         }
    diff --git a/App/iOS/FleetView.swift b/App/iOS/FleetView.swift
    --- a/App/iOS/FleetView.swift
    +++ b/App/iOS/FleetView.swift
    @@ -12,23 +12,9 @@ struct FleetView: View {
       let connected = connection.phase == .connected
       NavigationStack(path: $path) {
         List {
    -      Section {
    -        if let configuration = connection.configuration {
    -          HStack(spacing: 12) {
    -            Image(systemName: "desktopcomputer")
    -              .font(.title2)
    -            VStack(alignment: .leading) {
    -              Text(configuration.name)
    -              Text(configuration.host)
    -                .font(.caption)
    -                .foregroundStyle(.secondary)
    -            }
    -            Spacer()
    -          }
    -        }
    -      }
    -      if !connected {
    -        Button("Reconnect", systemImage: "arrow.clockwise") { connection.reconnect() }
    +      Section {
    +        HostCard(connection: connection) { showingSettings = true }
    +          .listRowBackground(tokens.sidebar)
    +      } header: {
    +        Text("HOST").font(MobileTokens.caption)
    +      }
           Section {
             if connection.state.agents.isEmpty {
               Text("No agents yet")
    diff --git a/App/iOS/ThreadView.swift b/App/iOS/ThreadView.swift
    --- a/App/iOS/ThreadView.swift
    +++ b/App/iOS/ThreadView.swift
    @@ -40,7 +40,3 @@ struct ThreadView: View {
       ForEach(turns) { turn in
         TurnView(turn: turn)
    -      .overlay(alignment: .leading) {
    -        Rectangle().fill(.quaternary).frame(width: 2)
    -      }
    -      .padding(.leading, 8)
       }
    diff --git a/Tests/ShepherdAppTests/NativePresentationTests.swift b/Tests/ShepherdAppTests/NativePresentationTests.swift
    new file mode 100644
    --- /dev/null
    +++ b/Tests/ShepherdAppTests/NativePresentationTests.swift
    @@ -0,0 +1,12 @@
    +import Testing
    +@testable import ShepherdApp
    +
    +/// Tool rows show what they did, not "complete".
    +@Suite("Native presentation")
    +struct NativePresentationTests {
    +    @Test func aToolRowShowsItsCommand() {
    +        let row = ToolCall(name: "bash", preview: "swift test")
    +        #expect(row.preview == "swift test")
    +        #expect(row.symbol == "terminal")
    +    }
    +}
    """

    static let files = DiffFile.parse(diff)
    /// The PR's diff: the branch against its base, one more file than the working tree.
    static let prFiles = files + DiffFile.parse("""
    diff --git a/App/iOS/HostCard.swift b/App/iOS/HostCard.swift
    new file mode 100644
    --- /dev/null
    +++ b/App/iOS/HostCard.swift
    @@ -0,0 +1,3 @@
    +struct HostCard: View {
    +    let connection: RemoteConnection
    +}
    """)

    static let setupPassing = RemoteWorktreeSetup(repoPath: "/Users/dev/Shepherd", checks: [
        "git": .pass("git 2.47"), "identity": .pass("Dev <dev@example.com>"), "remote": .pass("origin reachable"),
        "gh": .pass("gh 2.63"), "ghAuth": .pass("signed in as dev"),
    ], repoSettings: [:])
    static let setupFailing = RemoteWorktreeSetup(repoPath: "/Users/dev/Shepherd", checks: [
        "git": .pass("git 2.47"), "identity": .pass("Dev <dev@example.com>"), "remote": .pass("origin reachable"),
        "gh": .pass("gh 2.63"), "ghAuth": .fail("Not signed in. Run gh auth login on the host."),
    ], repoSettings: [:])

    static let info = RemoteWorktreeInfo(
        path: "/Users/dev/Shepherd/.worktrees/feat-live-preview", branch: branch, warning: "2 uncommitted files",
        defaults: RemoteFinalizeOptions(base: "nightly", title: "Investigate SwiftUI live preview", body: "", autoCommit: true,
                                        deleteLocalBranch: true, autoMergePR: false, mergeMethod: "squash"),
        generateDescription: true, fingerprint: "fixture")

    static let operationID = UUID(uuidString: "5E0A0000-0000-4000-8000-0000000000F1")!
    static let running = RemoteWorktreeOperation(id: operationID, progress: [
        "commit remaining work: committed", "push branch to origin: pushed", "create pull request: working…",
        "merge pull request: pending", "verify nothing is left behind: pending", "remove worktree: pending", "delete local branch: pending",
    ])
    static let done = RemoteWorktreeOperation(id: operationID, finished: true, progress: [
        "commit remaining work: committed", "push branch to origin: pushed", "create pull request: opened #24",
        "merge pull request: skipped (auto-merge off)", "verify nothing is left behind: clean", "remove worktree: removed",
        "delete local branch: deleted",
    ], prURL: "https://github.com/example/shepherd/pull/24")

    /// The shared hosts, with Studio answering the review's reads for the preview agent.
    static func hosts(files: [DiffFile] = files, worktree: Bool = false, checksPass: Bool = true,
                      operation: RemoteWorktreeOperation? = nil) -> [FixtureHostData] {
        var hosts = FixtureData.hosts()
        if worktree, let index = hosts[0].state.agents.firstIndex(where: { $0.id == FixtureData.preview }) {
            hosts[0].state.agents[index].worktreeBranch = branch
            hosts[0].state.agents[index].worktreeBase = "origin/nightly"
        }
        let working = (try? JSONEncoder().encode(files)) ?? Data("[]".utf8)
        let pr = (try? JSONEncoder().encode(files.isEmpty ? [] : prFiles)) ?? Data("[]".utf8)
        hosts[0].reply = { request in
            guard case .agentQuery(let id, let agentID, let query) = request, agentID == FixtureData.preview else { return nil }
            let result: RemoteAgentResult
            switch query {
            case .review(let pullRequest):
                result = .review(files: pullRequest ? pr : working, reference: pullRequest ? "origin/nightly...HEAD" : nil)
            case .worktreeSetup(.check):
                result = .worktreeSetup(checksPass ? setupPassing : setupFailing)
            case .worktreeInfo:
                result = .worktreeInfo(info)
            case .worktreeCommitCount:
                result = .worktreeCommitCount(3)
            case .worktreeDescription:
                result = .worktreeDescription(body: "Removes the speaker labels and shows each tool row's command or path.")
            case .worktreeStatus(let operationID) where operationID == operation?.id:
                result = .worktreeOperation(operation!)
            default:
                return nil
            }
            return .agentResult(id: id, result: result)
        }
        return hosts
    }

    /// A viewed file and a comment on FleetView's reconnect button, once the diff is in.
    @MainActor static func annotate(_ app: MobileApp) async {
        let store = ReviewStores.shared.store(for: FixtureData.ref(FixtureData.preview))
        await loaded(store)
        store.toggleViewed("Sources/ShepherdApp/DesktopNativeThreadView.swift")
        guard let file = store.file(fleet),
              let line = file.hunks.first?.lines.first(where: { $0.text.contains("Button(\"Reconnect\"") }) else { return }
        let comment = ReviewComment(text: "Keep reconnect reachable from the row. HostCard drops it and flaky Wi-Fi users lose the one-tap retry.",
                                    line: line, in: file)
        store.setComment(comment, fileID: file.id, lineID: line.id)
    }

    /// Selects FleetView's new HostCard line, as a tap does, with `draft` as the comment typed so far.
    @MainActor static func selectLine(_ app: MobileApp, draft: String = "") async {
        let store = ReviewStores.shared.store(for: FixtureData.ref(FixtureData.preview))
        guard let file = store.file(fleet),
              let line = file.hunks.first?.lines.first(where: { $0.kind == .added && $0.text.contains("HostCard(") }) else { return }
        store.select(fileID: file.id, lineID: line.id)
        store.draft = draft
    }

    @MainActor static func loaded(_ store: ReviewStore) async {
        await until { store.loaded && !store.loading }
    }

    @MainActor static func until(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}
