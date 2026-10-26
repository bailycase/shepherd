import SwiftUI

private let shPreviewLevels = [
  SHThinkingOption(id: "low", title: "Low", note: "quick"),
  SHThinkingOption(id: "medium", title: "Medium", note: "default"),
  SHThinkingOption(id: "high", title: "High", note: "slower, deeper"),
  SHThinkingOption(id: "xhigh", title: "Extra high", note: "deeper still"),
]

private let shPreviewSpeeds = [
  SHSpeedOption(id: "standard", title: "Standard", detail: "Default speed and price"),
  SHSpeedOption(
    id: "fast", title: "Fast", detail: "Faster responses, billed at a higher rate", boosted: true),
]

/// The popover for a model with Fast, with `speed` chosen.
private func shPreviewSettings(
  speed: String, levels: [SHThinkingOption] = shPreviewLevels, current: String = "xhigh",
  speeds: [SHSpeedOption] = shPreviewSpeeds, model: String = "gpt-6.1-sol"
) -> some View {
  SHModelSettings(
    models: [
      SHModelOption(id: "openai/\(model)", title: model, isCurrent: true, fast: !speeds.isEmpty),
      SHModelOption(id: "anthropic/claude-opus", title: "claude-opus"),
    ],
    thinking: levels, currentThinking: current, speeds: speeds, currentSpeed: speed,
    chooseModel: { _ in }, chooseThinking: { _ in }, chooseSpeed: { _ in }, allModels: {},
    close: {})
}

#Preview("Model settings button") {
  SHPreviewBoth {
    VStack(alignment: .leading, spacing: SH.Space.m) {
      Button {
      } label: {
        SHModelSettingsLabel(model: "claude-opus", thinking: "Medium")
      }
      .buttonStyle(.shComposerChip())
      Button {
      } label: {
        SHModelSettingsLabel(model: "gpt-6.1-sol", thinking: "Extra high", fast: true)
      }
      .buttonStyle(.shComposerChip())
      Button {
      } label: {
        SHModelSettingsLabel(model: "gpt-6.1-sol", fast: true)
      }
      .buttonStyle(.shComposerChip())
      Button {
      } label: {
        SHModelSettingsLabel(model: "claude-haiku")
      }
      .buttonStyle(.shComposerChip())
      Button {
      } label: {
        SHComposerBranchLabel(branch: "agent/swiftui-previews", changes: 3)
      }
      .buttonStyle(.shComposerChip())
    }
  }
}

#Preview("Model settings") {
  SHPreviewBoth {
    HStack(alignment: .top, spacing: SH.Space.xl) {
      shPreviewSettings(speed: "standard")
      shPreviewSettings(speed: "fast")
      shPreviewSettings(speed: "standard", speeds: [], model: "claude-sonnet")
    }
  }
}

#Preview("Model settings, every level") {
  SHPreviewBoth {
    HStack(alignment: .top, spacing: SH.Space.xl) {
      shPreviewSettings(
        speed: "fast",
        levels: ["off", "minimal", "low", "medium", "high"].map {
          SHThinkingOption(id: $0, title: $0.capitalized)
        }, current: "medium")
      shPreviewSettings(
        speed: "fast",
        levels: shPreviewLevels
          + [SHThinkingOption(id: "off", title: "Off"), SHThinkingOption(id: "max", title: "Max")],
        current: "xhigh")
    }
  }
}
