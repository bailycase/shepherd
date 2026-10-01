import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI
import SwiftUI
import Testing

@testable import ShepherdApp

extension ThreadPreviewTests {
    /// NWModelSettings as the board draws it (gpt-6.1-sol with a Fast tier, claude-opus without):
    /// Low to Extra high and the chosen speed.
    @MainActor static func modelSettings(speed: String, levels: [String] = ["low", "medium", "high", "xhigh"], current: String = "xhigh",
                                         tiers: Bool = true) -> some View {
        NWModelSettings(models: [NWModelOption(id: "openai/gpt-6.1-sol", title: "gpt-6.1-sol", isCurrent: true, fast: tiers),
                                 NWModelOption(id: "anthropic/claude-opus", title: "claude-opus")],
                        thinking: thinkingOptions(levels), currentThinking: current,
                        speeds: tiers ? [NWSpeedOption(id: "standard", title: "Standard", detail: "Default speed and price"),
                                         NWSpeedOption(id: "fast", title: "Fast", detail: "Faster responses, billed at a higher rate", boosted: true)] : [],
                        currentSpeed: speed, chooseModel: { _ in }, chooseThinking: { _ in }, chooseSpeed: { _ in }, allModels: {}, close: {})
    }

    /// The popover in each state the composer reaches: Standard, Fast, a model with no raised
    /// tier (no Speed row), and a model with every thinking level (the segments wrap). Rendered
    /// across appearances and text sizes (`Preview.renderMatrix`): at 1.3 a clipped title may show.
    @Test func modelSettingsPopoverStates() async throws {
        let size = CGSize(width: 1180, height: 620)
        try await Preview.renderMatrix("composer-model-settings", size: size) {
            HStack(alignment: .top, spacing: 24) {
                Self.modelSettings(speed: "standard")
                Self.modelSettings(speed: "fast")
                VStack(alignment: .leading, spacing: 24) {
                    Self.modelSettings(speed: "standard", tiers: false)
                    Self.modelSettings(speed: "fast", levels: ["off", "minimal", "low", "medium", "high", "xhigh", "max"], current: "max")
                }
            }
            .padding(32)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color.nw.bgWindow)
        }
    }

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
