import SwiftUI

// New thread's "Where it runs" (FleetNewThread): the chip beside the project chip, and its popover, which ranks every Mac by room.
// Plain values in; the app derives them (`FleetWherePicker`) and decides what a pick does.

/// One row of the popover: Auto, or a Mac.
public struct SHFleetPlaceRow: Identifiable, Equatable, Sendable {
    /// How the row's gauge and word are colored.
    public enum Tone: Sendable { case good, warn, bad, quiet }

    public var id: String
    public var title: String
    /// "18% CPU · 41 GB free · plugged in".
    public var detail: String
    /// 0...1.
    public var room: Double
    /// "most", "little", "asleep", or the Mac Auto would pick.
    public var roomWord: String
    public var tone: Tone
    public var isCurrent: Bool
    public var isEnabled: Bool

    public init(id: String, title: String, detail: String, room: Double, roomWord: String, tone: Tone, isCurrent: Bool, isEnabled: Bool = true) {
        self.id = id
        self.title = title
        self.detail = detail
        self.room = room
        self.roomWord = roomWord
        self.tone = tone
        self.isCurrent = isCurrent
        self.isEnabled = isEnabled
    }
}

public enum SHFleetPlaceMetrics {
    /// The popover: 360pt wide, its rows a check, the words and a 72pt room column holding a 64 by 4pt gauge.
    public static let width: CGFloat = 360
    static let mark: CGFloat = 16
    static let roomColumn: CGFloat = 72
    static let gauge: CGFloat = 64
    static let gaugeHeight: CGFloat = 4
}

/// The popover: "Where it runs", a row each for Auto and every Mac, and a line about which Macs have the repository.
public struct SHFleetPlaceMenu: View {
    let rows: [SHFleetPlaceRow]
    let footnote: String?
    let onChoose: (SHFleetPlaceRow) -> Void
    let onClose: () -> Void
    @State private var selection: Int

    public init(rows: [SHFleetPlaceRow], footnote: String?, onChoose: @escaping (SHFleetPlaceRow) -> Void, onClose: @escaping () -> Void) {
        self.rows = rows
        self.footnote = footnote
        self.onChoose = onChoose
        self.onClose = onClose
        _selection = State(initialValue: rows.firstIndex(where: \.isCurrent) ?? 0)
    }

    public var body: some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: 0) {
            Text("Where it runs")
                .font(.sh(.caption, weight: .regular))
                .foregroundStyle(sh.textTertiary)
                .padding(.horizontal, SH.Space.m)
                .padding(.top, SH.Space.s)
                .padding(.bottom, SH.Space.xs)
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                SHMenuRow(highlighted: index == selection && row.isEnabled, spacing: SH.Space.m,
                          padding: EdgeInsets(top: SH.Space.m, leading: SH.Space.m, bottom: SH.Space.m, trailing: SH.Space.m),
                          height: SHComposerMetrics.menuRowHeight,
                          action: { if row.isEnabled { onChoose(row) } }, onHover: { selection = index }) {
                    Image(systemName: "checkmark")
                        .font(.sh(.caption, weight: .semibold))
                        .foregroundStyle(sh.textPrimary)
                        .opacity(row.isCurrent ? 1 : 0)
                        .frame(width: SHFleetPlaceMetrics.mark)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: SH.Space.xxs) {
                        Text(row.title)
                            .font(.sh(.ui, weight: .medium))
                            .foregroundStyle(row.isEnabled ? sh.textPrimary : sh.textTertiary)
                            .lineLimit(1)
                        Text(row.detail)
                            .font(.sh(.caption, weight: .regular))
                            .foregroundStyle(sh.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: SH.Space.xs) {
                        Capsule().fill(sh.lineSubtle)
                            .frame(width: SHFleetPlaceMetrics.gauge, height: SHFleetPlaceMetrics.gaugeHeight)
                            .overlay(alignment: .leading) {
                                Capsule().fill(color(row.tone))
                                    .frame(width: SHFleetPlaceMetrics.gauge * max(0, min(1, row.room)), height: SHFleetPlaceMetrics.gaugeHeight)
                            }
                        Text(row.roomWord).font(.shMono(10)).foregroundStyle(color(row.tone)).lineLimit(1)
                    }
                    .frame(width: SHFleetPlaceMetrics.roomColumn, alignment: .trailing)
                }
                .accessibilityLabel("\(row.title), \(row.roomWord), \(row.detail)" + (row.isCurrent ? ", chosen" : ""))
                .opacity(row.isEnabled ? 1 : 0.7)
            }
            if let footnote {
                SHHairline().padding(.top, SH.Space.xs)
                Text(footnote)
                    .font(.sh(.caption, weight: .regular))
                    .foregroundStyle(sh.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, SH.Space.m)
                    .padding(.vertical, SH.Space.m)
            }
        }
        .onKeyPress(.downArrow) { selection = min(max(0, rows.count - 1), selection + 1); return .handled }
        .onKeyPress(.upArrow) { selection = max(0, selection - 1); return .handled }
        .onKeyPress(.return) {
            if rows.indices.contains(selection), rows[selection].isEnabled { onChoose(rows[selection]) }
            return .handled
        }
        .onKeyPress(.escape) { onClose(); return .handled }
        .modifier(SHMenuSurface(width: SHFleetPlaceMetrics.width))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Where it runs")
    }

    private func color(_ tone: SHFleetPlaceRow.Tone) -> Color {
        let sh = Color.sh
        return switch tone {
        case .good: sh.done
        case .warn: sh.lantern
        case .bad: sh.failed
        case .quiet: sh.textTertiary
        }
    }
}

/// The chip beside the project chip: a Mac glyph and where the thread runs ("Auto · Mac mini"), and a chevron.
public struct SHFleetPlaceChipLabel: View {
    let title: String

    public init(_ title: String) { self.title = title }

    public var body: some View {
        HStack(spacing: SH.Space.s) {
            Image(systemName: "display").font(.sh(.caption, weight: .regular)).foregroundStyle(.sh.textSecondary)
            Text(title).font(.sh(.ui, weight: .regular)).lineLimit(1)
            SHChipChevron()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Where it runs: \(title)")
    }
}
