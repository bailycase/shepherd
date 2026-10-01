import SwiftUI

private let nwPreviewLevels = [
  NWThinkingOption(id: "low", title: "Low", note: "quick"),
  NWThinkingOption(id: "medium", title: "Medium", note: "default"),
  NWThinkingOption(id: "high", title: "High", note: "slower, deeper"),
  NWThinkingOption(id: "xhigh", title: "Extra high", note: "deeper still"),
]

private let nwPreviewSpeeds = [
  NWSpeedOption(id: "standard", title: "Standard", detail: "Default speed and price"),
  NWSpeedOption(
    id: "fast", title: "Fast", detail: "Faster responses, billed at a higher rate", boosted: true),
]

/// The popover for a model with Fast, with `speed` chosen.
private func nwPreviewSettings(
  speed: String, levels: [NWThinkingOption] = nwPreviewLevels, current: String = "xhigh",
  speeds: [NWSpeedOption] = nwPreviewSpeeds, model: String = "gpt-6.1-sol"
) -> some View {
  NWModelSettings(
    models: [
      NWModelOption(id: "openai/\(model)", title: model, isCurrent: true, fast: !speeds.isEmpty),
      NWModelOption(id: "anthropic/claude-opus", title: "claude-opus"),
    ],
    thinking: levels, currentThinking: current, speeds: speeds, currentSpeed: speed,
    chooseModel: { _ in }, chooseThinking: { _ in }, chooseSpeed: { _ in }, allModels: {},
    close: {})
}

#Preview("Model settings button") {
  NWPreviewBoth {
    VStack(alignment: .leading, spacing: NW.Space.m) {
      Button {
      } label: {
        NWModelSettingsLabel(model: "claude-opus", thinking: "Medium")
      }
      .buttonStyle(.nwComposerChip())
      Button {
      } label: {
        NWModelSettingsLabel(model: "gpt-6.1-sol", thinking: "Extra high", fast: true)
      }
      .buttonStyle(.nwComposerChip())
      Button {
      } label: {
        NWModelSettingsLabel(model: "gpt-6.1-sol", fast: true)
      }
      .buttonStyle(.nwComposerChip())
      Button {
      } label: {
        NWModelSettingsLabel(model: "claude-haiku")
      }
      .buttonStyle(.nwComposerChip())
      Button {
      } label: {
        NWComposerBranchLabel(branch: "agent/swiftui-previews", changes: 3)
      }
      .buttonStyle(.nwComposerChip())
    }
  }
}

#Preview("Model settings") {
  NWPreviewBoth {
    HStack(alignment: .top, spacing: NW.Space.xl) {
      nwPreviewSettings(speed: "standard")
      nwPreviewSettings(speed: "fast")
      nwPreviewSettings(speed: "standard", speeds: [], model: "claude-sonnet")
    }
  }
}

#Preview("Model settings, every level") {
  NWPreviewBoth {
    HStack(alignment: .top, spacing: NW.Space.xl) {
      nwPreviewSettings(
        speed: "fast",
        levels: ["off", "minimal", "low", "medium", "high"].map {
          NWThinkingOption(id: $0, title: $0.capitalized)
        }, current: "medium")
      nwPreviewSettings(
        speed: "fast",
        levels: nwPreviewLevels
          + [NWThinkingOption(id: "off", title: "Off"), NWThinkingOption(id: "max", title: "Max")],
        current: "xhigh")
    }
  }
}
