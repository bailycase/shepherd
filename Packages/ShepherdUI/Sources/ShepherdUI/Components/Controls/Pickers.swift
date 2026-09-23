import SwiftUI

/// The segmented picker for scopes and view modes, 2–4 options (Controls board). SwiftUI has no
/// public custom `PickerStyle`, so this draws the Night Watch track and represents itself to
/// accessibility as a native segmented `Picker`, keeping its semantics.
public struct NWSegmentedPicker<Value: Hashable>: View {
    /// m 24 (default), s 20.
    public enum Size: Sendable { case s, m }

    @Binding var selection: Value
    let label: String
    let options: [(value: Value, title: String)]
    let size: Size

    public init(_ label: String = "", selection: Binding<Value>, options: [(Value, String)], size: Size = .m) {
        _selection = selection
        self.label = label
        self.options = options.map { (value: $0.0, title: $0.1) }
        self.size = size
    }

    public var body: some View {
        let nw = Color.nw
        HStack(spacing: NW.Space.xxs) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.title)
                        .font(.nwSans(12, selected ? .semibold : .medium))
                        .foregroundStyle(selected ? nw.textPrimary : nw.textSecondary)
                        .lineLimit(1)
                        .padding(.horizontal, size == .s ? NW.Space.m : 10)
                        .frame(height: size == .s ? 20 : NW.Height.controlS)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: NW.Radius.xs).fill(nw.bgSelected)
                                    .overlay { RoundedRectangle(cornerRadius: NW.Radius.xs).strokeBorder(nw.lineStrong, lineWidth: 1) }
                            }
                        }
                        .contentShape(Rectangle())
                        .nwFocusRing(radius: NW.Radius.xs)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(NW.Space.xxs)
        .background(nw.bgSunken, in: RoundedRectangle(cornerRadius: NW.Radius.s))
        .overlay { RoundedRectangle(cornerRadius: NW.Radius.s).strokeBorder(nw.lineSubtle, lineWidth: 1) }
        .fixedSize()
        .accessibilityRepresentation {
            Picker(label, selection: $selection) {
                ForEach(options, id: \.value) { Text($0.title).tag($0.value) }
            }
            .pickerStyle(.segmented)
        }
    }
}

/// The popup for longer option lists (Controls board): raised, 1px strong line, a chevron, 28pt.
/// A native `Menu` with a Night Watch label, so its items are real menu items.
public struct NWPopupMenu<Content: View>: View {
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
        Menu(content: content) { NWPopupLabel(title, mono: mono) }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .frame(minWidth: minWidth)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityValue(title)
    }
}

/// The popup's label, for a `Menu` built by hand.
public struct NWPopupLabel: View {
    let title: String
    let mono: Bool

    public init(_ title: String, mono: Bool = false) {
        self.title = title
        self.mono = mono
    }

    public var body: some View {
        let nw = Color.nw
        HStack(spacing: NW.Space.m) {
            Text(title)
                .font(mono ? .nwMono(12) : .nwSans(12))
                .foregroundStyle(nw.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(nw.textTertiary)
        }
        .padding(.leading, 10)
        .padding(.trailing, NW.Space.m)
        .frame(height: NW.Height.controlM)
        .background(nw.bgRaised, in: RoundedRectangle(cornerRadius: NW.Radius.s))
        .overlay { RoundedRectangle(cornerRadius: NW.Radius.s).strokeBorder(nw.lineStrong, lineWidth: 1) }
        .contentShape(Rectangle())
    }
}

/// A native slider (lantern) with its value in mono beside it ("105%", "239 pt"). Double-clicking
/// the value restores `neutral` when one is given. VoiceOver reads the formatted value.
public struct NWValueSlider: View {
    @Binding var value: Double
    let label: String
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String
    let neutral: Double?

    public init(_ label: String = "", value: Binding<Double>, in range: ClosedRange<Double>, step: Double,
                neutral: Double? = nil, format: @escaping (Double) -> String) {
        _value = value
        self.label = label
        self.range = range
        self.step = step
        self.neutral = neutral
        self.format = format
    }

    public var body: some View {
        HStack(spacing: NW.Space.l) {
            // Stepped by rounding, not `step:`: AppKit draws a tick per step otherwise.
            Slider(value: Binding(get: { value }, set: { value = (($0 / step).rounded() * step).clamped(to: range) }), in: range) {
                Text(label)
            }
            .labelsHidden()
            .tint(.nw.lantern)
            .frame(width: 180)
            .accessibilityValue(format(value))
            Text(format(value))
                .font(.nw(.mono))
                .foregroundStyle(.nw.textSecondary)
                .frame(minWidth: 44, alignment: .trailing)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { if let neutral { value = neutral } }
                .help(neutral == nil ? "" : "Double-click to reset")
                .accessibilityHidden(true)
        }
    }
}

/// "− 3M tok +": a bordered stepper for small integer settings (Controls board). SwiftUI has no
/// public stepper style, so this draws the control and represents itself to accessibility as a
/// native `Stepper` (adjustable, with its value).
public struct NWStepper: View {
    @Binding var value: Int
    let label: String
    let range: ClosedRange<Int>
    let format: (Int) -> String

    public init(_ label: String = "", value: Binding<Int>, in range: ClosedRange<Int>, format: @escaping (Int) -> String = { "\($0)" }) {
        _value = value
        self.label = label
        self.range = range
        self.format = format
    }

    public var body: some View {
        let nw = Color.nw
        HStack(spacing: 0) {
            button("minus", label: "Less", enabled: value > range.lowerBound) { value -= 1 }
            Text(format(value))
                .font(.nwMono(12))
                .foregroundStyle(nw.textPrimary)
                .frame(minWidth: 52)
                .frame(height: 26)
                .overlay(alignment: .leading) { NWHairline(.vertical) }
                .overlay(alignment: .trailing) { NWHairline(.vertical) }
            button("plus", label: "More", enabled: value < range.upperBound) { value += 1 }
        }
        .background(nw.bgRaised, in: RoundedRectangle(cornerRadius: NW.Radius.s))
        .overlay { RoundedRectangle(cornerRadius: NW.Radius.s).strokeBorder(nw.lineStrong, lineWidth: 1) }
        .fixedSize()
        .accessibilityRepresentation {
            Stepper(label, value: $value, in: range)
                .accessibilityValue(format(value))
        }
    }

    private func button(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.nw.textSecondary)
                .opacity(enabled ? 1 : 0.4)
                .frame(width: NW.Height.controlS, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

extension Double {
    fileprivate func clamped(to range: ClosedRange<Double>) -> Double { min(max(self, range.lowerBound), range.upperBound) }
}
