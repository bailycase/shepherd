import SwiftUI

#Preview("Unified model settings") {
  NWPreviewBoth {
    VStack(alignment: .leading, spacing: NW.Space.l) {
      Button {
      } label: {
        NWModelSettingsLabel(model: "gpt-6.1-sol", thinking: "Extra high", fast: true)
      }
      .buttonStyle(.nwComposerChip())
      NWModelSettings(
        models: [
          NWModelOption(id: "openai/gpt-6.1-sol", title: "gpt-6.1-sol", isCurrent: true),
          NWModelOption(id: "anthropic/claude-opus", title: "claude-opus"),
        ],
        thinking: [
          NWThinkingOption(id: "low", title: "Low", note: ""),
          NWThinkingOption(id: "medium", title: "Medium", note: ""),
          NWThinkingOption(id: "high", title: "High", note: ""),
          NWThinkingOption(id: "xhigh", title: "Extra high", note: ""),
        ], currentThinking: "xhigh",
        speeds: [
          NWSpeedOption(id: "standard", title: "Standard", detail: "", boosted: false),
          NWSpeedOption(id: "fast", title: "Fast", detail: "", boosted: true),
        ], currentSpeed: "fast",
        chooseModel: { _ in }, chooseThinking: { _ in }, chooseSpeed: { _ in }, allModels: {},
        close: {})
    }
  }
}
