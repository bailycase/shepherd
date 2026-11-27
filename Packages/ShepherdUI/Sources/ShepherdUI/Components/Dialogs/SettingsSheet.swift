import SwiftUI

// The Settings boards' form sheets (`gset`): Add a Mac, Add a device, Add space, Sign in. A title over its line, blocks 14pt
// apart on 22pt sides, rules that run edge to edge, and a foot of words with the one action as an ink pill.

public enum SHSettingsSheetMetrics {
    public static let inset: CGFloat = SHPiSignInMetrics.sheetInset
    public static let headerTop: CGFloat = SHPiSignInMetrics.sheetTop
    public static let bodyTop: CGFloat = 18
    public static let bodyBottom: CGFloat = 20
    /// Between blocks; a `tight` block pulls 8pt of it back.
    public static let blockGap: CGFloat = 14
    public static let tight: CGFloat = 8
    public static let titleSize: CGFloat = SHPiSignInMetrics.sheetTitleSize
    public static let titleLine: CGFloat = SHPiSignInMetrics.sheetTitleLine
    public static let textSize: CGFloat = 13
    /// The sheet's default line: 18pt.
    public static let baseLine: CGFloat = 18
    public static let textLine: CGFloat = 19.0 / 13
    public static let smallSize: CGFloat = 12
    public static let smallLine: CGFloat = 17.0 / 12
    public static let bigSize: CGFloat = 14
    public static let bigLine: CGFloat = 20.0 / 14
    public static let monoSize: CGFloat = 12.5
    public static let footerHeight: CGFloat = SHPiSignInMetrics.footerHeight
    public static let footerGap: CGFloat = SHPiSignInMetrics.footerGap
    public static let statusLine: CGFloat = 16.0 / 12
    public static let statusPadding: CGFloat = SH.Space.m
    public static let fieldHeight: CGFloat = 32
    public static let fieldRadius: CGFloat = SH.Radius.m
    public static let fieldSides: CGFloat = 10
    public static let fieldLabelGap: CGFloat = SH.Space.s
    /// Between a field and the action beside it.
    public static let rowGap: CGFloat = 14
    public static let focusRing: CGFloat = 3
    public static let groupRadius: CGFloat = 10
    public static let groupPad: CGFloat = SH.Space.l
    public static let preRadius: CGFloat = 10
    public static let prePad = EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
    /// The rows a sheet picks from: 44pt, 12 between their glyph and words, 10 in from the block's sides.
    public static let pickHeight: CGFloat = 44
    public static let pickGap: CGFloat = SH.Space.l
    public static let pickSides: CGFloat = 10
    public static let pickRadius: CGFloat = SH.Radius.m
    public static let pickRowGap: CGFloat = SH.Space.xxs
    public static let pickGlyph: CGFloat = 16
    public static let linesGap: CGFloat = SH.Space.s
    public static let stepVertical: CGFloat = 10
    public static let stepGap: CGFloat = SH.Space.xl
    public static let stepWordSize: CGFloat = 12.5
    public static let stepNoteGap: CGFloat = SH.Space.xxs
}

/// The sheet: `title`, its line (`subtitle`, and a mono `detail` under it), the content, and a foot with `status` at the left and
/// `actions` at the right.
public struct SHSettingsSheet<Content: View, Status: View, Actions: View>: View {
    let title: String
    let subtitle: String?
    /// A second line under the subtitle, in mono.
    let detail: String?
    let width: CGFloat
    let content: Content
    let status: Status
    let actions: Actions

    public init(_ title: String, subtitle: String? = nil, detail: String? = nil, width: CGFloat,
                @ViewBuilder content: () -> Content, @ViewBuilder status: () -> Status, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.subtitle = subtitle
        self.detail = detail
        self.width = width
        self.content = content()
        self.status = status()
        self.actions = actions()
    }

    public var body: some View {
        let sh = Color.sh
        let M = SHSettingsSheetMetrics.self
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: SH.Space.xs) {
                Text(title)
                    .font(.shSans(M.titleSize, .semibold))
                    .foregroundStyle(sh.textPrimary)
                    .frame(minHeight: M.titleLine, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if subtitle != nil || detail != nil {
                    VStack(alignment: .leading, spacing: 1) {
                        if let subtitle { SHSheetSubtitle(subtitle) }
                        if let detail {
                            Text(detail)
                                .font(.shMono(M.monoSize))
                                .foregroundStyle(sh.textTertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, M.headerTop)
            .padding(.horizontal, M.inset)
            VStack(alignment: .leading, spacing: M.blockGap) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, M.bodyTop)
                .padding(.bottom, M.bodyBottom)
                .padding(.horizontal, M.inset)
            HStack(spacing: M.footerGap) {
                status
                Spacer(minLength: 0)
                HStack(spacing: M.footerGap) { actions }.fixedSize().layoutPriority(1)
            }
            .padding(.horizontal, M.inset)
            .frame(maxWidth: .infinity, minHeight: M.footerHeight)
            .overlay(alignment: .top) { SHHairline(color: sh.lineStrong, width: SHSettingsNavMetrics.borderWidth) }
        }
        .frame(width: width)
        .background(sh.bgRaised)
        .shControlScale(.sheet)
    }
}

extension SHSettingsSheet where Status == EmptyView {
    public init(_ title: String, subtitle: String? = nil, detail: String? = nil, width: CGFloat,
                @ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions) {
        self.init(title, subtitle: subtitle, detail: detail, width: width, content: content, status: { EmptyView() }, actions: actions)
    }
}

/// What the foot says at its left: what is happening (12pt, `textSecondary` while it is), or a failure.
public struct SHSheetStatus: View {
    public enum Tone: Sendable { case quiet, now, failed }

    let text: String
    let tone: Tone

    public init(_ text: String, tone: Tone = .quiet) {
        self.text = text
        self.tone = tone
    }

    public var body: some View {
        let M = SHSettingsSheetMetrics.self
        Text(text)
            .shSheetText(size: M.smallSize, lineHeight: M.statusLine)
            .foregroundStyle(tone == .failed ? Color.sh.failed : tone == .now ? Color.sh.textSecondary : Color.sh.textTertiary)
            .padding(.vertical, M.statusPadding)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

/// A block's title: 13pt in 600.
public struct SHSheetHeading<Trailing: View>: View {
    let title: String
    let trailing: Trailing

    public init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: SH.Space.l) {
            Text(title).font(.shSans(SHSettingsSheetMetrics.textSize, .semibold)).foregroundStyle(Color.sh.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            trailing.font(.shSans(SHSettingsSheetMetrics.textSize, .medium))
        }
        .frame(minHeight: SHSettingsSheetMetrics.baseLine)
    }
}

extension SHSheetHeading where Trailing == EmptyView {
    public init(_ title: String) {
        self.init(title) { EmptyView() }
    }
}

/// A rule that runs from one edge of the sheet to the other.
public struct SHSheetRule: View {
    public init() {}

    public var body: some View {
        SHHairline(color: Color.sh.lineStrong, width: SHSettingsNavMetrics.borderWidth)
            .padding(.horizontal, -SHSettingsSheetMetrics.inset)
            .padding(.vertical, SH.Space.xxs)
    }
}

/// A sheet's words: `plain` 13/19 in `textSecondary`, `small` 12/17 in `textTertiary`, `big` 14/20 in 500 `textPrimary`.
public struct SHSheetParagraph: View {
    public enum Style: Sendable { case plain, small, big }

    let text: Text
    let style: Style
    let centered: Bool

    public init(_ text: String, style: Style = .plain, centered: Bool = false) {
        self.text = Text(text)
        self.style = style
        self.centered = centered
    }

    public init(_ text: Text, style: Style = .plain, centered: Bool = false) {
        self.text = text
        self.style = style
        self.centered = centered
    }

    public var body: some View {
        let M = SHSettingsSheetMetrics.self
        let sh = Color.sh
        Group {
            switch style {
            case .plain: text.shSheetText(size: M.textSize, lineHeight: M.textLine).foregroundStyle(sh.textSecondary)
            case .small: text.shSheetText(size: M.smallSize, lineHeight: M.smallLine).foregroundStyle(sh.textTertiary)
            case .big: text.shSheetText(size: M.bigSize, weight: .medium, lineHeight: M.bigLine).foregroundStyle(sh.textPrimary)
            }
        }
        .multilineTextAlignment(centered ? .center : .leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
    }
}

extension View {
    /// A block that sits 8pt closer to the one above it.
    public func shSheetTight() -> some View {
        padding(.top, -SHSettingsSheetMetrics.tight)
    }
}

/// A label over a field: 12pt in 500 `textSecondary`.
public struct SHSheetFieldLabel<Trailing: View>: View {
    let title: String
    let trailing: Trailing

    public init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: SH.Space.m) {
            Text(title).font(.shSans(SHSettingsSheetMetrics.smallSize, .medium))
            Spacer(minLength: 0)
            trailing.font(.shSans(SHSettingsSheetMetrics.smallSize))
        }
        .foregroundStyle(Color.sh.textSecondary)
        .frame(minHeight: SHSettingsSheetMetrics.baseLine)
        .padding(.bottom, SHSettingsSheetMetrics.fieldLabelGap)
    }
}

extension SHSheetFieldLabel where Trailing == EmptyView {
    public init(_ title: String) {
        self.init(title) { EmptyView() }
    }
}

/// A one-line field's box: 32pt, a 1pt line at radius 8 on the sheet's own fill; the focused one's line darkens and a 3pt halo
/// rises round it, a wrong one's turns `failed`.
public struct SHSheetField<Content: View>: View {
    let focused: Bool
    let failed: Bool
    let content: Content

    public init(focused: Bool = false, failed: Bool = false, @ViewBuilder content: () -> Content) {
        self.focused = focused
        self.failed = failed
        self.content = content()
    }

    public var body: some View {
        let sh = Color.sh
        let M = SHSettingsSheetMetrics.self
        HStack(spacing: SH.Space.m) { content }
            .padding(.horizontal, M.fieldSides)
            .frame(maxWidth: .infinity, minHeight: M.fieldHeight, alignment: .leading)
            .background(sh.bgRaised, in: RoundedRectangle(cornerRadius: M.fieldRadius))
            .overlay {
                RoundedRectangle(cornerRadius: M.fieldRadius)
                    .strokeBorder(failed ? sh.failed : focused ? sh.textTertiary : sh.lineStrong, lineWidth: SHSettingsNavMetrics.borderWidth)
            }
            .background {
                if focused {
                    RoundedRectangle(cornerRadius: M.fieldRadius + M.focusRing).fill(sh.bgSelected)
                        .padding(-M.focusRing)
                }
            }
    }
}

/// A line of small print under a field.
public struct SHSheetFieldNote: View {
    let text: String
    let tone: SHSheetStatus.Tone

    public init(_ text: String, tone: SHSheetStatus.Tone = .quiet) {
        self.text = text
        self.tone = tone
    }

    public var body: some View {
        Text(text)
            .shSheetText(size: SHSettingsSheetMetrics.smallSize, lineHeight: SHSettingsSheetMetrics.smallLine)
            .foregroundStyle(tone == .failed ? Color.sh.failed : tone == .now ? Color.sh.textSecondary : Color.sh.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, SH.Space.s)
    }
}

/// A quiet box (`gset-way`, `gset-result`): a `bgHover` tile at radius 10 holding what it says.
public struct SHSheetGroup<Content: View>: View {
    let on: Bool
    let content: Content

    public init(on: Bool = true, @ViewBuilder content: () -> Content) {
        self.on = on
        self.content = content()
    }

    public var body: some View {
        let M = SHSettingsSheetMetrics.self
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(M.groupPad)
            .background(on ? Color.sh.bgHover : Color.clear, in: RoundedRectangle(cornerRadius: M.groupRadius))
            .padding(.horizontal, -M.groupPad)
    }
}

/// A command's output, or what a tool printed: mono 12 on a quiet box.
public struct SHSheetPre: View {
    let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(.shMono(SHSettingsSheetMetrics.smallSize))
            .foregroundStyle(Color.sh.textSecondary)
            .lineSpacing(SHSettingsSheetMetrics.preLineExtra)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(SHSettingsSheetMetrics.prePad)
            .background(Color.sh.bgHover, in: RoundedRectangle(cornerRadius: SHSettingsSheetMetrics.preRadius))
    }
}

extension SHSettingsSheetMetrics {
    /// 12pt mono on 18pt lines.
    public static let preLineExtra: CGFloat = 3
}

/// A step: its title (and a note under it) at the left, its state in words at the right ("Done", "Now", "Failed"). Nothing spins.
public struct SHSheetStep: View {
    public enum State: Sendable { case done, now, wait, failed }

    let title: String
    let note: String?
    let word: String
    let state: State

    public init(_ title: String, note: String? = nil, word: String, state: State) {
        self.title = title
        self.note = note
        self.word = word
        self.state = state
    }

    public var body: some View {
        let sh = Color.sh
        let M = SHSettingsSheetMetrics.self
        HStack(alignment: .top, spacing: M.stepGap) {
            VStack(alignment: .leading, spacing: M.stepNoteGap) {
                Text(title)
                    .font(.shSans(M.textSize, state == .now ? .medium : .regular))
                    .foregroundStyle(state == .wait ? sh.textTertiary : sh.textPrimary)
                if let note {
                    Text(note)
                        .shSheetText(size: M.smallSize, mono: state == .failed, lineHeight: M.smallLine)
                        .foregroundStyle(state == .failed ? sh.failed : sh.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(word)
                .font(.shSans(M.stepWordSize, state == .now || state == .failed ? .medium : .regular))
                .foregroundStyle(state == .now ? sh.textPrimary : state == .failed ? sh.failed : sh.textTertiary)
                .fixedSize()
        }
        .padding(.vertical, M.stepVertical)
        .overlay(alignment: .bottom) { SHHairline(color: sh.lineStrong, width: SHSettingsNavMetrics.borderWidth) }
        .accessibilityElement(children: .combine)
    }
}

/// The steps' list: a rule above the first and under each.
public struct SHSheetSteps<Content: View>: View {
    let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { SHHairline(color: Color.sh.lineStrong, width: SHSettingsNavMetrics.borderWidth) }
    }
}

/// A sheet's list of plain lines, 6pt apart in `textSecondary`.
public struct SHSheetLines: View {
    let lines: [String]

    public init(_ lines: [String]) {
        self.lines = lines
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SHSettingsSheetMetrics.linesGap) {
            ForEach(lines, id: \.self) { SHSheetParagraph($0) }
        }
    }
}

extension View {
    /// Words set the way the boards' CSS lays a line box out: `lineHeight` (a multiple of the size) for every line, the last
    /// included, where SwiftUI's line spacing only falls between lines.
    @MainActor func shSheetText(size: CGFloat, weight: Font.Weight = .regular, mono: Bool = false, lineHeight: CGFloat) -> some View {
        shText(size: size, weight: weight, mono: mono, lineHeight: lineHeight)
            .padding(.bottom, SHLineSpacing.extra(size: size, weight: weight, mono: mono, lineHeight: lineHeight))
    }
}
