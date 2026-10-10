import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// The surfaces ThreadControlsFixes changes, from their real producers, light and dark at text
/// scale 1 and 1.3: the composer's corner (Stop when it works and nothing is typed, Send beside
/// an outlined Stop with words or a long draft), the workplace menu's Base row, and the base
/// picker over a long list of long names, a short one and an empty search.
@Suite("Thread controls previews", .serialized, .mainActorExclusive, .enabled(if: Preview.enabled && !Preview.liveModel, "set SHEPHERD_PREVIEW_DIR (without SHEPHERD_LIVE_MODEL) to render previews"))
@MainActor
struct ThreadControlsPreviewTests {
    private func thread(_ surface: String, running: Bool, draft: String) async throws {
        var snapshot = Threads.subagents([], running: running)
        snapshot.running = running
        let fixture = ThreadFixture(snapshot)
        fixture.store.draft = draft
        defer { fixture.store.stop() }
        try await Preview.renderMatrix(surface, size: CGSize(width: 900, height: 600), ready: { fixture.store.ready && fixture.store.running == running }) {
            fixture.thread()
        }
    }

    @Test func idleWithNothingTyped() async throws { try await thread("controls-idle", running: false, draft: "") }
    @Test func workingWithNothingTyped() async throws { try await thread("controls-working-empty", running: true, draft: "") }
    @Test func workingWithWords() async throws { try await thread("controls-working-typed", running: true, draft: "Also check the migration.") }
    @Test func workingWithALongDraft() async throws {
        try await thread("controls-working-long", running: true,
                         draft: Array(repeating: "Also run the whole suite twice and compare the timings between both runs.", count: 6).joined(separator: " "))
    }

    /// The real picker over a scratch repository (the engine's own branch list: checked-out branch,
    /// long names, a worktree-tagged one, many rows), then a search nothing matches, then a folder
    /// that is no repository (the engine's own refusal).
    @Test(arguments: [("worktree-base-picker", "", true), ("worktree-base-picker-empty", "zzz", true), ("worktree-base-picker-failed", "", false)])
    func theRealBasePicker(surface: String, query: String, repo: Bool) async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        let dir: URL
        if repo {
            dir = try makeScratchRepo()
            for name in ["release/2.4", "agent/calm-stone-3831-with-a-very-long-branch-name-that-keeps-going"] + (0..<30).map({ "feat/ledger-\($0)" }) {
                try git(["branch", name], in: dir)
            }
            try git(["worktree", "add", "-q", dir.deletingLastPathComponent().appendingPathComponent("wt-\(UUID().uuidString.prefix(6))").path,
                     "-b", "agent/in-a-worktree"], in: dir)
        } else {
            dir = try makeScratchDirectory("not-a-repo")
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        // `render` waits for "Reading branches…" to leave and for the settled text to show (a blank
        // or spinner capture is no evidence), at text scale 1 and 1.3.
        let settled = repo ? (query.isEmpty ? "feat/ledger" : "No branch matches") : "repository"
        let store = ThemeStore.shared
        let original = store.textScale
        defer { store.textScale = original }
        for scale in [CGFloat(1), 1.3] {
            store.textScale = scale
            try await Preview.render(scale == 1 ? surface : "\(surface)-x1.3", size: CGSize(width: 380, height: 460),
                                     untilGone: "Reading branches", showing: settled) {
                WorktreeBasePicker(vm: workspace.vm, repo: dir.path, selected: repo ? "agent/in-a-worktree" : nil, query: query, choose: { _ in }, close: {})
                    .padding(NW.Space.l)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Color.nw.bgWindow)
            }
        }
    }

    @Test(arguments: [("worktree-place-default", "Default"), ("worktree-place-picked", "agent/calm-stone-3831-with-a-very-long-branch-name")])
    func theWorkplaceMenuWithABaseRow(surface: String, base: String) async throws {
        let mac = NWPlaceSection(id: "local", title: "This Mac", options: [
            NWPlaceOption(id: "local/a", section: "local", title: "shepherd", detail: "~/Developer/Shepherd", isCurrent: true),
        ])
        try await Preview.renderMatrix(surface, size: CGSize(width: 360, height: 260)) {
            NWPlaceMenu(sections: [mac], worktree: NWPlaceWorktree(isOn: true, caption: NewThreadRules.worktreeCaption(base: base == "Default" ? "" : base), base: base),
                        onChoose: { _ in }, onAdd: { _ in }, onWorktree: { _ in }, onClose: {}) { _ in EmptyView() }
                .padding(NW.Space.l)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color.nw.bgWindow)
        }
    }
}
