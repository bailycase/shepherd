import AppKit
import Foundation
import ShepherdCore
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp

/// Renders every surface in light and dark to `$SHEPHERD_PREVIEW_DIR/<surface>-<light|dark>.png`
/// so a person or an agent can look at them:
///
///     SHEPHERD_PREVIEW_DIR=/tmp/previews swift test --filter ShepherdPreviewTests
///
/// Fixtures and a scripted stub pi only: no real model, no user files. Serialized so each
/// render has the main thread to itself.
@Suite("Previews", .serialized, .mainActorExclusive, .enabled(if: Preview.enabled && !Preview.liveModel, "set SHEPHERD_PREVIEW_DIR (without SHEPHERD_LIVE_MODEL) to render previews"))
@MainActor
struct PreviewTests {
    // MARK: Threads

    private func renderThread(_ surface: String, _ fixture: ThreadFixture, size: CGSize = CGSize(width: 1180, height: 1000),
                              inspected: String? = nil) async throws {
        defer { fixture.store.stop() }
        try await Preview.render(surface, size: size, ready: { fixture.store.ready }) {
            fixture.thread(inspected: inspected)
        }
    }

    @Test func threadIdle() async throws {
        try await renderThread("thread-idle", ThreadFixture(Threads.idle))
    }

    @Test func threadRunning() async throws {
        try await renderThread("thread-running", ThreadFixture(Threads.running))
    }

    @Test func threadQuestion() async throws {
        try await renderThread("thread-question", ThreadFixture(Threads.question))
    }

    @Test func threadEmpty() async throws {
        try await renderThread("thread-empty", ThreadFixture(Threads.empty), size: CGSize(width: 1180, height: 700))
    }

    // MARK: Composer menus

    @Test func composerSlashMenu() async throws {
        let fixture = ThreadFixture(Threads.idle)
        defer { fixture.store.stop() }
        fixture.store.draft = "/"
        try await Preview.render("composer-slash-menu", size: CGSize(width: 1000, height: 760), ready: { fixture.store.ready }) {
            fixture.thread()
        }
    }

    @Test func composerModelPicker() async throws {
        let fixture = ThreadFixture(Threads.idle)
        defer { fixture.store.stop() }
        let entries = [("anthropic/claude-opus-4-5", "200K"), ("anthropic/claude-sonnet-4-5", "1M"), ("anthropic/claude-haiku-4-5", "200K"),
                       ("openai/gpt-5", "400K"), ("google/gemini-2.5-pro", "1M")]
            .map { PiModelCatalog.Entry(id: $0.0, context: $0.1, reasoning: !$0.0.hasSuffix("haiku-4-5")) }
        // One model models.json gives Extra high and Max; one without reasoning.
        let levels = ["anthropic/claude-opus-4-5": ["off", "minimal", "low", "medium", "high", "xhigh", "max"]]
        final class Opened { var at: Date? }
        let opened = Opened()
        try await Preview.render("composer-model-picker", size: CGSize(width: 1000, height: 820), ready: {
            guard fixture.store.ready else { return false }
            // The picker grows from its chip: open it, then capture it at rest.
            if opened.at == nil {
                opened.at = Date()
                fixture.commands.send(.modelPicker, to: "preview")
            }
            return Date().timeIntervalSince(opened.at ?? Date()) > ThreadPreviewTests.motionAtRest
        }) {
            // Each appearance renders in a new window: open the picker in each.
            let _ = opened.at = nil
            fixture.thread(listModels: { ModelCatalog(entries, levels: levels) })
        }
    }

    /// The picker with legacy scroll bars (a mouse attached, or "Show scroll bars: Always"):
    /// a long catalog scrolls under the search row, the scroller inside the popover's edge.
    @Test func composerModelPickerLegacyScrollers() async throws {
        let fixture = ThreadFixture(Threads.idle)
        defer { fixture.store.stop() }
        let providers = ["anthropic", "openai", "google", "openrouter", "cpa"]
        let models = ["claude-opus-4-5", "claude-sonnet-4-5-20250929", "gpt-5.1-codex-max", "gemini-3-pro-preview", "o4-mini-deep-research"]
        let entries = providers.flatMap { provider in
            models.map { PiModelCatalog.Entry(id: "\(provider)/\($0)", context: "200K", reasoning: !$0.hasPrefix("gpt")) }
        }
        final class Opened { var at: Date? }
        let opened = Opened()
        try await Preview.render("composer-model-picker-legacy-scrollers", size: CGSize(width: 1000, height: 820), scrollers: .legacy, ready: {
            guard fixture.store.ready else { return false }
            if opened.at == nil {
                opened.at = Date()
                fixture.commands.send(.modelPicker, to: "preview")
            }
            return Date().timeIntervalSince(opened.at ?? Date()) > ThreadPreviewTests.motionAtRest
        }) {
            let _ = opened.at = nil
            fixture.thread(listModels: { ModelCatalog(entries) })
        }
    }

    // MARK: Gallery (the palette is in NavigationPreviewTests, the review pane in ReviewPreviewTests)

    @Test func componentGallery() async throws {
        try await Preview.render("components", size: CGSize(width: 1440, height: 1320)) {
            ComponentGallery()
        }
    }
}

/// `eventually` for main-actor previews whose condition awaits the server.
@MainActor
func eventuallyAsync(_ what: String, timeout: Duration = .seconds(20), _ condition: @MainActor () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    if try await condition() { return }
    Issue.record("timed out waiting for \(what)")
}
