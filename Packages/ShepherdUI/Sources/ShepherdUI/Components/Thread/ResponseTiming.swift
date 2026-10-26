import SwiftUI

/// What a reply's Response timing shows (ResponseVisibility › C), as plain words the host app
/// derived once: the total from the send to the end, the phases back to back, the moments since
/// the send, and the usage the provider reported.
public struct NWResponseTimingModel: Equatable, Sendable {
    /// A phase's swatch and bar color: the wait in `textTertiary`, thinking in the reasoning cyan,
    /// the reply in the messages blue, anything else in `lineStrong`. Swatches only, never text.
    public enum Tone: Equatable, Sendable { case waiting, thinking, writing, other }

    public struct Segment: Equatable, Sendable, Identifiable {
        public var label: String
        public var value: String
        public var seconds: Double
        public var tone: Tone
        public var id: String { label }

        public init(label: String, value: String, seconds: Double, tone: Tone) {
            self.label = label
            self.value = value
            self.seconds = seconds
            self.tone = tone
        }
    }

    public struct Mark: Equatable, Sendable, Identifiable {
        public var label: String
        public var value: String
        /// False for "Not measured" and "None": quieter.
        public var measured: Bool
        public var id: String { label }

        public init(label: String, value: String, measured: Bool = true) {
            self.label = label
            self.value = value
            self.measured = measured
        }
    }

    /// "claude-opus-4-5 · Anthropic".
    public var source: String?
    /// "45.0s".
    public var total: String
    public var totalSeconds: Double
    /// "45s", the axis' end.
    public var axisEnd: String
    /// Empty when the phases can't be told apart: no bar, no Phases.
    public var segments: [Segment]
    public var marks: [Mark]
    /// "14.2k in · 2.9k out"; nil leaves Usage out.
    public var usage: String?
    public var note: String

    public init(source: String?, total: String, totalSeconds: Double, axisEnd: String, segments: [Segment], marks: [Mark],
                usage: String?, note: String) {
        self.source = source
        self.total = total
        self.totalSeconds = totalSeconds
        self.axisEnd = axisEnd
        self.segments = segments
        self.marks = marks
        self.usage = usage
        self.note = note
    }
}

/// ResponseVisibility C's dimensions outside the shared type ramp.
enum NWResponseTimingMetrics {
    static let rowHeight: CGFloat = 22
    static let labelSize: CGFloat = 12
    static let axisSize: CGFloat = 10
    static let totalTracking: CGFloat = -0.44
    static let sectionTracking: CGFloat = 0.6
}

/// The Response timing popover (ResponseVisibility › C), 300pt like the context details: its
/// title and source, the total, a bar of the phases over a 0 to end axis, then Phases, Since the
/// request was sent, Usage, and the note. Nothing in it is pressed.
public struct NWResponseTiming: View {
    let model: NWResponseTimingModel
    let fillsWidth: Bool

    public init(_ model: NWResponseTimingModel, fillsWidth: Bool = false) {
        self.model = model
        self.fillsWidth = fillsWidth
    }

    public static let title = "Response timing"
    public var body: some View {
        let nw = Color.nw
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: NW.Space.m) {
                Text(Self.title).font(.nw(.ui, weight: .semibold)).foregroundStyle(nw.textPrimary)
                Spacer(minLength: NW.Space.m)
                if let source = model.source {
                    Text(source).font(.nw(.micro, weight: .regular)).foregroundStyle(nw.textTertiary).lineLimit(1).truncationMode(.middle)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: NW.Space.s) {
                Text(model.total).font(.nwSans(NWContextMetrics.totalSize, .semibold)).tracking(NWResponseTimingMetrics.totalTracking).foregroundStyle(nw.textPrimary)
                    .monospacedDigit()
                Text("request sent to response ended").font(.nwSans(NWResponseTimingMetrics.labelSize)).foregroundStyle(nw.textSecondary)
            }
            .padding(.top, NW.Space.s)
            .accessibilityElement(children: .combine)
            if !model.segments.isEmpty {
                bar.padding(.top, NW.Space.m + NW.Space.xxs)
                HStack {
                    Text("0s")
                    Spacer()
                    Text(model.axisEnd)
                }
                .font(.nwMono(NWResponseTimingMetrics.axisSize)).foregroundStyle(nw.textTertiary)
                .padding(.top, NW.Space.xs)
                .accessibilityHidden(true)
                section("Phases")
                ForEach(model.segments) { segment in
                    row(segment.label, value: segment.value, swatch: Self.color(segment.tone, nw))
                }
            }
            section("Since the request was sent")
            ForEach(model.marks) { mark in
                row(mark.label, value: mark.value, quiet: !mark.measured)
            }
            if let usage = model.usage {
                section("Usage")
                HStack(spacing: NW.Space.m) {
                    Text("Reported at the end").font(.nwSans(NWResponseTimingMetrics.labelSize)).foregroundStyle(nw.textSecondary)
                    Spacer(minLength: NW.Space.m)
                    Text(usage).font(.nw(.micro, weight: .regular)).foregroundStyle(nw.textTertiary)
                }
                .frame(minHeight: NWResponseTimingMetrics.rowHeight)
                .accessibilityElement(children: .combine)
            }
            Text(model.note).font(.nw(.caption)).lineSpacing(NW.Space.xxs).foregroundStyle(nw.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, NW.Space.m + NW.Space.xxs)
        }
        .padding(.top, NW.Space.l)
        .padding(.bottom, NW.Space.l)
        .padding(.horizontal, NWContextMetrics.side)
        .frame(width: fillsWidth ? nil : NWContextMetrics.detailsNarrowWidth, alignment: .leading)
        .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
        .background(nw.bgRaised)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.title)
    }

    /// The phases back to back, each its share of the total, 1.5pt apart.
    private var bar: some View {
        let nw = Color.nw
        let height = NWContextMetrics.barHeight
        let total = max(model.segments.reduce(0) { $0 + $1.seconds }, 0.001)
        return GeometryReader { geo in
            let room = max(0, geo.size.width - NWContextMetrics.barGap * CGFloat(model.segments.count - 1))
            HStack(spacing: NWContextMetrics.barGap) {
                ForEach(model.segments) { segment in
                    Rectangle().fill(Self.color(segment.tone, nw)).frame(width: max(1, room * segment.seconds / total))
                }
            }
        }
        .frame(height: height)
        .background(nw.lineSubtle)
        .clipShape(RoundedRectangle(cornerRadius: height / 2))
        .accessibilityHidden(true)
    }

    /// A section's mono caps label over a hairline.
    private func section(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            NWHairline()
            Text(title).textCase(.uppercase).font(.nw(.micro)).tracking(NWResponseTimingMetrics.sectionTracking).foregroundStyle(Color.nw.textTertiary)
                .padding(.top, NW.Space.m + NW.Space.xxs)
                .padding(.bottom, NW.Space.xs)
                .accessibilityAddTraits(.isHeader)
        }
        .padding(.top, NW.Space.l)
    }

    private func row(_ label: String, value: String, swatch: Color? = nil, quiet: Bool = false) -> some View {
        let nw = Color.nw
        return HStack(spacing: NW.Space.m) {
            if let swatch {
                RoundedRectangle(cornerRadius: NW.Space.xxs).fill(swatch).frame(width: NWContextMetrics.swatch, height: NWContextMetrics.swatch)
            }
            Text(label).font(.nwSans(NWResponseTimingMetrics.labelSize)).foregroundStyle(nw.textSecondary).lineLimit(1)
            Spacer(minLength: NW.Space.m)
            Text(value).font(.nw(.mono)).foregroundStyle(quiet ? nw.textTertiary : nw.textPrimary).monospacedDigit()
        }
        .frame(minHeight: NWResponseTimingMetrics.rowHeight)
        .accessibilityElement(children: .combine)
    }

    static func color(_ tone: NWResponseTimingModel.Tone, _ nw: NWPalette) -> Color {
        switch tone {
        case .waiting: nw.textTertiary
        case .thinking: nw.contextReasoning
        case .writing: nw.contextMessages
        case .other: nw.contextOther
        }
    }
}

#if os(iOS)
/// The same timing details in a popover at regular width, or a fitted, scrollable sheet at
/// compact width. Like Context, the sheet can grow to the scene's full available height.
struct NWResponseTimingPresentation: View {
    let model: NWResponseTimingModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dismiss) private var dismiss
    @State private var height: CGFloat = 0
    @State private var detent: PresentationDetent = .medium

    var body: some View {
        ScrollView {
            NWResponseTiming(model, fillsWidth: sizeClass == .compact)
                .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded(.up) } action: { new in
                    let fitted = detent != .large
                    height = new
                    if fitted { detent = .height(new) }
                }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(idealWidth: NWContextMetrics.detailsNarrowWidth)
        .presentationDetents(height > 0 ? [.height(height), .large] : [.medium, .large], selection: $detent)
        .presentationSizing(.form.fitted(horizontal: false, vertical: true))
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.nw.bgRaised)
        .background(Color.nw.bgRaised)
        .background {
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .hidden()
        }
    }
}
#endif
