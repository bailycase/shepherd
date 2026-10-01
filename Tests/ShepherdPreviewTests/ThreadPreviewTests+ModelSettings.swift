import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI
import SwiftUI
import Testing

@testable import ShepherdApp

extension ThreadPreviewTests {
  @Test(arguments: [
    ["off", "minimal", "low", "medium", "high"],
    ["off", "minimal", "low", "medium", "high", "xhigh", "max"],
  ])
  func thinkingSettingsWithEverySupportedLevel(_ levels: [String]) async throws {
    var snapshot = ActivityThreads.idle
    snapshot.model = "anthropic/claude-opus"
    snapshot.thinking = "medium"
    snapshot.thinkingLevels = levels
    let fixture = ThreadFixture(snapshot)
    defer { fixture.store.stop() }
    try await Preview.render(
      "composer-thinking-\(levels.count)-levels", size: CGSize(width: 720, height: 600),
      ready: { fixture.store.ready && !fixture.store.rows.isEmpty }
    ) {
      ThreadView(
        store: fixture.store, active: true, isFocused: false, request: fixture.request,
        agentName: "Review thinking levels", listModels: { .empty }, modelSettingsOpen: true)
    }
  }

  /// Real ThreadView and Composer, not a reproduction of their controls.
  @Test func redesignedComposerInThread() async throws {
    var snapshot = ActivityThreads.idle
    snapshot.model = "openai/gpt-6.1-sol"
    snapshot.thinking = "xhigh"
    snapshot.thinkingLevels = ["low", "medium", "high", "xhigh"]
    snapshot.serviceTier = "fast"
    snapshot.serviceTiers = ["standard", "fast"]
    snapshot.supportedActions.append("setServiceTier")
    let fixture = ThreadFixture(snapshot)
    fixture.store.draft = "Make the reviewer check dark mode too"
    defer { fixture.store.stop() }
    for settings in [false, true] {
      try await Preview.render(
        settings ? "composer-app-settings" : "composer-app-thread",
        size: CGSize(width: 1180, height: 800),
        ready: { fixture.store.ready && !fixture.store.rows.isEmpty }
      ) {
        VStack(spacing: 0) {
          ThreadHeader(store: fixture.store, project: "Shepherd", title: "Review the composer")
          ThreadView(
            store: fixture.store, active: true, isFocused: false, request: fixture.request,
            agentName: "Review the composer", workingDirectory: "~/Developer/Shepherd",
            branch: AgentBranchLabel(
              kind: .worktree, branch: "agent/swiftui-previews", changedFiles: 3),
            showChanges: {}, listModels: { .empty }, modelSettingsOpen: settings)
        }
      }
    }
  }
}
