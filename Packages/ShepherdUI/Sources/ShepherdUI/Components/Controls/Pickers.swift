import SwiftUI

/// The segmented picker for scopes and view modes, 2–4 options (Controls board; at `m` under
/// `.shControlScale(.settings)`, the Settings boards' filled track). SwiftUI has no
/// public custom `PickerStyle`, so this draws the Shepherd Design track and represents itself to
/// accessibility as a native segmented `Picker`, keeping its semantics.
public struct SHSegmentedPicker<Value: Hashable>: View {
    /// m 24 (default), s 20.
    public enum Size: Sendable { case s, m }

    @Binding var selection: Value
    let label: String
    let options: [(value: Value, title: String)]
    let size: Size
    @Namespace private var pill
    @State private var accessibilitySize: CGSize = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    @Environment(\.shControlScale) private var scale

    public init(_ label: String = "", selection: Binding<Value>, options: [(Value, String)], size: Size = .m) {
        _selection = selection
        self.label = label
        self.options = options.map { (value: $0.0, title: $0.1) }
        self.size = size
    }

    public var body: some View {
        let sh = Color.sh
        // The Settings boards' track: 26pt segments on a filled track, the chosen one lifted on
        // the page's own fill. `s` keeps the Controls board's anatomy everywhere.
        let settings = scale == .settings && size == .m
        let M = SHSettingsControlMetrics.self
        let pillRadius = settings ? M.segmentRadius : SH.Radius.xs
        let trackRadius = settings ? M.segmentTrackRadius : SH.Radius.s
        HStack(spacing: SH.Space.xxs) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.title)
                        .font(.shSans(12, selected ? .semibold : .medium))
                        .foregroundStyle(selected ? sh.textPrimary : sh.textSecondary)
                        .lineLimit(1)
                        .padding(.horizontal, settings ? M.segmentPadding : size == .s ? SH.Space.m : 10)
                        .frame(height: settings ? M.segmentHeight : size == .s ? 20 : SH.Height.controlS)
                        .matchedGeometryEffect(id: option.value, in: pill)
                        .contentShape(Rectangle())
                        .shFocusRing(radius: pillRadius)
                }
                .buttonStyle(.plain)
            }
        }
        .background {
            // One pill behind every segment takes the selected one's frame, so it slides under
            // the labels between. Under Reduce Motion each selection gets its own pill, and they
            // cross-fade in place.
            if options.contains(where: { $0.value == selection }) {
                Group {
                    if settings {
                        RoundedRectangle(cornerRadius: pillRadius).fill(sh.bgWindow)
                            .shadow(color: sh.knobShadow, radius: 1, y: 1)
                    } else {
                        RoundedRectangle(cornerRadius: pillRadius).fill(sh.bgSelected)
                            .shBorder(sh.lineStrong, radius: pillRadius)
                    }
                }
                // Dimmed with the disabled segments, as a plain button dims its label.
                .opacity(enabled ? 1 : 0.5)
                .matchedGeometryEffect(id: selection, in: pill, isSource: false)
                .id(reduceMotion ? AnyHashable(selection) : AnyHashable(Self.pillID))
            }
        }
        .padding(settings ? M.segmentTrackPadding : SH.Space.xxs)
        .background(settings ? sh.lineSubtle : sh.bgSunken, in: RoundedRectangle(cornerRadius: trackRadius))
        .shBorder(settings ? .clear : sh.lineSubtle, radius: trackRadius)
        .fixedSize()
        // Disabled while what it switches loads (the review's Local | PR): the segments and the
        // pill dim and come back as a fade, like every other control.
        .shComponentAnimation(.hover, value: enabled)
        // A click, ⇥ in the palette, or the value changing elsewhere: the pill moves however the
        // value did, and what the value drives outside the picker is left alone.
        .shComponentAnimation(.content, value: selection)
        .onGeometryChange(for: CGSize.self, of: \.size) { accessibilitySize = $0 }
        .accessibilityRepresentation {
            Picker(label, selection: $selection) {
                ForEach(options, id: \.value) { Text($0.title).tag($0.value) }
            }
            .pickerStyle(.segmented)
            .frame(width: accessibilitySize.width, height: accessibilitySize.height)
        }
    }

    private static var pillID: String { "selection" }
}

/// A radio group (Controls board): rare, so prefer segmented or a popup. 14pt circles, off
/// `bgRaised` with a 1.5pt `lineStrong` ring, on `lantern` with a 6pt `textOnLantern` center, each
/// label 8pt after its circle. Drawn here and represented to accessibility as a native `Picker`
/// (a radio group on the Mac), since SwiftUI has no public custom `PickerStyle`.
public struct SHRadioGroup<Value: Hashable>: View {
    @Binding var selection: Value
    let label: String
    let options: [(value: Value, title: String)]
    @Environment(\.isEnabled) private var enabled

    public init(_ label: String = "", selection: Binding<Value>, options: [(Value, String)]) {
        _selection = selection
        self.label = label
        self.options = options.map { (value: $0.0, title: $0.1) }
    }

    public var body: some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: SH.Space.m) {
            ForEach(options, id: \.value) { option in
                let on = option.value == selection
                Button { selection = option.value } label: {
                    HStack(spacing: SH.Space.m) {
                        ZStack {
                            Circle().fill(on ? sh.lantern : sh.bgRaised)
                            if on {
                                Circle().fill(sh.textOnLantern).frame(width: 6, height: 6)
                            } else {
                                Circle().strokeBorder(sh.lineStrong, lineWidth: 1.5)
                            }
                        }
                        .frame(width: 14, height: 14)
                        // Only the circle animates; the label never moves.
                        .shComponentAnimation(.content, value: on)
                        .shFocusRingCircle()
                        Text(option.title)
                            .font(.sh(.ui))
                            .foregroundStyle(sh.textPrimary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .shEnabledOpacity(enabled)
        .accessibilityRepresentation {
            Picker(label, selection: $selection) {
                ForEach(options, id: \.value) { Text($0.title).tag($0.value) }
            }
            #if os(macOS)
            .pickerStyle(.radioGroup)
            #else
            .pickerStyle(.inline)
            #endif
        }
    }
}

/// The popup for longer option lists (Controls board): raised, 1px strong line, a chevron, 28pt,
/// at least 200pt wide.
/// A native `Menu` with a Shepherd Design label, so its items are real menu items.
public struct SHPopupMenu<Content: View>: View {
    let title: String
    let mono: Bool
    let minWidth: CGFloat
    @ViewBuilder let content: () -> Content

    public init(_ title: String, mono: Bool = false, minWidth: CGFloat = 200, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.mono = mono
        self.minWidth = minWidth
        self.content = content
    }

    @Environment(\.shControlScale) private var scale

    public var body: some View {
        Menu(content: content) { SHPopupLabel(title, mono: mono) }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            // The Settings boards size a popup to its value.
            .frame(minWidth: scale == .settings ? nil : minWidth)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityValue(title)
    }
}

/// The popup's label, for a `Menu` built by hand.
public struct SHPopupLabel: View {
    let title: String
    let mono: Bool

    public init(_ title: String, mono: Bool = false) {
        self.title = title
        self.mono = mono
    }

    @Environment(\.shControlScale) private var scale

    public var body: some View {
        let sh = Color.sh
        if scale == .settings {
            // The Settings boards' popup: 32pt at radius 7, the value in Geist 13 and up-down
            // chevrons, sized to its value.
            let M = SHSettingsControlMetrics.self
            HStack(spacing: M.popupGap) {
                Text(title)
                    .font(mono ? .shMono(12.5) : .shSans(M.textSize))
                    .foregroundStyle(sh.textPrimary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(sh.textTertiary)
            }
            .padding(.leading, M.popupLeading)
            .padding(.trailing, M.popupTrailing)
            .frame(height: M.controlHeight)
            .background(sh.bgRaised, in: RoundedRectangle(cornerRadius: M.radius))
            .shBorder(sh.lineStrong, radius: M.radius)
            .contentShape(Rectangle())
        } else {
            HStack(spacing: SH.Space.m) {
                Text(title)
                    .font(mono ? .shMono(12) : .shSans(12))
                    .foregroundStyle(sh.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(sh.textTertiary)
            }
            .padding(.leading, 10)
            .padding(.trailing, SH.Space.m)
            .frame(height: SH.Height.controlM)
            .background(sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Radius.s))
            .shBorder(sh.lineStrong, radius: SH.Radius.s)
            .contentShape(Rectangle())
        }
    }
}

/// A slider with its value in mono beside it ("105%", "239 pt"), drawn per the Controls board:
/// a 3pt `lineStrong` track filled with lantern up to a 14pt knob. Double-clicking the value
/// restores `neutral` when one is given. SwiftUI has no public slider style, so this represents
/// itself to accessibility as a native `Slider` (adjustable, reading the formatted value) and
/// takes ← → while focused.
public struct SHValueSlider: View {
    @Binding var value: Double
    let label: String
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String
    /// What VoiceOver reads after the drawn number when the board draws it bare ("percent", "points").
    let unit: String?
    let neutral: Double?
    let editingChanged: ((Bool) -> Void)?
    /// Bumped by each reset, the one change that animates: a drag or an arrow key tracks at once.
    @State private var resets = 0
    @Environment(\.shControlScale) private var scale

    /// `onEditingChanged` hears a drag begin (true) and end (false), as a native slider's does;
    /// an arrow key or a reset is a change that begins and ends at once.
    public init(_ label: String = "", value: Binding<Double>, in range: ClosedRange<Double>, step: Double,
                neutral: Double? = nil, unit: String? = nil, format: @escaping (Double) -> String,
                onEditingChanged: ((Bool) -> Void)? = nil) {
        _value = value
        self.unit = unit
        self.label = label
        self.range = range
        self.step = step
        self.neutral = neutral
        self.format = format
        editingChanged = onEditingChanged
    }

    public var body: some View {
        HStack(spacing: SH.Space.l) {
            SHSliderTrack(value: $value, range: range, step: step, editingChanged: editingChanged)
                .accessibilityRepresentation {
                    Slider(value: $value, in: range, step: step) { Text(label) }
                        .accessibilityValue(spoken(value))
                        .accessibilityActions {
                            if let neutral { Button("Reset to \(spoken(neutral))") { reset(to: neutral) } }
                        }
                }
            Text(format(value))
                .font(scale == .settings ? .shMono(12) : .sh(.mono))
                .foregroundStyle(.sh.textSecondary)
                .shContentTransition(.numeric())
                .frame(minWidth: SHSliderMetrics.valueMinWidth, alignment: .trailing)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { if let neutral { reset(to: neutral) } }
                .help(neutral == nil ? "" : "Double-click to reset")
                .accessibilityHidden(true)
        }
        // Scoped to the slider: what the value drives elsewhere (text size, density, a sidebar's
        // width) still changes at once.
        .shComponentAnimation(.content, value: resets)
        // Resetting the text size moves everything around the slider at once; it moves with it.
        .geometryGroup()
    }

    private func spoken(_ value: Double) -> String { format(value) + (unit.map { " \($0)" } ?? "") }

    private func reset(to neutral: Double) {
        guard value != neutral else { return }
        editingChanged?(true)
        value = neutral
        resets += 1
        editingChanged?(false)
    }
}

enum SHSliderMetrics {
    static let width: CGFloat = 200
    static let height: CGFloat = 16
    static let track: CGFloat = 3
    static let knob: CGFloat = 14
    static let valueMinWidth: CGFloat = 44
}

private struct SHSliderTrack: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let editingChanged: ((Bool) -> Void)?
    @State private var dragging = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.displayScale) private var displayScale
    @Environment(\.shControlScale) private var scale

    var body: some View {
        let sh = Color.sh
        // The Settings boards' slider: 180pt, a 4pt `lineSubtle` track, an 18pt knob in a 1px line.
        let settings = scale == .settings
        let M = SHSettingsControlMetrics.self
        let knob = settings ? M.sliderKnob : SHSliderMetrics.knob
        let track = settings ? M.sliderTrack : SHSliderMetrics.track
        let width = settings ? M.sliderWidth : SHSliderMetrics.width
        let height = max(SHSliderMetrics.height, knob)
        // The Controls board keeps the knob inside the track; the Settings boards center it on
        // the value, so it overhangs either end by half its width.
        let inset = settings ? 0 : knob
        GeometryReader { geo in
            let usable = max(1, geo.size.width - inset)
            let x = CGFloat(fraction) * usable
            let filled = settings ? x : x + knob / 2
            ZStack(alignment: .leading) {
                Capsule().fill(settings ? sh.lineSubtle : sh.lineStrong).frame(height: track)
                Capsule().fill(sh.lantern).frame(width: filled, height: track)
                // A hairline ring outside the knob, as the board's 1px spread shadow draws.
                Circle()
                    .fill(sh.knobOn)
                    .padding(settings ? SH.hairline(displayScale) : 0)
                    .background { Circle().fill(sh.lineStrong).padding(settings ? 0 : -SH.hairline(displayScale)) }
                    .shadow(color: sh.knobShadow, radius: 1.5, y: 1)
                    .frame(width: knob, height: knob)
                    .offset(x: settings ? x - knob / 2 : x)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                if !dragging {
                    dragging = true
                    editingChanged?(true)
                }
                let position = Double((drag.location.x - inset / 2) / usable)
                set(range.lowerBound + position * (range.upperBound - range.lowerBound))
            }.onEnded { _ in
                dragging = false
                editingChanged?(false)
            })
        }
        .frame(width: width, height: height)
        .shEnabledOpacity(enabled)
        .shFocusRing(radius: height / 2)
        // Keyboard navigation only, like a native slider: a click must not take focus or ring it.
        .focusable(interactions: .activate)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { nudge(by: -step); return .handled }
        .onKeyPress(.rightArrow) { nudge(by: step); return .handled }
    }

    private var fraction: Double {
        let span = range.upperBound - range.lowerBound
        return span > 0 ? min(1, max(0, (value - range.lowerBound) / span)) : 0
    }

    /// An arrow key: one change, begun and ended at once.
    private func nudge(by delta: Double) {
        editingChanged?(true)
        set(value + delta)
        editingChanged?(false)
    }

    private func set(_ proposed: Double) {
        let stepped = ((proposed / step).rounded() * step).clamped(to: range)
        if stepped != value { value = stepped }
    }
}

/// "− 3M tok +": a bordered stepper for small integer settings (Controls board). SwiftUI has no
/// public stepper style, so this draws the control and represents itself to accessibility as a
/// native `Stepper` (adjustable, with its value).
public struct SHStepper: View {
    @Binding var value: Int
    let label: String
    let range: ClosedRange<Int>
    let format: (Int) -> String
    /// Which way the digits roll: down after −.
    @State private var countsDown = false

    public init(_ label: String = "", value: Binding<Int>, in range: ClosedRange<Int>, format: @escaping (Int) -> String = { "\($0)" }) {
        _value = value
        self.label = label
        self.range = range
        self.format = format
    }

    @Environment(\.shControlScale) private var scale

    public var body: some View {
        let sh = Color.sh
        // The Settings boards' stepper: 30pt tall at radius 7, 30pt buttons around a 34pt value
        // in mono 13, `lineSubtle` rules between.
        let settings = scale == .settings
        let M = SHSettingsControlMetrics.self
        let height = settings ? M.stepperHeight : 26
        let radius = settings ? M.radius : SH.Radius.s
        HStack(spacing: 0) {
            button("minus", label: "Less", enabled: value > range.lowerBound, height: height) {
                countsDown = true
                value -= 1
            }
            Text(format(value))
                .font(.shMono(settings ? M.textSize : 12))
                .foregroundStyle(sh.textPrimary)
                .shContentTransition(.numeric(countsDown: countsDown))
                .shComponentAnimation(.content, value: value)
                .frame(minWidth: settings ? M.stepperValueWidth : 52)
                .frame(height: height)
                .overlay(alignment: .leading) { SHHairline(.vertical, color: settings ? sh.lineSubtle : nil) }
                .overlay(alignment: .trailing) { SHHairline(.vertical, color: settings ? sh.lineSubtle : nil) }
            button("plus", label: "More", enabled: value < range.upperBound, height: height) {
                countsDown = false
                value += 1
            }
        }
        .background(sh.bgRaised, in: RoundedRectangle(cornerRadius: radius))
        .shBorder(sh.lineStrong, radius: radius)
        .fixedSize()
        .accessibilityRepresentation {
            Stepper(label, value: $value, in: range)
                .accessibilityValue(format(value))
        }
    }

    private func button(_ symbol: String, label: String, enabled: Bool, height: CGFloat, action: @escaping () -> Void) -> some View {
        let settings = scale == .settings
        let M = SHSettingsControlMetrics.self
        return Button(action: action) {
            Image(systemName: symbol).font(.system(size: settings ? M.stepperGlyphSize : 10, weight: .semibold))
                .foregroundStyle(.sh.textSecondary)
                .shEnabledOpacity(enabled)
                .frame(width: settings ? M.stepperButtonWidth : SH.Height.controlS, height: height)
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
