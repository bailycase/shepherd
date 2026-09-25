import SwiftUI

/// Settings ▸ Skills' own measures (SettingsSkills, SkillsStates, MobileSkills).
public enum NWSkillMetrics {
    public static let pillHeight: CGFloat = 22
    public static let pillTextSize: CGFloat = 11.5
    public static let chipHeight: CGFloat = 26
    public static let chipTextSize: CGFloat = 11.5
    public static let chipIconSize: CGFloat = 10.5
    public static let chipSides: CGFloat = 9
    public static let hostNameWidth: CGFloat = 70
    public static let hostRowHeight: CGFloat = 26
    public static let hostTextSize: CGFloat = 12
    public static let hostMarkSize: CGFloat = 12
    public static let hostDotSize: CGFloat = 7
    public static let budgetHeight: CGFloat = 6
    public static let budgetGap: CGFloat = 2
    public static let radioSize: CGFloat = 14
    public static let radioDot: CGFloat = 6
    /// Centres the mark on the title's first line.
    public static let radioTopInset: CGFloat = 2
    public static let optionTitleSize: CGFloat = 13
    public static let optionNoteSize: CGFloat = 12
    public static let optionNoteLineHeight: CGFloat = 1.45
}

/// The pill a skill with a newer commit wears, lantern on its tint (SkillsStates' "Update").
public struct NWUpdatePill: View {
    let title: String

    public init(_ title: String = "Update") {
        self.title = title
    }

    public var body: some View {
        let nw = Color.nw
        Text(title)
            .font(.nwSans(NWSkillMetrics.pillTextSize, .semibold))
            .foregroundStyle(nw.lanternText)
            .lineLimit(1)
            .padding(.horizontal, NW.Space.m)
            .frame(height: NWSkillMetrics.pillHeight)
            .background(nw.lanternTint, in: Capsule())
            .fixedSize()
    }
}

/// One entry at the top of a skill's folder: its icon, mono name, and a folder's file count
/// ("SKILL.md", "scripts/ 8").
public struct NWFileChip: View {
    public enum Kind: Sendable {
        /// A document: SKILL.md, reference.md.
        case file
        /// A folder of scripts the agent can run.
        case code
        /// Any other folder: references/, assets/.
        case folder
    }

    let name: String
    let count: Int?
    let kind: Kind

    public init(_ name: String, count: Int? = nil, kind: Kind = .file) {
        self.name = name
        self.count = count
        self.kind = kind
    }

    public var body: some View {
        let nw = Color.nw
        HStack(spacing: NW.Space.s) {
            Image(systemName: symbol)
                .font(.nwSans(NWSkillMetrics.chipIconSize))
                .foregroundStyle(nw.textTertiary)
                .accessibilityHidden(true)
            Text(name)
                .font(.nwMono(NWSkillMetrics.chipTextSize))
                .foregroundStyle(nw.textSecondary)
                .lineLimit(1)
            if let count {
                Text("\(count)")
                    .font(.nwMono(NWSkillMetrics.chipTextSize))
                    .foregroundStyle(nw.textTertiary)
            }
        }
        .padding(.horizontal, NWSkillMetrics.chipSides)
        .frame(height: NWSkillMetrics.chipHeight)
        .background(nw.bgWindow, in: RoundedRectangle(cornerRadius: NW.Radius.s))
        .nwBorder(nw.lineSubtle, radius: NW.Radius.s)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch kind {
        case .file: "doc.text"
        case .code: "curlybraces"
        case .folder: "folder"
        }
    }
}

/// Where one host is with a skill ("This Mac  installed"): a check when it's there, a filled dot
/// while something is on its way to it, a hollow one while it's offline.
public struct NWHostStateRow: View {
    public enum Mark: Sendable {
        case done
        case working
        case offline
        /// Online without it: nothing drawn but the words.
        case none
    }

    let name: String
    let detail: String
    let mark: Mark

    public init(_ name: String, detail: String, mark: Mark) {
        self.name = name
        self.detail = detail
        self.mark = mark
    }

    public var body: some View {
        let nw = Color.nw
        HStack(spacing: NW.Space.m) {
            Group {
                switch mark {
                case .done:
                    Image(systemName: "checkmark")
                        .font(.nwSans(NWSkillMetrics.hostMarkSize - 2, .bold))
                        .foregroundStyle(nw.done)
                case .working:
                    Circle().fill(nw.running).frame(width: NWSkillMetrics.hostDotSize, height: NWSkillMetrics.hostDotSize)
                case .offline:
                    Circle().strokeBorder(nw.textTertiary, lineWidth: 1.5)
                        .frame(width: NWSkillMetrics.hostDotSize, height: NWSkillMetrics.hostDotSize)
                case .none:
                    Color.clear
                }
            }
            .frame(width: NWSkillMetrics.hostMarkSize)
            .accessibilityHidden(true)
            Text(name)
                .font(.nwMono(NWSkillMetrics.hostTextSize))
                .foregroundStyle(nw.textPrimary)
                .lineLimit(1)
                .frame(width: NWSkillMetrics.hostNameWidth, alignment: .leading)
            Text(detail)
                .font(.nwSans(NWSkillMetrics.hostTextSize))
                .foregroundStyle(mark == .working ? nw.textSecondary : nw.textTertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(minHeight: NWSkillMetrics.hostRowHeight)
        .accessibilityElement(children: .combine)
    }
}

/// What the automatic skills cost in every prompt: a segment for each skill that is on, filled
/// for an automatic one and a rule for one only /skill loads.
public struct NWBudgetBar: View {
    let segments: [Bool]

    public init(_ segments: [Bool]) {
        self.segments = segments
    }

    public var body: some View {
        let nw = Color.nw
        HStack(spacing: NWSkillMetrics.budgetGap) {
            if segments.isEmpty {
                RoundedRectangle(cornerRadius: NWSkillMetrics.budgetGap).fill(nw.lineSubtle)
            }
            ForEach(Array(segments.enumerated()), id: \.offset) { _, filled in
                RoundedRectangle(cornerRadius: NWSkillMetrics.budgetGap).fill(filled ? nw.running : nw.lineSubtle)
            }
        }
        .frame(height: NWSkillMetrics.budgetHeight)
        .accessibilityHidden(true)
    }
}

/// A radio button's mark: lantern with a dark center when chosen, a raised ring when not.
public struct NWRadioMark: View {
    let selected: Bool

    public init(selected: Bool) {
        self.selected = selected
    }

    public var body: some View {
        let nw = Color.nw
        ZStack {
            if selected {
                Circle().fill(nw.lantern)
                Circle().fill(nw.textOnLantern).frame(width: NWSkillMetrics.radioDot, height: NWSkillMetrics.radioDot)
            } else {
                Circle().fill(nw.bgRaised)
                Circle().strokeBorder(nw.lineStrong, lineWidth: 1.5)
            }
        }
        .frame(width: NWSkillMetrics.radioSize, height: NWSkillMetrics.radioSize)
        .nwComponentAnimation(.content, value: selected)
        .accessibilityHidden(true)
    }
}

/// One choice of several, with what it means under its title (a skill's Use it).
public struct NWRadioOption: View {
    let title: String
    let note: String
    let selected: Bool
    let action: () -> Void

    public init(_ title: String, note: String, selected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.note = note
        self.selected = selected
        self.action = action
    }

    public var body: some View {
        let nw = Color.nw
        Button(action: action) {
            HStack(alignment: .top, spacing: NW.Space.m + NW.Space.xxs) {
                NWRadioMark(selected: selected)
                    .padding(.top, NWSkillMetrics.radioTopInset)
                VStack(alignment: .leading, spacing: NW.Space.xxs) {
                    Text(title)
                        .font(.nwSans(NWSkillMetrics.optionTitleSize, selected ? .semibold : .medium))
                        .foregroundStyle(nw.textPrimary)
                    Text(note)
                        .nwText(size: NWSkillMetrics.optionNoteSize, lineHeight: NWSkillMetrics.optionNoteLineHeight)
                        .foregroundStyle(nw.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// skills.sh's seal for a publisher it marks official.
public struct NWOfficialSeal: View {
    let size: CGFloat

    public init(size: CGFloat = 12) {
        self.size = size
    }

    public var body: some View {
        Image(systemName: "checkmark.seal")
            .font(.nwSans(size))
            .foregroundStyle(Color.nw.running)
            .accessibilityLabel("Official")
    }
}
