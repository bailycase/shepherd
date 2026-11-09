import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// Review track's screens: the changes, the diff reader, the iPad review docked and full screen
// (unified and side by side). The host answers the review's reads (the diff); every screen
// state beyond that (comments, viewed files, a selected line) is set on this device's stores.
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
                store.pick(.pullRequest)
                await ReviewFixture.until { store.list?.scope == .pullRequest && !store.loading }
            }),
            // The base picker over the phone's changes (ChangesStates › BasePicker).
            FixtureScreen(name: "review-base", hosts: ReviewFixture.hosts(), routes: [thread, changes], prepare: { app in
                let store = ReviewStores.shared.store(for: ref)
                await ReviewFixture.loaded(store)
                store.pickingBase = true
                await ReviewFixture.until { store.branches != nil }
            }),
            // A host without the Changes engine: today's working tree review, the same screens.
            FixtureScreen(name: "review-legacy", hosts: ReviewFixture.hosts(legacy: true), routes: [thread, changes],
                          prepare: ReviewFixture.annotate),
            FixtureScreen(name: "review-empty", hosts: ReviewFixture.hosts(files: []), routes: [thread, changes]),
            FixtureScreen(name: "review-error", hosts: ReviewFixture.hosts(reviewError: ReviewFixture.loadError), routes: [thread, changes],
                          prepare: { _ in
                              let store = ReviewStores.shared.store(for: ref)
                              await ReviewFixture.until { store.loadError != nil && !store.loading }
                          }),
            FixtureScreen(name: "review-worktree", hosts: ReviewFixture.hosts(worktree: true), routes: [thread, changes],
                          prepare: ReviewFixture.annotate),
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

    /// What a host says when the agent's directory is no longer a repository.
    static let loadError = "git diff HEAD failed (128): fatal: not a git repository (or any of the parent directories): .git"

    /// The shared hosts, with Studio answering the review's reads for the preview agent.
    /// `legacy` is a host without the Changes engine (`changes.v1`), which answers `review` only.
    static func hosts(files: [DiffFile] = files, worktree: Bool = false, reviewError: String? = nil,
                      legacy: Bool = false) -> [FixtureHostData] {
        var hosts = FixtureData.hosts()
        if legacy {
            // An older host neither answers the engine nor records turns.
            hosts[0].capabilities = RemoteProtocol.capabilities.filter { $0 != RemoteProtocol.changesCapability }
            hosts[0].threads[FixtureData.preview] = FixtureData.thread(turn: nil)
        }
        // The MobileChanges board's branch, compared against main.
        let changes = ChangesFixture.reply(ChangesFixture.Repo(
            files: files, branch: "agent/pay-button-jump", base: "origin/main", baseName: "main", mergeBase: "4be2c01",
            lastTurn: FixtureData.previewTurn(), turnFiles: ["Sources/ShepherdApp/DesktopNativeThreadView.swift", "App/iOS/ThreadView.swift"],
            listError: reviewError))
        if let index = hosts[0].state.agents.firstIndex(where: { $0.id == FixtureData.preview }) {
            // The review screens choose: the shared fixture's worktree only where they ask for one.
            hosts[0].state.agents[index].worktreeBranch = worktree ? branch : nil
            hosts[0].state.agents[index].worktreeBase = worktree ? "origin/nightly" : nil
        }
        let working = (try? JSONEncoder().encode(files)) ?? Data("[]".utf8)
        let pr = (try? JSONEncoder().encode(files.isEmpty ? [] : prFiles)) ?? Data("[]".utf8)
        hosts[0].reply = { request in
            guard case .agentQuery(let id, let agentID, let query) = request, agentID == FixtureData.preview else { return nil }
            if case .review = query, let reviewError { return .error(id: id, code: "failed", message: reviewError) }
            let result: RemoteAgentResult
            switch query {
            case .review(let pullRequest):
                result = .review(files: pullRequest ? pr : working, reference: pullRequest ? "origin/nightly...HEAD" : nil)
            default:
                return legacy ? nil : changes(request)
            }
            return .agentResult(id: id, result: result)
        }
        return hosts
    }

    /// A viewed file and a comment on FleetView's reconnect button, once the diff is in.
    @MainActor static func annotate(_ app: MobileApp) async {
        let store = ReviewStores.shared.store(for: FixtureData.ref(FixtureData.preview))
        await loaded(store)
        await ChangesFixture.filesLoaded(store)
        store.toggleViewed("Sources/ShepherdApp/DesktopNativeThreadView.swift")
        guard let file = store.diff(fleet),
              let line = file.hunks.first?.lines.first(where: { $0.text.contains("Button(\"Reconnect\"") }) else { return }
        store.select(fileID: file.id, lineID: line.id)
        store.draft = "Keep reconnect reachable from the row. HostCard drops it and flaky Wi-Fi users lose the one-tap retry."
        store.saveDraft()
    }

    /// Selects FleetView's new HostCard line, as a tap does, with `draft` as the comment typed so far.
    @MainActor static func selectLine(_ app: MobileApp, draft: String = "") async {
        let store = ReviewStores.shared.store(for: FixtureData.ref(FixtureData.preview))
        await ChangesFixture.filesLoaded(store)
        guard let file = store.diff(fleet),
              let line = file.hunks.first?.lines.first(where: { $0.kind == .added && $0.text.contains("HostCard(") }) else { return }
        store.select(fileID: file.id, lineID: line.id)
        store.draft = draft
    }

    @MainActor static func loaded(_ store: ReviewStore) async {
        await until { store.loaded && !store.loading }
    }

    @MainActor static func until(file: StaticString = #fileID, line: UInt = #line, _ condition: () -> Bool) async {
        await FixtureWindows.wait("review readiness", seconds: 10, file: file, line: line, until: condition)
    }
}
