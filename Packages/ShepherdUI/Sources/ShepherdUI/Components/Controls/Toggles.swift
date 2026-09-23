import SwiftUI

/// The switch for settings that apply immediately (Controls board): 30×18, lantern when on.
/// On a native `Toggle`: `.toggleStyle(.nwSwitch)`. VoiceOver and keyboard see a real toggle.
public struct NWSwitchToggleStyle: ToggleStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        NWSwitch(configuration: configuration)
    }
}

extension ToggleStyle where Self == NWSwitchToggleStyle {
    public static var nwSwitch: NWSwitchToggleStyle { NWSwitchToggleStyle() }
}

private struct NWSwitch: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var enabled
    @Environment(\.labelsVisibility) private var labelsVisibility

    var body: some View {
        let nw = Color.nw
        let on = configuration.isOn
        HStack(spacing: NW.Space.m) {
            if labelsVisibility != .hidden { configuration.label }
            Button { configuration.isOn.toggle() } label: {
                Capsule()
                    .fill(on ? nw.lantern : nw.lineStrong)
                    .frame(width: 30, height: 18)
                    .overlay(alignment: on ? .trailing : .leading) {
                        Circle()
                            .fill(on ? nw.knobOn : nw.knobOff)
                            .shadow(color: nw.knobShadow, radius: 1, y: 1)
                            .frame(width: 14, height: 14)
                            .padding(2)
                    }
                    .contentShape(Capsule())
                    .nwAnimation(.hover, value: on)
                    .nwFocusRing(radius: 9)
            }
            .buttonStyle(.plain)
        }
        .opacity(enabled ? 1 : 0.4)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

/// The checkbox for lists and "done when" checks (Controls board): 14pt, radius 4, lantern
/// when on, a dash when mixed. On a native `Toggle`: `.toggleStyle(.nwCheckbox)`.
public struct NWCheckboxToggleStyle: ToggleStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        NWCheckbox(configuration: configuration)
    }
}

extension ToggleStyle where Self == NWCheckboxToggleStyle {
    public static var nwCheckbox: NWCheckboxToggleStyle { NWCheckboxToggleStyle() }
}

private struct NWCheckbox: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var enabled
    @Environment(\.labelsVisibility) private var labelsVisibility

    var body: some View {
        let nw = Color.nw
        let filled = configuration.isOn || configuration.isMixed
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: NW.Space.m) {
                ZStack {
                    RoundedRectangle(cornerRadius: NW.Radius.xs)
                        .fill(filled ? nw.lantern : nw.bgRaised)
                    if !filled {
                        RoundedRectangle(cornerRadius: NW.Radius.xs).strokeBorder(nw.lineStrong, lineWidth: 1.5)
                    }
                    if configuration.isMixed {
                        RoundedRectangle(cornerRadius: 1).fill(nw.textOnLantern).frame(width: 7, height: 2)
                    } else if configuration.isOn {
                        Image(systemName: "checkmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(nw.textOnLantern)
                    }
                }
                .frame(width: 14, height: 14)
                .nwFocusRing(radius: NW.Radius.xs)
                if labelsVisibility != .hidden { configuration.label }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}
