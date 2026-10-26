import SwiftUI

// The Subagents tab of the side pane (SubagentList board): every subagent of a thread, the
// current turn's first and the earlier ones after, each opening in the inspector. The values are
// the tray's (`SHSubagentTrayRun`), so a run reads the same in both; the app hands every value in,
// derived once per change. Every spacing and size is the board's own token (its `.sl-*` rules):
// 12pt padding and gaps, an 8pt trailing edge, `ui` names, `caption` lines and `micro` mono.

public enum SHSubagentListMetrics {
    /// The board's row: `min-height: 52px`.
    public static let rowHeight: CGFloat = 52
    /// The board's time column: `width: 30px`, right-aligned.
    public static let timeWidth: CGFloat = 30
    /// The finished glyphs (`checkmark`, `xmark`): 11pt, as the board draws them (8 wide, where the tray's 8pt cross is 6).
    public static let glyphSize: CGFloat = 11
    /// A line's height in the board: its spans set a size but no line height, so a browser gives Geist its natural 1.2
    /// leading, where the ramp's styles run 1.3 and 1.35; whole points, as it lays them out. Scaled with the Text size.
    @MainActor public static func line(_ size: CGFloat) -> CGFloat { (size * ThemeStore.shared.textScale * 1.2).rounded(.down) }
}

/// "5 subagents" and the tally: "1 running · 1 waiting on parent · 2 done · 1 stopped".
public struct SHSubagentListSummary: View, Equatable {
    let title: String
    let tally: [SHSubagentTraySummary.Part]

    public init(title: String, tally: [SHSubagentTraySummary.Part]) {
        self.title = title
        self.tally = tally
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
            Text(title).font(.sh(.ui, weight: .semibold)).foregroundStyle(Color.sh.textPrimary).lineLimit(1).fixedSize()
                .shContentTransition(.numeric())
            // Every part quiet: the board colors none.
            Text(tally.map(\.text).joined(separator: " · ")).font(.sh(.micro, weight: .regular)).monospacedDigit()
                .foregroundStyle(Color.sh.textTertiary).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .frame(height: SHSubagentListMetrics.line(SHTextStyle.ui.size))
        .padding(.horizontal, SH.Space.l)
        .padding(.top, SH.Space.l)
        .padding(.bottom, SH.Space.s)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(([title] + tally.map(\.text)).joined(separator: ", "))
        .accessibilityAddTraits(.isHeader)
    }
}

/// "This turn · started 2:41 PM", "Earlier in this thread · 1:58 PM".
public struct SHSubagentListSection: View, Equatable {
    let title: String
    let time: String?

    public init(_ title: String, time: String? = nil) {
        self.title = title
        self.time = time
    }

    public var body: some View {
        let sh = Color.sh
        HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
            Text(title).font(.sh(.caption)).foregroundStyle(sh.textSecondary).lineLimit(1)
            if let time {
                Text(time).font(.sh(.micro, weight: .regular)).foregroundStyle(sh.textTertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(height: SHSubagentListMetrics.line(SHTextStyle.caption.size))
        .padding(.horizontal, SH.Space.l)
        .padding(.top, SH.Space.l)
        .padding(.bottom, SH.Space.s)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One run: its state, its name and role over what it is doing (or asked its parent, or did), its
/// diff and time, and a chevron. The whole row is one button that opens the run in the inspector;
/// the run's own controls live there.
public struct SHSubagentListRow: View, Equatable {
    let run: SHSubagentTrayRun
    let open: () -> Void

    public init(_ run: SHSubagentTrayRun, open: @escaping () -> Void) {
        self.run = run
        self.open = open
    }

    public nonisolated static func == (a: SHSubagentListRow, b: SHSubagentListRow) -> Bool { a.run == b.run }

    public var body: some View {
        let _ = SHRenderProbe.tick("subagents.listRow")
        let sh = Color.sh
        let mono = Font.sh(.micro, weight: .regular)
        Button(action: open) {
            HStack(spacing: SH.Space.l) {
                // The dot is 7pt wide as the board draws it; the finished glyphs are the tray's, centered on it.
                SHSubagentStateMark(run.state, slot: SHSubagentTrayMetrics.pointer.stateSlot, width: SHSubagentTrayMetrics.dotSize,
                                    glyph: SHSubagentListMetrics.glyphSize)
                VStack(alignment: .leading, spacing: SH.Space.xxs) {
                    HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
                        Text(run.name).font(.sh(.ui, weight: .semibold)).foregroundStyle(sh.textPrimary)
                            .lineLimit(1).truncationMode(.tail).frame(height: SHSubagentListMetrics.line(SHTextStyle.ui.size))
                        if let role = run.role {
                            Text(role).font(mono).foregroundStyle(sh.textTertiary).lineLimit(1).layoutPriority(1)
                        }
                    }
                    detail
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let added = run.added, let removed = run.removed {
                    SHDiffStat(added: added, removed: removed, font: mono)
                }
                // A fixed column, so every row's chevron and diff stay where the next row's do.
                Group {
                    if let since = run.since {
                        SHElapsedText(since: since, until: run.until).font(mono).foregroundStyle(sh.textTertiary).lineLimit(1).fixedSize()
                    }
                }
                .frame(width: SHSubagentListMetrics.timeWidth, alignment: .trailing)
                Image(systemName: "chevron.right")
                    .font(.system(size: SHSubagentTrayMetrics.chevron - 1, weight: .semibold))
                    .foregroundStyle(sh.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.leading, SH.Space.l)
            .padding(.trailing, SH.Space.m)
            .padding(.vertical, SH.Space.s)
            .frame(minHeight: SHSubagentListMetrics.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.shRow(radius: 0))
        .overlay(alignment: .top) { SHHairline() }
        .accessibilityLabel(run.accessibilityLabel)
        .accessibilityHint("Opens the run")
    }

    /// What it is doing, why it waits, what it did, or why it failed: one plain line (the board's `.sl-line`).
    @MainActor private var detail: some View {
        let sh = Color.sh
        let (text, color): (String, Color) = switch run.line {
        case .working(let verb, let subject, _): ([verb, subject].compactMap { $0 }.joined(separator: " "), sh.textSecondary)
        case .waiting(let text), .result(let text): (text, sh.textSecondary)
        case .asked(let question): (question.isEmpty ? "asked the parent" : "asked the parent: " + question, sh.textSecondary)
        case .failed(let reason): (reason, sh.failed)
        }
        return Text(text).font(.sh(.caption)).foregroundStyle(color).lineLimit(1).truncationMode(.tail)
            .frame(height: SHSubagentListMetrics.line(SHTextStyle.caption.size))
    }
}
