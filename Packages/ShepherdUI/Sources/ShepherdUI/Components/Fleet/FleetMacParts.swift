import SwiftUI

// The Mac Fleet boards' small parts (FleetA, FleetCheck, FleetStates): a segmented control whose chosen segment is a lifted card, a
// quiet text action, and a one-color meter. Plain values in; what a tap does is the caller's.

/// One segment of `SHLiftSegments`: its value, its words and a count after them in the quiet color ("Check 6").
public struct SHLiftSegment<Value: Hashable>: Identifiable {
    public var value: Value
    public var title: String
    public var count: String?
    public var id: Value { value }

    public init(_ value: Value, _ title: String, count: String? = nil) {
        self.value = value
        self.title = title
        self.count = count
    }
}

public enum SHLiftSegmentsStyle: Sendable { case tabs, choice }

/// The boards' `.segc` and `.gfl-seg`: a rounded track, and the chosen segment a raised card on the `lift` shadow. `.tabs` is the page
/// header's (a hover-tinted track, 26pt), `.choice` Send work here (a selected-tinted track).
public struct SHLiftSegments<Value: Hashable>: View {
    public typealias Style = SHLiftSegmentsStyle

    @Binding var selection: Value
    let label: String
    let segments: [SHLiftSegment<Value>]
    let style: Style

    public init(_ label: String, selection: Binding<Value>, segments: [SHLiftSegment<Value>], style: Style = .tabs) {
        _selection = selection
        self.label = label
        self.segments = segments
        self.style = style
    }

    public var body: some View {
        let sh = Color.sh
        let pill = RoundedRectangle(cornerRadius: SH.Radius.s)
        HStack(spacing: SH.Space.xxs) {
            ForEach(segments) { segment in
                let on = segment.value == selection
                Button { selection = segment.value } label: {
                    HStack(spacing: SH.Space.xs) {
                        Text(segment.title)
                            .font(.sh(.caption, weight: on ? .medium : .regular))
                            .foregroundStyle(on ? sh.textPrimary : sh.textSecondary)
                        if let count = segment.count {
                            Text(count).font(.sh(.caption, weight: .regular)).foregroundStyle(sh.textTertiary)
                        }
                    }
                    .lineLimit(1)
                    .padding(.horizontal, style == .tabs ? SH.Space.l - SH.Space.xxs : SH.Space.l)
                    .frame(height: SHLiftSegmentsMetrics.segmentHeight(style))
                    .background {
                        // Every segment keeps its lifted card and shows it while chosen: the tree never changes shape.
                        Color.clear.shLift(pill, fill: sh.bgRaised).opacity(on ? 1 : 0)
                    }
                    .contentShape(pill)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(SH.Space.xxs)
        .background(style == .tabs ? sh.bgHover : sh.bgSelected, in: RoundedRectangle(cornerRadius: SH.Radius.m))
        .fixedSize()
        .shComponentAnimation(.content, value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

enum SHLiftSegmentsMetrics {
    /// The tabs' track is 26pt (2pt padded), Send work here's segments 24pt.
    static func segmentHeight(_ style: SHLiftSegmentsStyle) -> CGFloat { style == .tabs ? 22 : SH.Height.controlS }
}

/// The boards' `.gfl-act`: a word on no fill that takes the hover fill, 13pt semibold. `quiet` is the secondary word (Cancel).
public struct SHTextActionStyle: ButtonStyle {
    let quiet: Bool
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    public init(quiet: Bool = false) { self.quiet = quiet }

    public func makeBody(configuration: Configuration) -> some View {
        let sh = Color.sh
        configuration.label
            .font(.sh(.ui, weight: quiet ? .regular : .semibold))
            .foregroundStyle(quiet ? sh.textSecondary : sh.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, SH.Space.s)
            .padding(.vertical, SH.Space.xs)
            .background(hovering && enabled || configuration.isPressed ? sh.bgHover : Color.clear, in: RoundedRectangle(cornerRadius: SH.Radius.s))
            .opacity(enabled ? 1 : 0.5)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .shFocusRing(radius: SH.Radius.s)
    }
}

extension ButtonStyle where Self == SHTextActionStyle {
    /// A word-only action: a card's Open, a detail's Check…
    public static var shTextAction: SHTextActionStyle { SHTextActionStyle() }
    public static func shTextAction(quiet: Bool) -> SHTextActionStyle { SHTextActionStyle(quiet: quiet) }
}

/// The boards' `.gfl-track`: a rounded track with `fraction` of it filled in the secondary text color.
public struct SHMeter: View {
    let fraction: Double
    let height: CGFloat

    public init(fraction: Double, height: CGFloat) {
        self.fraction = fraction
        self.height = height
    }

    public var body: some View {
        let sh = Color.sh
        let shape = RoundedRectangle(cornerRadius: SH.Radius.xs)
        shape.fill(sh.lineSubtle)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    shape.fill(sh.textSecondary).frame(width: proxy.size.width * min(1, max(0, fraction)))
                }
            }
            .frame(height: height)
            .clipShape(shape)
            .shComponentAnimation(.content, value: fraction)
            .accessibilityHidden(true)
    }
}
