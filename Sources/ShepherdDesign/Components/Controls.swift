import SwiftUI

/// SegmentedControl (Components board): 2–4 exclusive options on a `bgTrack` track, the
/// selected one on a raised thumb with the segmented shadow.
public struct SegmentedControl<Value: Hashable>: View {
    public enum Size { case small, regular }
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    let size: Size

    public init(selection: Binding<Value>, options: [(Value, String)], size: Size = .regular) {
        _selection = selection
        self.options = options.map { (value: $0.0, title: $0.1) }
        self.size = size
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.title)
                        .font(selected ? Fonts.sans(12, .semibold) : Fonts.captionMedium)
                        .foregroundStyle(selected ? Tokens.text : Tokens.textSecondary)
                        .lineLimit(1)
                        .padding(.horizontal, size == .small ? 8 : 12)
                        .frame(height: size == .small ? Metrics.segmentHeightSmall : Metrics.segmentHeight)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: Radius.sm).fill(Tokens.bgRaised)
                                    .shadow(color: Tokens.thumbShadow, radius: 1, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Tokens.bgTrack, in: RoundedRectangle(cornerRadius: Radius.md))
        .fixedSize()
    }
}

/// The 38×22 accent switch for booleans (Settings).
public struct ShepherdSwitchStyle: ToggleStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        Switch(configuration: configuration)
    }

    private struct Switch: View {
        let configuration: ToggleStyleConfiguration
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.labelsVisibility) private var labelsVisibility

        var body: some View {
            HStack(spacing: 8) {
                if labelsVisibility != .hidden { configuration.label }
                Button { configuration.isOn.toggle() } label: {
                    Capsule()
                        .fill(configuration.isOn ? Tokens.accent : Tokens.bgTrack)
                        .overlay(Capsule().strokeBorder(configuration.isOn ? Color.clear : Tokens.borderStrong, lineWidth: 1))
                        .frame(width: Metrics.switchWidth, height: Metrics.switchHeight)
                        .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                            Circle().fill(Color.white)
                                .shadow(color: Tokens.thumbShadow, radius: 1, y: 1)
                                .frame(width: 18, height: 18)
                                .padding(2)
                        }
                        .opacity(enabled ? 1 : 0.5)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isOn)
                }
                .buttonStyle(.plain)
                .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
            }
        }
    }
}

extension ToggleStyle where Self == ShepherdSwitchStyle {
    public static var shepherdSwitch: ShepherdSwitchStyle { ShepherdSwitchStyle() }
}

/// Popup button label for longer option lists: raised fill, strong border, up/down chevrons.
/// Wrap it as a `Menu` label.
public struct PopupButtonLabel: View {
    let title: String
    var mono = false

    public init(_ title: String, mono: Bool = false) {
        self.title = title
        self.mono = mono
    }

    public var body: some View {
        HStack(spacing: 8) {
            Text(title).font(mono ? Fonts.code : Fonts.labelRegular).foregroundStyle(Tokens.text).lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Tokens.textMuted)
        }
        .padding(.horizontal, 10)
        .frame(height: Metrics.fieldHeight)
        .background(Tokens.bgRaised, in: RoundedRectangle(cornerRadius: Radius.button))
        .overlay(RoundedRectangle(cornerRadius: Radius.button).strokeBorder(Tokens.borderStrong, lineWidth: 1))
        .contentShape(Rectangle())
    }
}

/// A `Menu` shown as a PopupButtonLabel, without the system chrome.
public struct PopupMenu<Content: View>: View {
    let title: String
    let mono: Bool
    let minWidth: CGFloat
    @ViewBuilder let content: () -> Content

    public init(_ title: String, mono: Bool = false, minWidth: CGFloat = 180, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.mono = mono
        self.minWidth = minWidth
        self.content = content
    }

    public var body: some View {
        Menu(content: content) { PopupButtonLabel(title, mono: mono) }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .frame(minWidth: minWidth)
            .fixedSize(horizontal: true, vertical: false)
    }
}

/// Keycaps for a real shortcut ("⌘", "N"). Never shown for a chord that is not wired.
public struct Keycaps: View {
    let keys: [String]

    public init(_ keys: [String]) { self.keys = keys }

    /// Splits a display chord ("⇧⌘N") into caps.
    public init(chord: String) {
        var caps: [String] = []
        var rest = Substring(chord)
        while let first = rest.first, "⌃⌥⇧⌘".contains(first) {
            caps.append(String(first))
            rest = rest.dropFirst()
        }
        if !rest.isEmpty { caps.append(String(rest).uppercased()) }
        keys = caps
    }

    public var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(Fonts.mono(10.5, .medium))
                    .foregroundStyle(Tokens.textSecondary)
                    .frame(minWidth: 18, minHeight: 18)
                    .padding(.horizontal, key.count > 1 ? 4 : 0)
                    .background(Tokens.bgRaised, in: RoundedRectangle(cornerRadius: Radius.xs))
                    .overlay(RoundedRectangle(cornerRadius: Radius.xs).strokeBorder(Tokens.borderStrong, lineWidth: 1))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(keys.joined())
    }
}

extension View {
    /// The standard field chrome for a `TextField`: raised, strong border, accent border and
    /// ring while focused.
    public func shepherdField(focused: Bool = false, mono: Bool = false) -> some View {
        self
            .textFieldStyle(.plain)
            .font(mono ? Fonts.code : Fonts.labelRegular)
            .foregroundStyle(Tokens.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minHeight: Metrics.fieldHeight)
            .background(Tokens.bgRaised, in: RoundedRectangle(cornerRadius: Radius.button))
            .overlay(RoundedRectangle(cornerRadius: Radius.button).strokeBorder(focused ? Tokens.accent : Tokens.borderStrong, lineWidth: 1))
            .background(RoundedRectangle(cornerRadius: Radius.button + 3).fill(focused ? Tokens.focusRing : .clear).padding(-3))
    }
}

/// Search field with a leading glyph and an optional trailing hint (a shortcut keycap).
public struct SearchField: View {
    let placeholder: String
    @Binding var text: String
    var shortcut: String?
    var large = false

    public init(_ placeholder: String, text: Binding<String>, shortcut: String? = nil, large: Bool = false) {
        self.placeholder = placeholder
        _text = text
        self.shortcut = shortcut
        self.large = large
    }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: large ? 15 : 12, weight: .medium))
                .foregroundStyle(Tokens.textMuted)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(large ? Fonts.sans(16) : Fonts.labelRegular)
                .foregroundStyle(Tokens.text)
            if let shortcut, text.isEmpty {
                Text(shortcut).font(Fonts.micro).foregroundStyle(Tokens.textMuted)
            }
        }
        .padding(.horizontal, large ? 16 : 10)
        .frame(height: large ? Metrics.paletteSearchHeight : Metrics.fieldHeight + 2)
        .background {
            if !large {
                RoundedRectangle(cornerRadius: Radius.md).fill(Tokens.bgRaised)
                    .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(Tokens.borderStrong, lineWidth: 1))
            }
        }
    }
}

/// A slider with its value in mono beside it ("105%", "239 pt"). Double-clicking the value
/// restores `neutral` when one is given.
public struct ValueSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String
    var neutral: Double?

    public init(value: Binding<Double>, in range: ClosedRange<Double>, step: Double,
                neutral: Double? = nil, format: @escaping (Double) -> String) {
        _value = value
        self.range = range
        self.step = step
        self.neutral = neutral
        self.format = format
    }

    public var body: some View {
        HStack(spacing: 12) {
            // Stepped by rounding, not `step:` — AppKit draws a tick per step otherwise.
            Slider(value: Binding(get: { value }, set: { value = (($0 / step).rounded() * step).clamped(to: range) }), in: range)
                .tint(Tokens.accent)
                .frame(width: 180)
                .labelsHidden()
            Text(format(value))
                .font(Fonts.micro)
                .foregroundStyle(Tokens.textSecondary)
                .frame(minWidth: 44, alignment: .trailing)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { if let neutral { value = neutral } }
                .help(neutral == nil ? "" : "Double-click to reset")
        }
    }
}

/// "− 4 +": a bordered stepper for small integer settings.
public struct ShepherdStepper: View {
    @Binding var value: Int
    let range: ClosedRange<Int>

    public init(value: Binding<Int>, in range: ClosedRange<Int>) {
        _value = value
        self.range = range
    }

    public var body: some View {
        HStack(spacing: 0) {
            button("minus", enabled: value > range.lowerBound) { value -= 1 }
            Tokens.borderStrong.frame(width: 1)
            Text("\(value)").font(Fonts.micro).foregroundStyle(Tokens.text).frame(width: 34)
            Tokens.borderStrong.frame(width: 1)
            button("plus", enabled: value < range.upperBound) { value += 1 }
        }
        .frame(height: Metrics.fieldHeight)
        .background(Tokens.bgRaised, in: RoundedRectangle(cornerRadius: Radius.button))
        .overlay(RoundedRectangle(cornerRadius: Radius.button).strokeBorder(Tokens.borderStrong, lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityValue("\(value)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: if value < range.upperBound { value += 1 }
            case .decrement: if value > range.lowerBound { value -= 1 }
            @unknown default: break
            }
        }
    }

    private func button(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                .foregroundStyle(enabled ? Tokens.text : Tokens.textDisabled)
                .frame(width: 30, height: Metrics.fieldHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double { min(max(self, range.lowerBound), range.upperBound) }
}
