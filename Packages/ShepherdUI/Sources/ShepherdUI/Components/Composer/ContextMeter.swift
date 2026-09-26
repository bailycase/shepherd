import SwiftUI

/// The context meter's measures (ContextIdeas, ContextDetails, ContextFull, ContextCompacted).
public enum NWContextMetrics {
    /// The ring's circle button, beside Send.
    public static let buttonSize: CGFloat = 32
    /// The ring inside it: a trimmed circle from 12 o'clock with round caps.
    public static let ringSize: CGFloat = 18
    public static let ringStroke: CGFloat = 2.2
    /// How much of the circle the compacting arc spans as it turns.
    public static let compactingSweep: CGFloat = 0.28
    /// The after-compaction ring's dashes.
    public static let ringDash: CGFloat = 1.55
    /// The details popover: 340pt with the split, 300pt otherwise.
    public static let detailsWidth: CGFloat = 340
    public static let detailsNarrowWidth: CGFloat = 300
    public static let side: CGFloat = 14
    public static let totalSize: CGFloat = 22
    public static let barHeight: CGFloat = 8
    public static let barGap: CGFloat = 1.5
    public static let markWidth: CGFloat = 1.5
    public static let markHeight: CGFloat = 14
    /// The estimate's dashes along the bar.
    public static let barDash: CGFloat = 4
    public static let barDashGap: CGFloat = 3
    public static let rowHeight: CGFloat = 26
    public static let swatch: CGFloat = 8
    public static let largestHeaderHeight: CGFloat = 22
    public static let largestInset: CGFloat = 6
    public static let buttonHeight: CGFloat = 30
    public static let keepMinHeight: CGFloat = 52
    public static let icon: CGFloat = 12
    /// A sheet's own inset above the header (iPad and iPhone): clear of the drag indicator.
    public static let sheetTop: CGFloat = NW.Space.xxl
}

/// The ring's fill, by how full the window is: `calm` under 60%, `warning` to 85%, `critical`
/// past it.
public enum NWContextTone: Equatable, Sendable {
    case calm, warning, critical
}

public enum NWContextRingState: Equatable, Sendable {
    /// No number yet: the track alone.
    case empty
    /// The fraction of the window, 0...1.
    case fill(Double, NWContextTone)
    /// A `running` arc that turns while the agent compacts.
    case compacting
    /// Dashed until the agent's next reply gives a real number.
    case estimated
}

/// The 18pt context ring (ContextIdeas › The ring): a trimmed circle, 2.2pt stroke, round caps,
/// starting at 12 o'clock, over a `lineStrong` track.
public struct NWContextRing: View {
    let state: NWContextRingState
    let size: CGFloat

    public init(_ state: NWContextRingState, size: CGFloat = NWContextMetrics.ringSize) {
        self.state = state
        self.size = size
    }

    public var body: some View {
        let nw = Color.nw
        let stroke = NWContextMetrics.ringStroke
        let inset = stroke / 2
        ZStack {
            switch state {
            case .estimated:
                Circle().inset(by: inset)
                    .stroke(nw.textSecondary.opacity(0.8),
                            style: StrokeStyle(lineWidth: stroke, dash: [NWContextMetrics.ringDash, NWContextMetrics.ringDash]))
            case .empty:
                Circle().inset(by: inset).stroke(nw.lineStrong, lineWidth: stroke)
            case .fill(let fraction, let tone):
                Circle().inset(by: inset).stroke(nw.lineStrong, lineWidth: stroke)
                Circle().inset(by: inset)
                    .trim(from: 0, to: max(0, min(1, fraction)))
                    .stroke(Self.color(tone, nw), style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            case .compacting:
                Circle().inset(by: inset).stroke(nw.lineStrong, lineWidth: stroke)
                NWLayerSpinner(size: size, color: nw.running, lineWidth: stroke, sweep: NWContextMetrics.compactingSweep)
            }
        }
        .frame(width: size, height: size)
        .nwComponentAnimation(.content, value: state)
        .accessibilityHidden(true)
    }

    static func color(_ tone: NWContextTone, _ nw: NWPalette) -> Color {
        switch tone {
        case .calm: nw.textSecondary
        case .warning: nw.lantern
        case .critical: nw.failed
        }
    }
}

/// The ring in its own 32pt circle button beside Send (ContextIdeas › A). It fills `bgHover`
/// under the pointer and `bgSelected` while its details are open; it never shows text.
public struct NWContextMeterButton: View {
    let state: NWContextRingState
    let expanded: Bool
    let help: String
    let label: String
    let action: () -> Void

    public init(_ state: NWContextRingState, expanded: Bool, help: String, accessibilityLabel: String, action: @escaping () -> Void) {
        self.state = state
        self.expanded = expanded
        self.help = help
        self.label = accessibilityLabel
        self.action = action
    }

    public var body: some View {
        Button(action: action) { NWContextRing(state) }
            .buttonStyle(NWContextMeterStyle(expanded: expanded))
            .help(help)
            .accessibilityLabel(label)
            .accessibilityValue(expanded ? "Details shown" : "")
    }
}

private struct NWContextMeterStyle: ButtonStyle {
    let expanded: Bool

    func makeBody(configuration: Configuration) -> some View {
        MeterBody(configuration: configuration, expanded: expanded)
    }

    private struct MeterBody: View {
        let configuration: Configuration
        let expanded: Bool
        @State private var hovering = false

        var body: some View {
            let nw = Color.nw
            configuration.label
                .frame(width: NWContextMetrics.buttonSize, height: NWContextMetrics.buttonSize)
                .background(Circle().fill(expanded || configuration.isPressed ? nw.bgSelected : hovering ? nw.bgHover : .clear))
                .contentShape(Circle())
                .onHover { hovering = $0 }
                .nwAnimation(.hover, value: hovering)
                .nwFocusRing(radius: NWContextMetrics.buttonSize / 2)
                // A 44pt target on touch; nothing changes on the Mac.
                .nwTouchTarget(height: NWContextMetrics.buttonSize, width: NWContextMetrics.buttonSize)
        }
    }
}

// MARK: - Details

/// What the ring's details show (ContextDetails, ContextFull, ContextIdeas › Click for details).
public struct NWContextDetailsModel: Equatable, Sendable {
    public enum Variant: Equatable, Sendable {
        /// No number yet.
        case empty
        /// The total, the auto-compact mark, and Compact now.
        case simple
        /// Adds what the context is made of and the three largest items.
        case split
        /// Past 85%: the problem first, and a field for what to keep.
        case almostFull
        /// Nothing to press; it closes itself when the agent is done.
        case compacting(startedAt: Date)
        /// The agent's estimate until its next reply.
        case compacted
    }

    public enum Part: Equatable, Sendable { case system, instructions, messages, toolResults }

    public struct Segment: Equatable, Sendable {
        public var part: Part?
        public var fraction: Double
        public init(part: Part?, fraction: Double) { self.part = part; self.fraction = fraction }
    }

    public struct Row: Equatable, Sendable, Identifiable {
        public var part: Part
        public var label: String
        public var value: String
        public var id: String { label }
        public init(part: Part, label: String, value: String) { self.part = part; self.label = label; self.value = value }
    }

    public enum ItemKind: Equatable, Sendable { case file, command, tool }

    public struct Item: Equatable, Sendable, Identifiable {
        public var id: String
        public var kind: ItemKind
        public var label: String
        public var value: String
        public init(id: String, kind: ItemKind, label: String, value: String) {
            self.id = id; self.kind = kind; self.label = label; self.value = value
        }
    }

    public var variant: Variant
    public var title: String
    public var meta: String?
    public var total: String?
    public var ofWindow: String?
    public var trailing: String?
    public var segments: [Segment]
    public var mark: Double?
    public var markLabel: String?
    public var rows: [Row]
    public var free: String?
    public var items: [Item]
    public var note: String?
    /// A part of `note` set in mono (the size being summarized).
    public var emphasis: String?
    public var footnote: String?
    /// Show summary is offered (just compacted).
    public var showsSummary: Bool
    public var compactOffered: Bool

    public init(variant: Variant, title: String, meta: String? = nil, total: String? = nil, ofWindow: String? = nil,
                trailing: String? = nil, segments: [Segment] = [], mark: Double? = nil, markLabel: String? = nil, rows: [Row] = [],
                free: String? = nil, items: [Item] = [], note: String? = nil, emphasis: String? = nil, footnote: String? = nil,
                showsSummary: Bool = false, compactOffered: Bool = true) {
        self.variant = variant
        self.title = title
        self.meta = meta
        self.total = total
        self.ofWindow = ofWindow
        self.trailing = trailing
        self.segments = segments
        self.mark = mark
        self.markLabel = markLabel
        self.rows = rows
        self.free = free
        self.items = items
        self.note = note
        self.emphasis = emphasis
        self.footnote = footnote
        self.showsSummary = showsSummary
        self.compactOffered = compactOffered
    }

    /// 340pt with the split or the almost-full field, 300pt otherwise.
    public var width: CGFloat {
        switch variant {
        case .split, .almostFull: NWContextMetrics.detailsWidth
        default: NWContextMetrics.detailsNarrowWidth
        }
    }
}

/// What the details can do: compact with what to keep, find an item in the thread, and open
/// the latest compaction's summary.
public struct NWContextDetailsActions {
    public var compact: (String) -> Void
    public var find: (String) -> Void
    public var showSummary: () -> Void
    /// Compact now can go (the agent is idle); `compactHelp` says why not.
    public var compactEnabled: Bool
    public var compactHelp: String?

    public init(compact: @escaping (String) -> Void = { _ in }, find: @escaping (String) -> Void = { _ in },
                showSummary: @escaping () -> Void = {}, compactEnabled: Bool = true, compactHelp: String? = nil) {
        self.compact = compact
        self.find = find
        self.showSummary = showSummary
        self.compactEnabled = compactEnabled
        self.compactHelp = compactHelp
    }
}

/// The ring's details (`ContextDetails(.split)` and its states): the total of the window, a bar
/// of what fills it with the auto-compact mark, the split and the largest items, then Compact
/// now. Past 85% it leads with the problem and a field for what the summary should keep; while
/// compacting there is nothing to press; just compacted, the agent's estimate and Show summary.
public struct NWContextDetails: View {
    /// Above the ring on the Mac; a sheet on iPad and iPhone, where a tap opens the details.
    public enum Presentation: Equatable, Sendable {
        /// The board's 340pt (or 300pt) popover, with its own surface.
        case popover
        /// As wide as the sheet, on the sheet's surface, with touch-sized rows and buttons.
        case sheet
    }

    let model: NWContextDetailsModel
    let actions: NWContextDetailsActions
    let presentation: Presentation
    /// Compact now… opens the field for what to keep.
    @State private var composing = false
    @State private var keep = ""
    @FocusState private var keepFocused: Bool

    public init(_ model: NWContextDetailsModel, actions: NWContextDetailsActions, presentation: Presentation = .popover) {
        self.model = model
        self.actions = actions
        self.presentation = presentation
    }

    private var critical: Bool { model.variant == .almostFull }
    private var sheet: Bool { presentation == .sheet }

    public var body: some View {
        let nw = Color.nw
        VStack(alignment: .leading, spacing: 0) {
            header
            switch model.variant {
            case .compacting(let started):
                compactingBody(started)
            default:
                if let total = model.total { totalRow(total) }
                if !model.segments.isEmpty || model.variant == .simple || model.variant == .split { bar }
                if let markLabel = model.markLabel, model.variant != .compacted, model.variant != .empty {
                    Text(markLabel).font(.nwMono(10)).foregroundStyle(nw.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.top, 5).padding(.horizontal, NWContextMetrics.side)
                }
                if let note = model.note { noteText(note) }
                if !model.rows.isEmpty { rows }
                if !model.items.isEmpty { largest }
                if let footnote = model.footnote {
                    Text(footnote).font(.nwSans(11)).lineSpacing(2).foregroundStyle(nw.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, NW.Space.m).padding(.horizontal, NWContextMetrics.side)
                }
                actionsArea
            }
        }
        .modifier(DetailsSurface(presentation: presentation, width: model.width))
        .nwAnimation(.disclosure, value: composing)
    }

    /// The popover's width and surface, or a sheet's full width on the sheet's own surface.
    private struct DetailsSurface: ViewModifier {
        let presentation: Presentation
        let width: CGFloat

        func body(content: Content) -> some View {
            switch presentation {
            case .popover: content.frame(width: width, alignment: .leading).nwPopover()
            case .sheet: content.frame(maxWidth: .infinity, alignment: .leading).padding(.top, NWContextMetrics.sheetTop - NW.Space.l)
            }
        }
    }

    private var header: some View {
        HStack(spacing: NW.Space.m) {
            Text(model.title).font(.nwSans(12.5, .semibold)).foregroundStyle(critical ? Color.nw.failed : Color.nw.textPrimary)
            Spacer(minLength: NW.Space.m)
            if case .compacting(let started) = model.variant {
                TimelineView(.periodic(from: started, by: 1)) { context in
                    Text("started \(Self.clock(from: started, now: context.date)) ago")
                        .font(.nwMono(10.5)).foregroundStyle(Color.nw.textTertiary).monospacedDigit()
                }
            } else if let meta = model.meta {
                Text(meta).font(.nwMono(10.5)).foregroundStyle(Color.nw.textTertiary).lineLimit(1)
            }
        }
        .padding(.top, NW.Space.l).padding(.horizontal, NWContextMetrics.side)
    }

    private func totalRow(_ total: String) -> some View {
        let nw = Color.nw
        let estimate = model.variant == .compacted
        return HStack(alignment: .firstTextBaseline, spacing: NW.Space.s) {
            Text(total).font(.nwSans(NWContextMetrics.totalSize, .semibold)).tracking(-0.44)
                .foregroundStyle(critical ? nw.failed : estimate ? nw.textSecondary : nw.textPrimary)
            if let of = model.ofWindow { Text(of).font(.nwSans(12.5)).foregroundStyle(nw.textSecondary) }
            Spacer(minLength: NW.Space.m)
            if let trailing = model.trailing {
                Text(trailing).font(.nwMono(12)).foregroundStyle(critical ? nw.failed : estimate ? nw.textTertiary : nw.textSecondary)
            }
        }
        .padding(.top, NW.Space.m).padding(.horizontal, NWContextMetrics.side)
    }

    /// The window as a bar: each part's share, a gap of 1.5pt between, and the auto-compact mark.
    private var bar: some View {
        let nw = Color.nw
        let height = NWContextMetrics.barHeight
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2).fill(nw.lineSubtle)
                if model.variant == .compacted, let segment = model.segments.first {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: height / 2))
                        path.addLine(to: CGPoint(x: geo.size.width * segment.fraction, y: height / 2))
                    }
                    .stroke(nw.textTertiary, style: StrokeStyle(lineWidth: height, dash: [NWContextMetrics.barDash, NWContextMetrics.barDashGap]))
                } else {
                    HStack(spacing: NWContextMetrics.barGap) {
                        ForEach(Array(model.segments.enumerated()), id: \.offset) { _, segment in
                            Rectangle().fill(Self.color(segment.part, nw))
                                .frame(width: max(1, geo.size.width * segment.fraction))
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: height / 2))
            .overlay(alignment: .leading) {
                if let mark = model.mark, model.variant != .compacted {
                    RoundedRectangle(cornerRadius: 1).fill(nw.textSecondary)
                        .frame(width: NWContextMetrics.markWidth, height: NWContextMetrics.markHeight)
                        .offset(x: geo.size.width * mark)
                }
            }
        }
        .frame(height: height)
        .padding(.top, 10).padding(.horizontal, NWContextMetrics.side)
        .accessibilityHidden(true)
    }

    private func noteText(_ note: String) -> some View {
        let quiet = model.variant == .compacted || model.variant == .empty
        return Text(note)
            .font(.nwSans(quiet ? 11 : 12.5)).lineSpacing(quiet ? 2 : 3)
            .foregroundStyle(quiet ? Color.nw.textTertiary : Color.nw.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, NW.Space.m).padding(.horizontal, NWContextMetrics.side)
    }

    private var rows: some View {
        let nw = Color.nw
        return VStack(spacing: 0) {
            ForEach(model.rows) { row in
                HStack(spacing: 9) {
                    RoundedRectangle(cornerRadius: 2).fill(Self.color(row.part, nw))
                        .frame(width: NWContextMetrics.swatch, height: NWContextMetrics.swatch)
                    Text(row.label).font(.nwSans(12.5)).foregroundStyle(nw.textPrimary).lineLimit(1)
                    Spacer(minLength: NW.Space.m)
                    Text(row.value).font(.nwMono(11.5)).foregroundStyle(nw.textSecondary)
                }
                .frame(minHeight: NWContextMetrics.rowHeight)
                .padding(.horizontal, NWContextMetrics.side)
            }
            if let free = model.free {
                HStack(spacing: 9) {
                    Color.clear.frame(width: NWContextMetrics.swatch, height: NWContextMetrics.swatch)
                    Text("Free").font(.nwSans(12.5)).foregroundStyle(nw.textTertiary)
                    Spacer(minLength: NW.Space.m)
                    Text(free).font(.nwMono(11.5)).foregroundStyle(nw.textTertiary)
                }
                .frame(minHeight: NWContextMetrics.rowHeight)
                .padding(.horizontal, NWContextMetrics.side)
            }
        }
        .padding(.top, NW.Space.xs)
    }

    private var largest: some View {
        let nw = Color.nw
        return VStack(spacing: 0) {
            HStack {
                Text("Largest").font(.nwMono(10, .medium)).tracking(0.6).textCase(.uppercase)
                Spacer(minLength: NW.Space.m)
                Text(sheet ? "tap to find in thread" : "click to find in thread").font(.nwMono(10))
            }
            .foregroundStyle(nw.textTertiary)
            .frame(height: NWContextMetrics.largestHeaderHeight - NW.Space.s, alignment: .bottom)
            .padding(.top, NW.Space.s)
            .padding(.horizontal, NWContextMetrics.side)
            ForEach(model.items) { item in
                NWContextItemRow(item: item, touch: sheet) { actions.find(item.id) }
            }
        }
    }

    @ViewBuilder private var actionsArea: some View {
        let nw = Color.nw
        switch model.variant {
        case .compacted:
            Button(action: actions.showSummary) {
                Label { Text("Show summary") } icon: { Image(systemName: "text.alignleft").font(.system(size: NWContextMetrics.icon - 2, weight: .medium)) }
            }
            .buttonStyle(NWContextButtonStyle(primary: false, touch: sheet))
            .padding(.top, 10).padding(.horizontal, NWContextMetrics.side).padding(.bottom, NWContextMetrics.side)
        case .empty:
            Color.clear.frame(height: NWContextMetrics.side)
        case .almostFull:
            keepField.padding(.top, 10)
            compactButton(primary: true, title: "Compact now")
                .padding(.top, 10).padding(.horizontal, NWContextMetrics.side).padding(.bottom, NWContextMetrics.side)
        case .simple, .split:
            Rectangle().fill(nw.lineSubtle).frame(height: 1).padding(.top, 10)
            if composing {
                keepField.padding(.top, NW.Space.l)
                compactButton(primary: true, title: "Compact now")
                    .padding(.top, 10).padding(.horizontal, NWContextMetrics.side).padding(.bottom, NWContextMetrics.side)
            } else {
                Button { composing = true; keepFocused = true } label: { compactLabel("Compact now…") }
                    .buttonStyle(NWContextButtonStyle(primary: false, touch: sheet))
                    .disabled(!model.compactOffered || !actions.compactEnabled)
                    .help(actions.compactHelp ?? "")
                    .padding(.top, 10).padding(.horizontal, NWContextMetrics.side).padding(.bottom, NWContextMetrics.side)
            }
        case .compacting:
            EmptyView()
        }
    }

    private var keepField: some View {
        let nw = Color.nw
        return TextField(text: $keep, prompt: Text("What should the summary keep? (optional)").foregroundStyle(nw.textTertiary),
                         axis: .vertical) { Text("What the summary should keep") }
            .textFieldStyle(.plain)
            .font(.nwSans(12.5)).lineSpacing(2)
            .foregroundStyle(nw.textPrimary)
            .tint(nw.lantern)
            .lineLimit(2...5)
            .focused($keepFocused)
            .padding(.vertical, NW.Space.m).padding(.horizontal, 10)
            .frame(minHeight: NWContextMetrics.keepMinHeight, alignment: .topLeading)
            .background(nw.bgWindow, in: RoundedRectangle(cornerRadius: NW.Radius.m))
            .overlay(RoundedRectangle(cornerRadius: NW.Radius.m).strokeBorder(keepFocused ? nw.textTertiary : nw.lineStrong, lineWidth: 1))
            .onSubmit(compact)
            .padding(.horizontal, NWContextMetrics.side)
    }

    private func compactButton(primary: Bool, title: String) -> some View {
        Button(action: compact) { compactLabel(title) }
            .buttonStyle(NWContextButtonStyle(primary: primary, touch: sheet))
            .disabled(!model.compactOffered || !actions.compactEnabled)
            .help(actions.compactHelp ?? "")
    }

    private func compactLabel(_ title: String) -> some View {
        Label { Text(title) } icon: {
            Image(systemName: "arrow.down.right.and.arrow.up.left").font(.system(size: NWContextMetrics.icon - 2, weight: .semibold))
        }
    }

    private func compact() {
        guard model.compactOffered, actions.compactEnabled else { return }
        actions.compact(keep.trimmingCharacters(in: .whitespacesAndNewlines))
        keep = ""
        composing = false
    }

    private func compactingBody(_ started: Date) -> some View {
        let nw = Color.nw
        return VStack(alignment: .leading, spacing: 0) {
            if let note = model.note {
                Self.emphasized(note, model.emphasis).font(.nwSans(12.5)).foregroundStyle(nw.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .nwShimmer()
                    .padding(.top, 10).padding(.horizontal, NWContextMetrics.side)
            }
            // How far along is unknown: the bar eases toward full while it runs.
            TimelineView(.periodic(from: started, by: 0.5)) { context in
                let fraction = Self.progress(from: started, now: context.date)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: NWContextMetrics.barHeight / 2).fill(nw.lineSubtle)
                        RoundedRectangle(cornerRadius: NWContextMetrics.barHeight / 2).fill(nw.running)
                            .frame(width: geo.size.width * fraction)
                    }
                }
                .frame(height: NWContextMetrics.barHeight)
                .nwComponentAnimation(.content, value: fraction)
            }
            .padding(.top, 10).padding(.horizontal, NWContextMetrics.side).padding(.bottom, NWContextMetrics.side)
        }
    }

    /// The compacting bar: pi says nothing of how far along it is, so the bar runs most of the
    /// way in the first seconds (the board's 0:08 is at 92%) and never fills.
    static func progress(from start: Date, now: Date) -> Double {
        let seconds = max(0, now.timeIntervalSince(start))
        return min(0.95, 1 - exp(-seconds / 3))
    }

    /// `note` with `emphasis` (the size being summarized) in mono `textPrimary`.
    static func emphasized(_ note: String, _ emphasis: String?) -> Text {
        guard let emphasis, let range = note.range(of: emphasis) else { return Text(note) }
        return Text(note[..<range.lowerBound])
            + Text(emphasis).font(.nwMono(12.5)).foregroundColor(Color.nw.textPrimary)
            + Text(note[range.upperBound...])
    }

    /// "0:08".
    static func clock(from start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    static func color(_ part: NWContextDetailsModel.Part?, _ nw: NWPalette) -> Color {
        switch part {
        case .system?: nw.contextSystem
        case .instructions?: nw.contextInstructions
        case .messages?: nw.contextMessages
        case .toolResults?: nw.contextToolResults
        case nil: nw.textTertiary
        }
    }
}

/// One of the largest items: a file or terminal glyph, the name in mono, its size; `bgHover`
/// under the pointer, and a click finds it in the thread.
private struct NWContextItemRow: View {
    let item: NWContextDetailsModel.Item
    /// A touch row: at least 44pt.
    let touch: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let nw = Color.nw
        Button(action: action) {
            HStack(spacing: NW.Space.m) {
                Image(systemName: item.kind == .command ? "apple.terminal" : item.kind == .file ? "doc.text" : "wrench.and.screwdriver")
                    .font(.system(size: NWContextMetrics.icon - 1)).foregroundStyle(nw.textTertiary)
                    .frame(width: NWContextMetrics.icon)
                Text(item.label).font(.nwMono(11.5)).foregroundStyle(nw.textSecondary).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: NW.Space.m)
                Text(item.value).font(.nwMono(11)).foregroundStyle(nw.textSecondary)
            }
            .padding(.horizontal, NW.Space.m)
            .frame(minHeight: touch ? NW.Height.touch : NWContextMetrics.rowHeight)
            .background(hovering ? nw.bgHover : .clear, in: RoundedRectangle(cornerRadius: NW.Radius.s))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.horizontal, NWContextMetrics.largestInset)
        .help("Find \(item.label) in the thread")
        .accessibilityLabel("\(item.label), \(item.value) tokens")
        .accessibilityHint("Finds it in the thread")
    }
}

/// The details' full-width buttons (30pt, radius 8): Compact now in `lantern`, the rest on
/// `bgWindow` with a `lineStrong` line.
struct NWContextButtonStyle: ButtonStyle {
    let primary: Bool
    /// A sheet's button: 44pt tall.
    var touch = false

    func makeBody(configuration: Configuration) -> some View {
        ButtonBody(configuration: configuration, primary: primary, touch: touch)
    }

    private struct ButtonBody: View {
        let configuration: Configuration
        let primary: Bool
        let touch: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        var body: some View {
            let nw = Color.nw
            let shape = RoundedRectangle(cornerRadius: NW.Radius.m)
            let active = enabled && (hovering || configuration.isPressed)
            configuration.label
                .labelStyle(NWContextLabelStyle())
                .font(.nwSans(12.5, primary ? .semibold : .medium))
                .foregroundStyle(primary ? nw.textOnLantern : nw.textPrimary)
                .frame(maxWidth: .infinity, minHeight: touch ? NW.Height.touch : NWContextMetrics.buttonHeight)
                .background(primary ? AnyShapeStyle(nw.lantern.mix(with: .white, by: active ? 0.12 : 0))
                                    : AnyShapeStyle(active ? nw.bgHover : nw.bgWindow), in: shape)
                .overlay { if !primary { shape.strokeBorder(nw.lineStrong, lineWidth: 1) } }
                .contentShape(shape)
                .nwEnabledOpacity(enabled)
                .onHover { hovering = $0 }
                .nwAnimation(.hover, value: hovering)
                .nwFocusRing(radius: NW.Radius.m)
        }
    }
}

private struct NWContextLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 7) {
            configuration.icon
            configuration.title
        }
    }
}
