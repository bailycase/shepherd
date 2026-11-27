import SwiftUI

#if os(macOS)
/// The Mac popover's measures (GXContext, GXContextFull): 320pt wide on a 12pt-radius card with
/// 10pt above, 12pt at the sides and 8pt below; rows 24pt, the bar 6pt.
enum SHContextMacMetrics {
    static let width: CGFloat = 320
    /// The almost-full paragraph, the field and the compacting note (the board's 12.5).
    static let noteFont: CGFloat = 12.5
    static let top: CGFloat = 10
    static let side: CGFloat = 12
    static let bottom: CGFloat = 8
    static let totalTop: CGFloat = 6
    static let totalLine: CGFloat = 28
    static let barTop: CGFloat = 8
    static let barHeight: CGFloat = 6
    static let barRadius: CGFloat = 3
    static let tickWidth: CGFloat = 2
    static let tickHeight: CGFloat = 12
    static let noteTop: CGFloat = 5
    static let rowHeight: CGFloat = 24
    static let rowGap: CGFloat = 8
    static let childHeight: CGFloat = 18
    static let largestTop: CGFloat = 8
    static let largestHeight: CGFloat = 22
    static let footnoteTop: CGFloat = 6
    static let paragraphTop: CGFloat = 8
    static let fieldTop: CGFloat = 10
    static let fieldHeight: CGFloat = 34
    static let fieldInset: CGFloat = 10
    static let actionsTop: CGFloat = 8
    static let pillHeight: CGFloat = 26
    static let pillInset: CGFloat = 11
    /// The share of `textPrimary` each part's swatch and bar segment is drawn in: the four the
    /// board shows, then the parts a long thread adds.
    static let partShades: [SHContextDetailsModel.Part: Double] = [
        .system: 0.85, .instructions: 0.62, .messages: 0.42, .toolResults: 0.24,
        .toolCalls: 0.52, .reasoning: 0.34, .images: 0.18, .other: 0.12,
    ]
}

extension SHContextDetails {
    /// The breakdown shows past 85% only once Details is open.
    var showsBreakdown: Bool { model.variant != .almostFull || detailsOpen }

    /// The Mac's details: the board's popover, where the total, the bar and the rows sit as plain
    /// text on the card and the actions are words, not buttons.
    var macBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            macHeader
            switch model.variant {
            case .compacting(let started):
                macCompacting(started)
            default:
                if let total = model.total { macTotal(total) }
                if !model.segments.isEmpty || model.variant == .simple || model.variant == .split { macBar }
                if let markLabel = model.markLabel, model.variant != .compacted, model.variant != .empty {
                    Text(markLabel).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.top, SHContextMacMetrics.noteTop)
                }
                if let note = model.note { macNote(note) }
                // Past 85% the breakdown waits behind Details (GXContextFull).
                if !model.rows.isEmpty, showsBreakdown { macRows }
                if !model.items.isEmpty, showsBreakdown { macLargest }
                if let footnote = model.footnote, showsBreakdown {
                    Text(footnote).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, SHContextMacMetrics.footnoteTop)
                }
                macActions
            }
        }
        .padding(.top, SHContextMacMetrics.top)
        .padding(.horizontal, SHContextMacMetrics.side)
        .padding(.bottom, SHContextMacMetrics.bottom)
        .frame(width: SHContextMacMetrics.width, alignment: .leading)
        .shPopover()
        .shAnimation(.disclosure, value: composing)
    }

    private var macHeader: some View {
        HStack(spacing: SH.Space.m) {
            Text(model.title).font(.sh(.ui, weight: .semibold)).foregroundStyle(Color.sh.textPrimary)
            Spacer(minLength: SH.Space.m)
            if case .compacting(let started) = model.variant {
                TimelineView(.periodic(from: started, by: 1)) { context in
                    Text("started \(Self.clock(from: started, now: context.date)) ago")
                        .font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary).monospacedDigit()
                }
            } else if let meta = model.meta {
                Text(meta).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary).lineLimit(1)
            }
        }
    }

    private func macTotal(_ total: String) -> some View {
        let sh = Color.sh
        let estimate = model.variant == .compacted
        return HStack(alignment: .firstTextBaseline, spacing: SH.Space.s) {
            Text(total).font(.shSans(SHContextMetrics.totalSize, .semibold)).tracking(-0.22)
                .foregroundStyle(estimate ? sh.textSecondary : sh.textPrimary)
            if let of = model.ofWindow { Text(of).font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textSecondary) }
            Spacer(minLength: SH.Space.m)
            if let trailing = model.trailing {
                Text(trailing).font(.sh(.caption)).foregroundStyle(estimate ? sh.textTertiary : sh.textSecondary)
            }
        }
        .frame(minHeight: SHContextMacMetrics.totalLine)
        .padding(.top, SHContextMacMetrics.totalTop)
    }

    /// The window as a 6pt bar on `bgHover`: each part in a shade of `textPrimary`, one `lantern`
    /// fill when nearly full, and the auto-compact tick standing out of it.
    private var macBar: some View {
        let sh = Color.sh
        let height = SHContextMacMetrics.barHeight
        let full = model.variant == .almostFull
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(sh.bgHover)
                if model.variant == .compacted, let segment = model.segments.first {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: height / 2))
                        path.addLine(to: CGPoint(x: geo.size.width * segment.fraction, y: height / 2))
                    }
                    .stroke(sh.textTertiary, style: StrokeStyle(lineWidth: height, dash: [SHContextMetrics.barDash, SHContextMetrics.barDashGap]))
                } else if full {
                    Rectangle().fill(sh.lantern)
                        .frame(width: geo.size.width * min(1, model.segments.reduce(0) { $0 + $1.fraction }))
                } else {
                    HStack(spacing: 0) {
                        ForEach(Array(model.segments.enumerated()), id: \.offset) { _, segment in
                            Rectangle().fill(Self.macColor(segment.part, sh))
                                .frame(width: max(1, geo.size.width * segment.fraction))
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: SHContextMacMetrics.barRadius))
            .overlay(alignment: .leading) {
                if let mark = model.mark, model.variant != .compacted {
                    RoundedRectangle(cornerRadius: 1).fill(sh.textSecondary)
                        .frame(width: SHContextMacMetrics.tickWidth, height: SHContextMacMetrics.tickHeight)
                        .offset(x: geo.size.width * mark)
                }
            }
        }
        .frame(height: height)
        .padding(.top, SHContextMacMetrics.barTop)
        .accessibilityHidden(true)
    }

    private func macNote(_ note: String) -> some View {
        let quiet = model.variant == .compacted || model.variant == .empty
        return Text(note)
            .font(quiet ? .sh(.caption) : .shSans(SHContextMacMetrics.noteFont)).lineSpacing(quiet ? 0 : 3)
            .foregroundStyle(quiet ? Color.sh.textTertiary : Color.sh.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, SHContextMacMetrics.paragraphTop)
    }

    private var macRows: some View {
        let sh = Color.sh
        return VStack(spacing: 0) {
            ForEach(model.rows) { row in
                HStack(spacing: SHContextMacMetrics.rowGap) {
                    RoundedRectangle(cornerRadius: 2).fill(Self.macColor(row.part, sh))
                        .frame(width: SHContextMetrics.swatch, height: SHContextMetrics.swatch)
                    if let detail = row.detail {
                        (Text(row.label + ", ").font(.sh(.ui, weight: .regular)) + Text(detail).font(.sh(.mono)))
                            .foregroundStyle(sh.textPrimary).lineLimit(1)
                    } else {
                        Text(row.label).font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textPrimary).lineLimit(1)
                    }
                    Spacer(minLength: SH.Space.m)
                    Text(row.value).font(.sh(.caption)).foregroundStyle(sh.textSecondary)
                }
                .frame(minHeight: SHContextMacMetrics.rowHeight)
                // What the part is made of, in the part's own column and quietly: nothing here is pressed.
                ForEach(row.children) { child in
                    HStack(spacing: SH.Space.m) {
                        Text(child.label).font(.sh(.micro, weight: .regular)).foregroundStyle(sh.textTertiary).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: SH.Space.m)
                        Text(child.value).font(.sh(.micro, weight: .regular)).foregroundStyle(sh.textTertiary)
                    }
                    .frame(minHeight: SHContextMacMetrics.childHeight)
                    .padding(.leading, SHContextMetrics.swatch + SHContextMacMetrics.rowGap)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(child.label), \(child.value) tokens")
                }
            }
            if let free = model.free {
                HStack(spacing: SHContextMacMetrics.rowGap) {
                    Color.clear.frame(width: SHContextMetrics.swatch, height: SHContextMetrics.swatch)
                    Text("Free").font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textTertiary)
                    Spacer(minLength: SH.Space.m)
                    Text(free).font(.sh(.caption)).foregroundStyle(sh.textSecondary)
                }
                .frame(minHeight: SHContextMacMetrics.rowHeight)
            }
        }
    }

    private var macLargest: some View {
        let sh = Color.sh
        return VStack(spacing: 0) {
            HStack {
                Text("Largest")
                Spacer(minLength: SH.Space.m)
                Text("Click to find it in the thread")
            }
            .font(.sh(.caption)).foregroundStyle(sh.textTertiary)
            .frame(height: SHContextMacMetrics.largestHeight)
            .padding(.top, SHContextMacMetrics.largestTop)
            ForEach(model.items) { item in
                SHContextMacItemRow(item: item) { actions.find(item.id) }
            }
        }
    }

    @ViewBuilder private var macActions: some View {
        switch model.variant {
        case .compacted:
            macActionBar { macLink("Show summary", action: actions.showSummary) }
        case .empty:
            EmptyView()
        case .almostFull:
            macKeepField
            macActionBar(leading: model.rows.isEmpty ? nil : macLink(detailsOpen ? "Hide details" : "Details") { detailsOpen.toggle() }) { macPill }
        case .simple, .split:
            if composing {
                macKeepField
                macActionBar { macPill }
            } else {
                macActionBar {
                    macLink("Compact now…") { composing = true; keepFocused = true }
                        .disabled(!model.compactOffered || !actions.compactEnabled)
                        .help(actions.compactHelp ?? "")
                }
            }
        case .compacting:
            EmptyView()
        }
    }

    /// The row under the card's content: a hairline over words at its trailing edge.
    private func macActionBar<Content: View>(leading: (some View)? = Optional<EmptyView>.none, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: SH.Space.m) {
                if let leading { leading }
                Spacer(minLength: 0)
                content()
            }
            .padding(.top, SHContextMacMetrics.actionsTop)
        }
        .overlay(alignment: .top) { Rectangle().fill(Color.sh.lineSubtle).frame(height: 1) }
        .padding(.top, SHContextMacMetrics.actionsTop)
    }

    private func macLink(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title) }
            .buttonStyle(SHContextLinkStyle())
    }

    private var macPill: some View {
        Button(action: compact) { Text("Compact now") }
            .buttonStyle(SHContextPillStyle())
            .disabled(!model.compactOffered || !actions.compactEnabled)
            .help(actions.compactHelp ?? "")
    }

    private var macKeepField: some View {
        let sh = Color.sh
        return TextField(text: $keep, prompt: Text("What should the summary keep? (optional)").foregroundStyle(sh.textTertiary),
                         axis: .vertical) { Text("What the summary should keep") }
            .textFieldStyle(.plain)
            .font(.shSans(SHContextMacMetrics.noteFont)).lineSpacing(2)
            .foregroundStyle(sh.textPrimary)
            .tint(sh.lantern)
            .lineLimit(1...5)
            .focused($keepFocused)
            .padding(.vertical, SH.Space.s).padding(.horizontal, SHContextMacMetrics.fieldInset)
            .frame(minHeight: SHContextMacMetrics.fieldHeight, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: SH.Radius.m).strokeBorder(keepFocused ? sh.textTertiary : sh.lineSubtle, lineWidth: 1))
            .onSubmit(compact)
            .padding(.top, SHContextMacMetrics.fieldTop)
    }

    private func macCompacting(_ started: Date) -> some View {
        let sh = Color.sh
        return VStack(alignment: .leading, spacing: 0) {
            if let note = model.note {
                Self.emphasized(note, model.emphasis).font(.shSans(SHContextMacMetrics.noteFont)).foregroundStyle(sh.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .shShimmer(active: true)
                    .padding(.top, SHContextMacMetrics.paragraphTop)
            }
            // How far along is unknown: the bar eases toward full while it runs.
            TimelineView(.periodic(from: started, by: 0.5)) { context in
                let fraction = Self.progress(from: started, now: context.date)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: SHContextMacMetrics.barRadius).fill(sh.bgHover)
                        RoundedRectangle(cornerRadius: SHContextMacMetrics.barRadius).fill(sh.running)
                            .frame(width: geo.size.width * fraction)
                    }
                }
                .frame(height: SHContextMacMetrics.barHeight)
                .shComponentAnimation(.content, value: fraction)
            }
            .padding(.top, SHContextMacMetrics.fieldTop).padding(.bottom, SH.Space.xs)
        }
    }

    /// A part's swatch and bar segment: a shade of `textPrimary`; an unsplit total is `textTertiary`.
    static func macColor(_ part: SHContextDetailsModel.Part?, _ sh: SHPalette) -> Color {
        guard let part else { return sh.textTertiary }
        return sh.textPrimary.opacity(SHContextMacMetrics.partShades[part] ?? 0.2)
    }
}

/// One of the largest items: its glyph, the name in mono, its size; `bgHover` under the pointer,
/// and a click finds it in the thread.
private struct SHContextMacItemRow: View {
    let item: SHContextDetailsModel.Item
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let sh = Color.sh
        let glyph: String = switch item.kind {
        case .command: "apple.terminal"
        case .file: SHGlyph.document.symbolName
        case .tool: "wrench.and.screwdriver"
        }
        Button(action: action) {
            HStack(spacing: SHContextMacMetrics.rowGap) {
                Image(systemName: glyph)
                    .font(.system(size: SHContextMetrics.icon)).foregroundStyle(sh.textSecondary)
                    .frame(width: SHContextMetrics.icon)
                Text(item.label).font(.sh(.mono)).foregroundStyle(sh.textPrimary).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: SH.Space.m)
                Text(item.value).font(.sh(.caption)).foregroundStyle(sh.textSecondary)
            }
            .frame(minHeight: SHContextMacMetrics.rowHeight)
            .padding(.horizontal, SH.Space.s)
            .background(hovering ? sh.bgHover : .clear, in: RoundedRectangle(cornerRadius: SH.Radius.s))
            .padding(.horizontal, -SH.Space.s)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Find \(item.label) in the thread")
        .accessibilityLabel("\(item.label), \(item.value) tokens")
        .accessibilityHint("Finds it in the thread")
    }
}

/// Words as the action (Compact now…, Show summary): `textPrimary` in medium, fading when disabled.
private struct SHContextLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { LinkBody(configuration: configuration) }

    private struct LinkBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(.sh(.ui, weight: .medium)).foregroundStyle(Color.sh.textPrimary)
                .padding(.horizontal, SH.Space.xs)
                // A taller press area than the words, without taller layout.
                .padding(.vertical, SH.Space.xs)
                .contentShape(Rectangle())
                .padding(.vertical, -SH.Space.xs)
                .shEnabledOpacity(enabled)
                .shFocusRing(radius: SH.Radius.xs)
        }
    }
}

/// Compact now: a 26pt capsule in the primary fill.
private struct SHContextPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { PillBody(configuration: configuration) }

    private struct PillBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        var body: some View {
            let sh = Color.sh
            configuration.label
                .font(.sh(.caption, weight: .medium))
                .foregroundStyle(sh.textOnPrimary)
                .padding(.horizontal, SHContextMacMetrics.pillInset)
                .frame(height: SHContextMacMetrics.pillHeight)
                .background(configuration.isPressed && enabled ? sh.primaryPressed : enabled && hovering ? sh.primaryHover : sh.primary, in: Capsule())
                .contentShape(Capsule())
                .shEnabledOpacity(enabled)
                .onHover { hovering = $0 }
                .shAnimation(.hover, value: hovering)
                .shFocusRing(radius: SHContextMacMetrics.pillHeight / 2)
        }
    }
}
#endif
