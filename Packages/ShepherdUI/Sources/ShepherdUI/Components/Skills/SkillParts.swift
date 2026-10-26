import SwiftUI

/// Settings ▸ Skills' own measures (SettingsSkills, SkillsStates, MobileSkills).
public enum SHSkillMetrics {
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
public struct SHUpdatePill: View {
    let title: String

    public init(_ title: String = "Update") {
        self.title = title
    }

    public var body: some View {
        let sh = Color.sh
        Text(title)
            .font(.shSans(SHSkillMetrics.pillTextSize, .semibold))
            .foregroundStyle(sh.lanternText)
            .lineLimit(1)
            .padding(.horizontal, SH.Space.m)
            .frame(height: SHSkillMetrics.pillHeight)
            .background(sh.lanternTint, in: Capsule())
            .fixedSize()
    }
}

/// One entry at the top of a skill's folder: its icon, mono name, and a folder's file count
/// ("SKILL.md", "scripts/ 8").
public struct SHSkillFileChip: View {
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
        let sh = Color.sh
        HStack(spacing: SH.Space.s) {
            Image(systemName: symbol)
                .font(.shSans(SHSkillMetrics.chipIconSize))
                .foregroundStyle(sh.textTertiary)
                .accessibilityHidden(true)
            Text(name)
                .font(.shMono(SHSkillMetrics.chipTextSize))
                .foregroundStyle(sh.textSecondary)
                .lineLimit(1)
            if let count {
                Text("\(count)")
                    .font(.shMono(SHSkillMetrics.chipTextSize))
                    .foregroundStyle(sh.textTertiary)
            }
        }
        .padding(.horizontal, SHSkillMetrics.chipSides)
        .frame(height: SHSkillMetrics.chipHeight)
        .background(sh.bgWindow, in: RoundedRectangle(cornerRadius: SH.Radius.s))
        .shBorder(sh.lineSubtle, radius: SH.Radius.s)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch kind {
        case .file: SHGlyph.document.symbolName
        case .code: "curlybraces"
        case .folder: "folder"
        }
    }
}

/// Where one host is with a skill ("This Mac  installed"): a check when it's there, a filled dot
/// while something is on its way to it, a hollow one while it's offline.
public struct SHHostStateRow: View {
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
        let sh = Color.sh
        HStack(spacing: SH.Space.m) {
            Group {
                switch mark {
                case .done:
                    Image(systemName: "checkmark")
                        .font(.shSans(SHSkillMetrics.hostMarkSize - 2, .bold))
                        .foregroundStyle(sh.done)
                case .working:
                    Circle().fill(sh.running).frame(width: SHSkillMetrics.hostDotSize, height: SHSkillMetrics.hostDotSize)
                case .offline:
                    Circle().strokeBorder(sh.textTertiary, lineWidth: 1.5)
                        .frame(width: SHSkillMetrics.hostDotSize, height: SHSkillMetrics.hostDotSize)
                case .none:
                    Color.clear
                }
            }
            .frame(width: SHSkillMetrics.hostMarkSize)
            .accessibilityHidden(true)
            Text(name)
                .font(.shMono(SHSkillMetrics.hostTextSize))
                .foregroundStyle(sh.textPrimary)
                .lineLimit(1)
                .frame(width: SHSkillMetrics.hostNameWidth, alignment: .leading)
            Text(detail)
                .font(.shSans(SHSkillMetrics.hostTextSize))
                .foregroundStyle(mark == .working ? sh.textSecondary : sh.textTertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(minHeight: SHSkillMetrics.hostRowHeight)
        .accessibilityElement(children: .combine)
    }
}

/// What the automatic skills cost in every prompt: a segment for each skill that is on, filled
/// for an automatic one and a rule for one only /skill loads.
public struct SHBudgetBar: View {
    let segments: [Bool]

    public init(_ segments: [Bool]) {
        self.segments = segments
    }

    public var body: some View {
        let sh = Color.sh
        HStack(spacing: SHSkillMetrics.budgetGap) {
            if segments.isEmpty {
                RoundedRectangle(cornerRadius: SHSkillMetrics.budgetGap).fill(sh.lineSubtle)
            }
            ForEach(Array(segments.enumerated()), id: \.offset) { _, filled in
                RoundedRectangle(cornerRadius: SHSkillMetrics.budgetGap).fill(filled ? sh.running : sh.lineSubtle)
            }
        }
        .frame(height: SHSkillMetrics.budgetHeight)
        .accessibilityHidden(true)
    }
}

/// A radio button's mark: lantern with a dark center when chosen, a raised ring when not.
public struct SHRadioMark: View {
    let selected: Bool

    public init(selected: Bool) {
        self.selected = selected
    }

    public var body: some View {
        let sh = Color.sh
        ZStack {
            if selected {
                Circle().fill(sh.lantern)
                Circle().fill(sh.textOnLantern).frame(width: SHSkillMetrics.radioDot, height: SHSkillMetrics.radioDot)
            } else {
                Circle().fill(sh.bgRaised)
                Circle().strokeBorder(sh.lineStrong, lineWidth: 1.5)
            }
        }
        .frame(width: SHSkillMetrics.radioSize, height: SHSkillMetrics.radioSize)
        .shComponentAnimation(.content, value: selected)
        .accessibilityHidden(true)
    }
}

/// One choice of several, with what it means under its title (a skill's Use it).
public struct SHRadioOption: View {
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
        let sh = Color.sh
        Button(action: action) {
            HStack(alignment: .top, spacing: SH.Space.m + SH.Space.xxs) {
                SHRadioMark(selected: selected)
                    .padding(.top, SHSkillMetrics.radioTopInset)
                VStack(alignment: .leading, spacing: SH.Space.xxs) {
                    Text(title)
                        .font(.shSans(SHSkillMetrics.optionTitleSize, selected ? .semibold : .medium))
                        .foregroundStyle(sh.textPrimary)
                    Text(note)
                        .shText(size: SHSkillMetrics.optionNoteSize, lineHeight: SHSkillMetrics.optionNoteLineHeight)
                        .foregroundStyle(sh.textTertiary)
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
public struct SHOfficialSeal: View {
    let size: CGFloat

    public init(size: CGFloat = 12) {
        self.size = size
    }

    public var body: some View {
        Image(systemName: "checkmark.seal")
            .font(.shSans(size))
            .foregroundStyle(Color.sh.running)
            .accessibilityLabel("Official")
    }
}
