import SwiftUI

/// The segmented picker for scopes and view modes, 2–4 options (Controls board; at `m` under
/// `.nwControlScale(.settings)`, the Settings boards' filled track). SwiftUI has no
/// public custom `PickerStyle`, so this draws the Night Watch track and represents itself to
/// accessibility as a native segmented `Picker`, keeping its semantics.
public struct NWSegmentedPicker<Value: Hashable>: View {
    /// m 24 (default), s 20.
    public enum Size: Sendable { case s, m }

    @Binding var selection: Value
    let label: String
    let options: [(value: Value, title: String)]
    let size: Size
    @Namespace private var pill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    @Environment(\.nwControlScale) private var scale

    public init(_ label: String = "", selection: Binding<Value>, options: [(Value, String)], size: Size = .m) {
        _selection = selection
        self.label = label
        self.options = options.map { (value: $0.0, title: $0.1) }
        self.size = size
    }

    public var body: some View {
        let nw = Color.nw
        // The Settings boards' track: 26pt segments on a filled track, the chosen one lifted on
        // the page's own fill. `s` keeps the Controls board's anatomy everywhere.
        let settings = scale == .settings && size == .m
        let M = NWSettingsControlMetrics.self
        let pillRadius = settings ? M.segmentRadius : NW.Radius.xs
        let trackRadius = settings ? M.segmentTrackRadius : NW.Radius.s
        HStack(spacing: NW.Space.xxs) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.title)
                        .font(.nwSans(12, selected ? .semibold : .medium))
                        .foregroundStyle(selected ? nw.textPrimary : nw.textSecondary)
                        .lineLimit(1)
                        .padding(.horizontal, settings ? M.segmentPadding : size == .s ? NW.Space.m : 10)
                        .frame(height: settings ? M.segmentHeight : size == .s ? 20 : NW.Height.controlS)
                        .matchedGeometryEffect(id: option.value, in: pill)
                        .contentShape(Rectangle())
                        .nwFocusRing(radius: pillRadius)
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
                        RoundedRectangle(cornerRadius: pillRadius).fill(nw.bgWindow)
                            .shadow(color: nw.knobShadow, radius: 1, y: 1)
                    } else {
                        RoundedRectangle(cornerRadius: pillRadius).fill(nw.bgSelected)
                            .nwBorder(nw.lineStrong, radius: pillRadius)
                    }
                }
                // Dimmed with the disabled segments, as a plain button dims its label.
                .opacity(enabled ? 1 : 0.5)
                .matchedGeometryEffect(id: selection, in: pill, isSource: false)
                .id(reduceMotion ? AnyHashable(selection) : AnyHashable(Self.pillID))
            }
        }
        .padding(settings ? M.segmentTrackPadding : NW.Space.xxs)
        .background(settings ? nw.lineSubtle : nw.bgSunken, in: RoundedRectangle(cornerRadius: trackRadius))
        .nwBorder(settings ? .clear : nw.lineSubtle, radius: trackRadius)
        .fixedSize()
        // Disabled while what it switches loads (the review's Local | PR): the segments and the
        // pill dim and come back as a fade, like every other control.
        .nwComponentAnimation(.hover, value: enabled)
        // A click, ⇥ in the palette, or the value changing elsewhere: the pill moves however the
        // value did, and what the value drives outside the picker is left alone.
        .nwComponentAnimation(.content, value: selection)
        .accessibilityRepresentation {
            Picker(label, selection: $selection) {
                ForEach(options, id: \.value) { Text($0.title).tag($0.value) }
            }
            .pickerStyle(.segmented)
        }
    }

    private static var pillID: String { "selection" }
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

    @Environment(\.nwControlScale) private var scale

    public var body: some View {
        Menu(content: content) { NWPopupLabel(title, mono: mono) }
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
public struct NWPopupLabel: View {
    let title: String
    let mono: Bool

    public init(_ title: String, mono: Bool = false) {
        self.title = title
        self.mono = mono
    }

    @Environment(\.nwControlScale) private var scale

    public var body: some View {
        let nw = Color.nw
        if scale == .settings {
            // The Settings boards' popup: 32pt at radius 7, the value in Geist 13 and up-down
            // chevrons, sized to its value.
            let M = NWSettingsControlMetrics.self
            HStack(spacing: M.popupGap) {
                Text(title)
                    .font(mono ? .nwMono(12.5) : .nwSans(M.textSize))
                    .foregroundStyle(nw.textPrimary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(nw.textTertiary)
            }
            .padding(.leading, M.popupLeading)
            .padding(.trailing, M.popupTrailing)
            .frame(height: M.controlHeight)
            .background(nw.bgRaised, in: RoundedRectangle(cornerRadius: M.radius))
            .nwBorder(nw.lineStrong, radius: M.radius)
            .contentShape(Rectangle())
        } else {
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
            .nwBorder(nw.lineStrong, radius: NW.Radius.s)
            .contentShape(Rectangle())
        }
    }
}

/// A slider with its value in mono beside it ("105%", "239 pt"), drawn per the Controls board:
/// a 3pt `lineStrong` track filled with lantern up to a 14pt knob. Double-clicking the value
/// restores `neutral` when one is given. SwiftUI has no public slider style, so this represents
/// itself to accessibility as a native `Slider` (adjustable, reading the formatted value) and
/// takes ← → while focused.
public struct NWValueSlider: View {
    @Binding var value: Double
    let label: String
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String
    let neutral: Double?
    /// Bumped by each reset, the one change that animates: a drag or an arrow key tracks at once.
    @State private var resets = 0
    @Environment(\.nwControlScale) private var scale

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
            NWSliderTrack(value: $value, range: range, step: step)
                .accessibilityRepresentation {
                    Slider(value: $value, in: range, step: step) { Text(label) }
                        .accessibilityValue(format(value))
                        .accessibilityActions {
                            if let neutral { Button("Reset to \(format(neutral))") { reset(to: neutral) } }
                        }
                }
            Text(format(value))
                .font(scale == .settings ? .nwMono(12) : .nw(.mono))
                .foregroundStyle(.nw.textSecondary)
                .nwContentTransition(.numeric())
                .frame(minWidth: NWSliderMetrics.valueMinWidth, alignment: .trailing)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { if let neutral { reset(to: neutral) } }
                .help(neutral == nil ? "" : "Double-click to reset")
                .accessibilityHidden(true)
        }
        // Scoped to the slider: what the value drives elsewhere (text size, density, a sidebar's
        // width) still changes at once.
        .nwComponentAnimation(.content, value: resets)
        // Resetting the text size moves everything around the slider at once; it moves with it.
        .geometryGroup()
    }

    private func reset(to neutral: Double) {
        guard value != neutral else { return }
        value = neutral
        resets += 1
    }
}

enum NWSliderMetrics {
    static let width: CGFloat = 200
    static let height: CGFloat = 16
    static let track: CGFloat = 3
    static let knob: CGFloat = 14
    static let valueMinWidth: CGFloat = 44
}

private struct NWSliderTrack: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    @Environment(\.isEnabled) private var enabled
    @Environment(\.displayScale) private var displayScale
    @Environment(\.nwControlScale) private var scale

    var body: some View {
        let nw = Color.nw
        // The Settings boards' slider: 180pt, a 4pt `lineSubtle` track, an 18pt knob in a 1px line.
        let settings = scale == .settings
        let M = NWSettingsControlMetrics.self
        let knob = settings ? M.sliderKnob : NWSliderMetrics.knob
        let track = settings ? M.sliderTrack : NWSliderMetrics.track
        let width = settings ? M.sliderWidth : NWSliderMetrics.width
        let height = max(NWSliderMetrics.height, knob)
        // The Controls board keeps the knob inside the track; the Settings boards center it on
        // the value, so it overhangs either end by half its width.
        let inset = settings ? 0 : knob
        GeometryReader { geo in
            let usable = max(1, geo.size.width - inset)
            let x = CGFloat(fraction) * usable
            let filled = settings ? x : x + knob / 2
            ZStack(alignment: .leading) {
                Capsule().fill(settings ? nw.lineSubtle : nw.lineStrong).frame(height: track)
                Capsule().fill(nw.lantern).frame(width: filled, height: track)
                // A hairline ring outside the knob, as the board's 1px spread shadow draws.
                Circle()
                    .fill(nw.knobOn)
                    .padding(settings ? NW.hairline(displayScale) : 0)
                    .background { Circle().fill(nw.lineStrong).padding(settings ? 0 : -NW.hairline(displayScale)) }
                    .shadow(color: nw.knobShadow, radius: 1.5, y: 1)
                    .frame(width: knob, height: knob)
                    .offset(x: settings ? x - knob / 2 : x)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let position = Double((drag.location.x - inset / 2) / usable)
                set(range.lowerBound + position * (range.upperBound - range.lowerBound))
            })
        }
        .frame(width: width, height: height)
        .nwEnabledOpacity(enabled)
        .nwFocusRing(radius: height / 2)
        // Keyboard navigation only, like a native slider: a click must not take focus or ring it.
        .focusable(interactions: .activate)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { set(value - step); return .handled }
        .onKeyPress(.rightArrow) { set(value + step); return .handled }
    }

    private var fraction: Double {
        let span = range.upperBound - range.lowerBound
        return span > 0 ? min(1, max(0, (value - range.lowerBound) / span)) : 0
    }

    private func set(_ proposed: Double) {
        let stepped = ((proposed / step).rounded() * step).clamped(to: range)
        if stepped != value { value = stepped }
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
    /// Which way the digits roll: down after −.
    @State private var countsDown = false

    public init(_ label: String = "", value: Binding<Int>, in range: ClosedRange<Int>, format: @escaping (Int) -> String = { "\($0)" }) {
        _value = value
        self.label = label
        self.range = range
        self.format = format
    }

    @Environment(\.nwControlScale) private var scale

    public var body: some View {
        let nw = Color.nw
        // The Settings boards' stepper: 30pt tall at radius 7, 30pt buttons around a 34pt value
        // in mono 13, `lineSubtle` rules between.
        let settings = scale == .settings
        let M = NWSettingsControlMetrics.self
        let height = settings ? M.stepperHeight : 26
        let radius = settings ? M.radius : NW.Radius.s
        HStack(spacing: 0) {
            button("minus", label: "Less", enabled: value > range.lowerBound, height: height) {
                countsDown = true
                value -= 1
            }
            Text(format(value))
                .font(.nwMono(settings ? M.textSize : 12))
                .foregroundStyle(nw.textPrimary)
                .nwContentTransition(.numeric(countsDown: countsDown))
                .nwComponentAnimation(.content, value: value)
                .frame(minWidth: settings ? M.stepperValueWidth : 52)
                .frame(height: height)
                .overlay(alignment: .leading) { NWHairline(.vertical, color: settings ? nw.lineSubtle : nil) }
                .overlay(alignment: .trailing) { NWHairline(.vertical, color: settings ? nw.lineSubtle : nil) }
            button("plus", label: "More", enabled: value < range.upperBound, height: height) {
                countsDown = false
                value += 1
            }
        }
        .background(nw.bgRaised, in: RoundedRectangle(cornerRadius: radius))
        .nwBorder(nw.lineStrong, radius: radius)
        .fixedSize()
        .accessibilityRepresentation {
            Stepper(label, value: $value, in: range)
                .accessibilityValue(format(value))
        }
    }

    private func button(_ symbol: String, label: String, enabled: Bool, height: CGFloat, action: @escaping () -> Void) -> some View {
        let settings = scale == .settings
        let M = NWSettingsControlMetrics.self
        return Button(action: action) {
            Image(systemName: symbol).font(.system(size: settings ? M.stepperGlyphSize : 10, weight: .semibold))
                .foregroundStyle(.nw.textSecondary)
                .nwEnabledOpacity(enabled)
                .frame(width: settings ? M.stepperButtonWidth : NW.Height.controlS, height: height)
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
