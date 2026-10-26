import SwiftUI

/// The switch for settings that apply immediately (Controls board): 30×18, lantern when on.
/// On a native `Toggle`: `.toggleStyle(.shSwitch)`. VoiceOver and keyboard see a real toggle.
public struct SHSwitchToggleStyle: ToggleStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        SHSwitch(configuration: configuration)
    }
}

extension ToggleStyle where Self == SHSwitchToggleStyle {
    public static var shSwitch: SHSwitchToggleStyle { SHSwitchToggleStyle() }
}

private struct SHSwitch: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var enabled
    @Environment(\.labelsVisibility) private var labelsVisibility

    var body: some View {
        let sh = Color.sh
        let on = configuration.isOn
        HStack(spacing: SH.Space.m) {
            if labelsVisibility != .hidden { configuration.label }
            Button { configuration.isOn.toggle() } label: {
                Capsule()
                    .fill(on ? sh.lantern : sh.lineStrong)
                    .frame(width: 30, height: 18)
                    .overlay(alignment: on ? .trailing : .leading) {
                        Circle()
                            .fill(on ? sh.knobOn : sh.knobOff)
                            .shadow(color: sh.knobShadow, radius: 1, y: 1)
                            .frame(width: 14, height: 14)
                            .padding(2)
                    }
                    .frame(minHeight: SH.Height.controlS)
                    .contentShape(Rectangle())
                    // The knob slides and the fill turns lantern however the value changed
                    // (a click, Space, a reset, another window).
                    .shComponentAnimation(.content, value: on)
                    .shFocusRing(radius: 9)
            }
            .buttonStyle(.plain)
        }
        .shEnabledOpacity(enabled)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

/// The checkbox for lists and "done when" checks (Controls board): 14pt, radius 4, lantern
/// when on, a dash when mixed. On a native `Toggle`: `.toggleStyle(.shCheckbox)`.
public struct SHCheckboxToggleStyle: ToggleStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        SHCheckbox(configuration: configuration)
    }
}

extension ToggleStyle where Self == SHCheckboxToggleStyle {
    public static var shCheckbox: SHCheckboxToggleStyle { SHCheckboxToggleStyle() }
}

private struct SHCheckbox: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var enabled
    @Environment(\.labelsVisibility) private var labelsVisibility

    var body: some View {
        let sh = Color.sh
        let filled = configuration.isOn || configuration.isMixed
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: SH.Space.m) {
                ZStack {
                    RoundedRectangle(cornerRadius: SH.Radius.xs)
                        .fill(filled ? sh.lantern : sh.bgRaised)
                    if !filled {
                        RoundedRectangle(cornerRadius: SH.Radius.xs).strokeBorder(sh.lineStrong, lineWidth: 1.5)
                    }
                    if configuration.isMixed {
                        RoundedRectangle(cornerRadius: 1).fill(sh.textOnLantern).frame(width: 7, height: 2)
                    } else if configuration.isOn {
                        Image(systemName: "checkmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(sh.textOnLantern)
                    }
                }
                .frame(width: 14, height: 14)
                // The fill and the mark fade in place, only in the box: the label never moves.
                .shComponentAnimation(.content, value: filled)
                .shComponentAnimation(.content, value: configuration.isMixed)
                .shFocusRing(radius: SH.Radius.xs)
                if labelsVisibility != .hidden { configuration.label }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .shEnabledOpacity(enabled)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}
