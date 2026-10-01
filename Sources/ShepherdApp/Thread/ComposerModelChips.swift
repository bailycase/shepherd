import SwiftUI
import ShepherdCore
import ShepherdRemote
import ShepherdUI

/// The model controls shared by New thread and a running thread's composer.
struct ComposerModelChip: View {
    let model: String
    var short = false
    var changeable = true
    var enabled = true
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: NW.Space.s) {
                Text(model.isEmpty ? "Default" : short ? nativeModelCompactName(model) : nativeModelShortName(model))
                    .font(Font.nw(.code)).lineLimit(1).truncationMode(.middle)
                    .nwContentTransition(.crossFade)
                if changeable { NWChipChevron() }
            }
        }
        .buttonStyle(.nwComposerChip(active: active))
        .disabled(!enabled)
        .help(model.isEmpty ? "Model: the default" : "Model: \(model)")
        .accessibilityLabel("Model \(model.isEmpty ? "Default" : model)")
    }
}

struct ComposerThinkingChip: View {
    let level: String
    var short = false
    var enabled = true
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) { NWComposerThinkingLabel(level: NativeThinkingLevel.title(level), short: short) }
            .buttonStyle(.nwComposerChip(active: active))
            .disabled(!enabled)
            .accessibilityLabel("Thinking level: \(NativeThinkingLevel.title(level))")
    }
}

struct ComposerSpeedChip: View {
    let tier: ServiceTier
    var short = false
    var enabled = true
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) { NWComposerSpeedLabel(value: tier.title, boosted: tier != .standard, short: short) }
            .buttonStyle(.nwComposerChip(active: active))
            .disabled(!enabled)
            .help("Speed: \(tier.title)")
            .accessibilityLabel("Speed: \(tier.title)")
    }
}
