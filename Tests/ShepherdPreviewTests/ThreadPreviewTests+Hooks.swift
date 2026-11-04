import AppKit
import Foundation
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdUI
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp

/// Hooks in a thread (HookThreadScene board) in light and dark: every row kind from the runtime's
/// messages through the host's projection, the running hook's live line, the proposal card, the
/// ask panel, and the composer with and without the hook glyph.
extension ThreadPreviewTests {
    private func renderHooks(_ surface: String, _ snapshot: NativeThreadSnapshot, hooks: HookFixture, cwd: String,
                             size: CGSize = CGSize(width: 1000, height: 900), ready: @escaping @MainActor () -> Bool = { true }) async throws {
        let workspace = try PreviewWorkspace(hooks: hooks.model)
        defer { workspace.stop() }
        let fixture = ThreadFixture(snapshot)
        defer { fixture.store.stop() }
        try await Preview.render(surface, size: size, ready: { fixture.store.ready && !fixture.store.rows.isEmpty && ready() }) {
            VStack(spacing: 0) {
                ThreadHeader(store: fixture.store, project: "payments", title: "Fix refund rounding")
                ThreadView(store: fixture.store, active: true, isFocused: false, request: fixture.request, commandKey: "preview",
                           agentName: "Fix refund rounding", workingDirectory: cwd, review: { _ in }, allowsLocalFiles: true)
            }
            .environment(\.threadCommands, fixture.commands)
            .environment(\.composerModelDefaults, fixture.modelDefaults)
            .environment(\.hookPresenter, HookPresenter(model: workspace.vm))
        }
    }

    @Test func threadHookRows() async throws {
        let hooks = try HookFixture()
        defer { hooks.remove() }
        let file = hooks.payments + "/.shepherd/hooks.json"
        let model = hooks.model
        try await renderHooks("thread-hook-rows", HookThreads.everyKind(file: file), hooks: hooks, cwd: hooks.payments,
                              size: CGSize(width: 1000, height: 1500)) { model.indicator(forCwd: hooks.payments) != nil }
    }

    @Test func threadHookRunning() async throws {
        let hooks = try HookFixture()
        defer { hooks.remove() }
        let model = hooks.model
        try await renderHooks("thread-hook-running", HookThreads.running, hooks: hooks, cwd: hooks.payments, size: CGSize(width: 1000, height: 560)) {
            model.indicator(forCwd: hooks.payments) != nil
        }
    }

    @Test func threadHookProposal() async throws {
        let hooks = try HookFixture()
        defer { hooks.remove() }
        let snapshot = HookThreads.propose(space: hooks.payments + "/.shepherd/hooks.json", mac: hooks.home + "/.shepherd/hooks.json")
        try await renderHooks("thread-hook-proposal", snapshot, hooks: hooks, cwd: hooks.payments, size: CGSize(width: 1000, height: 820))
    }

    @Test func threadHookAsk() async throws {
        let hooks = try HookFixture()
        defer { hooks.remove() }
        try await renderHooks("thread-hook-ask", HookThreads.ask(file: hooks.home + "/.shepherd/hooks.json"), hooks: hooks, cwd: hooks.payments,
                              size: CGSize(width: 1000, height: 620))
    }

    /// No hooks configured: no glyph. Hooks that run: the glyph.
    @Test func threadHookComposerGlyph() async throws {
        let none = try HookFixture(empty: true)
        defer { none.remove() }
        let quiet = HookThreads.snapshot([HookThreads.user("u1", "Add a monthly CSV export."), HookThreads.say("a1", "Done.")])
        let noneModel = none.model
        try await renderHooks("thread-hook-composer-none", quiet, hooks: none, cwd: none.payments, size: CGSize(width: 1000, height: 420)) {
            noneModel.snapshot != nil && !noneModel.loading
        }
        let some = try HookFixture()
        defer { some.remove() }
        let model = some.model
        try await renderHooks("thread-hook-composer-glyph", quiet, hooks: some, cwd: some.payments, size: CGSize(width: 1000, height: 420)) {
            model.indicator(forCwd: some.payments) != nil
        }
    }
}
