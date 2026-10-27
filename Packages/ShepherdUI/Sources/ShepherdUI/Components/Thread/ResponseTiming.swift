import SwiftUI

/// What a reply's Response timing shows (ResponseVisibility › C), as plain words the host app
/// derived once: the total from the send to the end, the phases back to back, the moments since
/// the send, and the usage the provider reported.
public struct SHResponseTimingModel: Equatable, Sendable {
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
enum SHResponseTimingMetrics {
    static let rowHeight: CGFloat = 22
    static let labelSize: CGFloat = 12
    static let axisSize: CGFloat = 10
    static let totalTracking: CGFloat = -0.44
    static let sectionTracking: CGFloat = 0.6
}

/// The Response timing popover (ResponseVisibility › C), 300pt like the context details: its
/// title and source, the total, a bar of the phases over a 0 to end axis, then Phases, Since the
/// request was sent, Usage, and the note. Nothing in it is pressed.
public struct SHResponseTiming: View {
    let model: SHResponseTimingModel
    let fillsWidth: Bool

    public init(_ model: SHResponseTimingModel, fillsWidth: Bool = false) {
        self.model = model
        self.fillsWidth = fillsWidth
    }

    public static let title = "Response timing"
    public var body: some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
                Text(Self.title).font(.sh(.ui, weight: .semibold)).foregroundStyle(sh.textPrimary)
                Spacer(minLength: SH.Space.m)
                if let source = model.source {
                    Text(source).font(.sh(.micro, weight: .regular)).foregroundStyle(sh.textTertiary).lineLimit(1).truncationMode(.middle)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: SH.Space.s) {
                Text(model.total).font(.shSans(SHContextMetrics.totalSize, .semibold)).tracking(SHResponseTimingMetrics.totalTracking).foregroundStyle(sh.textPrimary)
                    .monospacedDigit()
                Text("request sent to response ended").font(.shSans(SHResponseTimingMetrics.labelSize)).foregroundStyle(sh.textSecondary)
            }
            .padding(.top, SH.Space.s)
            .accessibilityElement(children: .combine)
            if !model.segments.isEmpty {
                bar.padding(.top, SH.Space.m + SH.Space.xxs)
                HStack {
                    Text("0s")
                    Spacer()
                    Text(model.axisEnd)
                }
                .font(.shMono(SHResponseTimingMetrics.axisSize)).foregroundStyle(sh.textTertiary)
                .padding(.top, SH.Space.xs)
                .accessibilityHidden(true)
                section("Phases")
                ForEach(model.segments) { segment in
                    row(segment.label, value: segment.value, swatch: Self.color(segment.tone, sh))
                }
            }
            section("Since the request was sent")
            ForEach(model.marks) { mark in
                row(mark.label, value: mark.value, quiet: !mark.measured)
            }
            if let usage = model.usage {
                section("Usage")
                HStack(spacing: SH.Space.m) {
                    Text("Reported at the end").font(.shSans(SHResponseTimingMetrics.labelSize)).foregroundStyle(sh.textSecondary)
                    Spacer(minLength: SH.Space.m)
                    Text(usage).font(.sh(.micro, weight: .regular)).foregroundStyle(sh.textTertiary)
                }
                .frame(minHeight: SHResponseTimingMetrics.rowHeight)
                .accessibilityElement(children: .combine)
            }
            Text(model.note).font(.sh(.caption)).lineSpacing(SH.Space.xxs).foregroundStyle(sh.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, SH.Space.m + SH.Space.xxs)
        }
        .padding(.top, SH.Space.l)
        .padding(.bottom, SH.Space.l)
        .padding(.horizontal, SHContextMetrics.side)
        .frame(width: fillsWidth ? nil : SHContextMetrics.detailsNarrowWidth, alignment: .leading)
        .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
        .background(sh.bgRaised)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.title)
    }

    /// The phases back to back, each its share of the total, 1.5pt apart.
    private var bar: some View {
        let sh = Color.sh
        let height = SHContextMetrics.barHeight
        let total = max(model.segments.reduce(0) { $0 + $1.seconds }, 0.001)
        return GeometryReader { geo in
            let room = max(0, geo.size.width - SHContextMetrics.barGap * CGFloat(model.segments.count - 1))
            HStack(spacing: SHContextMetrics.barGap) {
                ForEach(model.segments) { segment in
                    Rectangle().fill(Self.color(segment.tone, sh)).frame(width: max(1, room * segment.seconds / total))
                }
            }
        }
        .frame(height: height)
        .background(sh.lineSubtle)
        .clipShape(RoundedRectangle(cornerRadius: height / 2))
        .accessibilityHidden(true)
    }

    /// A section's mono caps label over a hairline.
    private func section(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SHHairline()
            Text(title).textCase(.uppercase).font(.sh(.micro)).tracking(SHResponseTimingMetrics.sectionTracking).foregroundStyle(Color.sh.textTertiary)
                .padding(.top, SH.Space.m + SH.Space.xxs)
                .padding(.bottom, SH.Space.xs)
                .accessibilityAddTraits(.isHeader)
        }
        .padding(.top, SH.Space.l)
    }

    private func row(_ label: String, value: String, swatch: Color? = nil, quiet: Bool = false) -> some View {
        let sh = Color.sh
        return HStack(spacing: SH.Space.m) {
            if let swatch {
                RoundedRectangle(cornerRadius: SH.Space.xxs).fill(swatch).frame(width: SHContextMetrics.swatch, height: SHContextMetrics.swatch)
            }
            Text(label).font(.shSans(SHResponseTimingMetrics.labelSize)).foregroundStyle(sh.textSecondary).lineLimit(1)
            Spacer(minLength: SH.Space.m)
            Text(value).font(.sh(.mono)).foregroundStyle(quiet ? sh.textTertiary : sh.textPrimary).monospacedDigit()
        }
        .frame(minHeight: SHResponseTimingMetrics.rowHeight)
        .accessibilityElement(children: .combine)
    }

    static func color(_ tone: SHResponseTimingModel.Tone, _ sh: SHPalette) -> Color {
        switch tone {
        case .waiting: sh.textTertiary
        case .thinking: sh.contextReasoning
        case .writing: sh.contextMessages
        case .other: sh.contextOther
        }
    }
}

#if os(iOS)
/// The same timing details in a popover at regular width, or a fitted, scrollable sheet at
/// compact width. Like Context, the sheet can grow to the scene's full available height.
struct SHResponseTimingPresentation: View {
    let model: SHResponseTimingModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dismiss) private var dismiss
    @State private var height: CGFloat = 0
    @State private var detent: PresentationDetent = .medium

    var body: some View {
        ScrollView {
            SHResponseTiming(model, fillsWidth: sizeClass == .compact)
                .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded(.up) } action: { new in
                    let fitted = detent != .large
                    height = new
                    if fitted { detent = .height(new) }
                }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(idealWidth: SHContextMetrics.detailsNarrowWidth)
        .presentationDetents(height > 0 ? [.height(height), .large] : [.medium, .large], selection: $detent)
        .presentationSizing(.form.fitted(horizontal: false, vertical: true))
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.sh.bgRaised)
        .background(Color.sh.bgRaised)
        .background {
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .hidden()
        }
    }
}
#endif
