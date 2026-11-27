import SwiftUI

/// A section label ("THIS MAC  19"): micro mono caps in tertiary, with an optional trailing
/// count or accessory.
public struct SHSectionHeader<Trailing: View>: View {
    /// `settings` is a Settings group's label (`ui` 600, `textPrimary`, sentence case);
    /// `settingsNav` is the label over a run of the Settings nav (caption 500, `textTertiary`).
    public enum Style: Sendable { case standard, settings, settingsNav }

    let title: String
    let style: Style
    @ViewBuilder let trailing: () -> Trailing

    public init(_ title: String, style: Style = .standard, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.style = style
        self.trailing = trailing
    }

    public var body: some View {
        HStack(spacing: SH.Space.s) {
            Group {
                if style == .settings {
                    Text(title).font(.sh(.ui, weight: .semibold)).foregroundStyle(Color.sh.textPrimary)
                } else if style == .settingsNav {
                    Text(title).font(.sh(.caption, weight: .medium)).foregroundStyle(Color.sh.textTertiary)
                } else {
                    Text(title).shSectionLabel()
                }
            }
            .lineLimit(1)
            Spacer(minLength: SH.Space.xs)
            trailing()
        }
        .accessibilityElement(children: Trailing.self == Text?.self ? .combine : .contain)
        .accessibilityAddTraits(.isHeader)
    }
}

extension SHSectionHeader where Trailing == SHSectionLink {
    /// A header with a plain link at its right (a Settings group's "Reset", "Manage…").
    public init(_ title: String, style: Style = .settings, link: String, action: @escaping () -> Void) {
        self.init(title, style: style) { SHSectionLink(title: link, action: action) }
    }
}

/// The trailing link of a section header: caption in `running`, a plain button.
public struct SHSectionLink: View {
    let title: String
    let action: () -> Void

    public init(title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    @Environment(\.shControlScale) private var scale

    public var body: some View {
        // A 24pt target around a caption-high word: the extra height overhangs the header's line. In Settings the
        // boards write it as a 500 word in `textSecondary`.
        Button(action: action) {
            Text(title)
                .font(scale.isSettings ? .shSans(SHSettingsControlMetrics.segmentTextSize, .medium) : .sh(.caption))
                .foregroundStyle(scale.isSettings ? Color.sh.textSecondary : Color.sh.running)
                .frame(minHeight: SH.Height.controlS).contentShape(Rectangle())
        }
            .buttonStyle(.plain)
            .padding(.vertical, -SH.Space.xs)
            .shFocusRing(radius: SH.Radius.xs, color: .sh.running)
    }
}

extension SHSectionHeader where Trailing == Text? {
    public init(_ title: String, count: Int? = nil, style: Style = .standard) {
        self.init(title, style: style) {
            count.map { Text("\($0)").font(.sh(.micro)).foregroundStyle(.sh.textTertiary) }
        }
    }
}

/// A grouped card (settings groups, lists of rows): `.shCard()` with a 1px `lineSubtle` rule
/// between its children. Pass rows; the rules are inserted. `fill` replaces the raised fill.
public struct SHGroupCard<Content: View>: View {
    let fill: Color?
    let radius: CGFloat
    let lazy: Bool
    let lift: Bool
    let rule: Color?
    @ViewBuilder let content: () -> Content

    /// `lazy` builds only the rows near the screen (a list that can run to hundreds of rows). `lift` raises the card
    /// on the boards' shadow and `rule` colors the lines between rows (the Settings cards).
    public init(fill: Color? = nil, radius: CGFloat = SH.Radius.m, lazy: Bool = false, lift: Bool = false, rule: Color? = nil,
                @ViewBuilder content: @escaping () -> Content) {
        self.fill = fill
        self.radius = radius
        self.lazy = lazy
        self.lift = lift
        self.rule = rule
        self.content = content
    }

    public var body: some View {
        Group {
            if lazy {
                LazyVStack(spacing: 0) { rows }
            } else {
                VStack(spacing: 0) { rows }
            }
        }
        // The boards' card takes its 1px line out of its own room, so the rows sit inside it.
        .padding(lift ? SHSettingsNavMetrics.borderWidth : 0)
        .shCard(radius: radius, fill: fill, lift: lift)
    }

    private var rows: some View {
        Group(subviews: content()) { subviews in
            ForEach(subviews) { subview in
                if subview.id != subviews.first?.id {
                    SHHairline(color: rule, width: rule == nil ? nil : SHSettingsNavMetrics.borderWidth)
                    // The boards' rows are 44pt with their rule inside it.
                    subview.environment(\.shRuleAbove, rule != nil)
                } else {
                    subview
                }
            }
        }
    }
}

/// How an `SHCardRow` sets its text.
public enum SHCardRowStyle: Sendable {
    /// The compact card row of sheets and the phone's forms: `ui` over `caption`, 16pt before the
    /// control.
    case standard
    /// The Settings row: a `ui` title in `textPrimary` over a one-line `caption` hint in
    /// `textTertiary` (inline markup, `SHMarkupText`), 12pt before the control, and a problem led
    /// by an `xmark`; at least 44pt, 6pt inside the top and bottom, 12pt at the sides.
    case settings
}

/// The color of a Settings row's hint: the quiet default, `lantern` when something wants you, `failed` when it broke.
public enum SHRowTone: Sendable {
    case normal, warn, bad
}

/// The 8pt status dot leading a Settings row: filled `done` when on, `lantern` when it wants you,
/// `failed` when broken, a hollow ring when off.
public enum SHRowDot: Sendable {
    case on, warn, bad, off
}

/// A card row (settings): title, optional description and inline problem (in `failed`), and a
/// trailing control. At least 52pt, scaled by density. The problem line discloses; animate the
/// page around it (`shAnimation(.disclosure, value: problem)`) so the card grows in step.
/// `problemHelp` is the problem's tooltip: the technical reason behind the plain sentence.
public struct SHCardRow<Control: View>: View {
    let title: String
    let description: String?
    let problem: String?
    let problemHelp: String?
    let style: SHCardRowStyle
    let dot: SHRowDot?
    let monoTitle: Bool
    let indented: Bool
    let descriptionTone: SHRowTone
    @ViewBuilder let control: () -> Control

    public init(_ title: String, description: String? = nil, descriptionTone: SHRowTone = .normal, problem: String? = nil, problemHelp: String? = nil,
                style: SHCardRowStyle = .standard, dot: SHRowDot? = nil, monoTitle: Bool = false, indented: Bool = false,
                @ViewBuilder control: @escaping () -> Control) {
        self.descriptionTone = descriptionTone
        self.dot = dot
        self.monoTitle = monoTitle
        self.indented = indented
        self.title = title
        self.description = description
        self.problem = problem
        self.problemHelp = problemHelp
        self.style = style
        self.control = control
    }

    public var body: some View {
        let sh = Color.sh
        let settings = style == .settings
        HStack(alignment: .center, spacing: settings ? SHCardRowMetrics.settingsControlGap : SH.Space.xl) {
            if let dot { SHRowDotView(dot) }
            VStack(alignment: .leading, spacing: settings ? SHCardRowMetrics.settingsTextSpacing : 3) {
                Text(title)
                    .font(monoTitle ? .sh(.mono) : settings ? .sh(.ui, weight: .regular) : .sh(.ui))
                    .foregroundStyle(sh.textPrimary)
                    .frame(minHeight: settings ? SHCardRowMetrics.settingsLineHeight : nil, alignment: .leading)
                if let description {
                    Group {
                        if settings {
                            SHMarkupText(description, size: SHTextStyle.caption.size,
                                           lineHeight: SHCardRowMetrics.settingsDescriptionLineHeight)
                                .lineLimit(1).truncationMode(.tail)
                                .frame(minHeight: SHCardRowMetrics.settingsLineHeight, alignment: .leading)
                        } else {
                            Text(description).shText(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .foregroundStyle(settings ? (descriptionTone == .warn ? sh.lantern : descriptionTone == .bad ? sh.failed : sh.textTertiary) : sh.textSecondary)
                }
                if let problem {
                    Group {
                        if settings {
                            SHInlineProblem(problem, help: problemHelp)
                                .padding(.top, SH.Space.xs - SH.Space.xxs)
                        } else {
                            Text(problem).shText(.caption).foregroundStyle(sh.failed)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                    .shTransition(.disclosure)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
        }
        .modifier(SHCardRowFrame(settings: settings))
        .padding(.leading, indented ? SH.Space.xxl : 0)
    }
}

/// The dot itself.
struct SHRowDotView: View {
    let dot: SHRowDot
    init(_ dot: SHRowDot) { self.dot = dot }

    var body: some View {
        let sh = Color.sh
        Group {
            switch dot {
            case .on: Circle().fill(sh.done)
            case .warn: Circle().fill(sh.lantern)
            case .bad: Circle().fill(sh.failed)
            case .off: Circle().strokeBorder(sh.textTertiary, lineWidth: 1)
            }
        }
        .frame(width: SHCardRowMetrics.dotSize, height: SHCardRowMetrics.dotSize)
        .accessibilityHidden(true)
    }
}

/// A card row's padding and least height: the compact row is at least 52pt with 12pt above and
/// below; a Settings row is at least 44pt, 6pt in from the top and the bottom.
public struct SHCardRowFrame: ViewModifier {
    let settings: Bool
    @Environment(\.shRuleAbove) private var ruleAbove

    public init(settings: Bool) { self.settings = settings }

    public func body(content: Content) -> some View {
        if settings {
            content
                .padding(.horizontal, SHCardRowMetrics.settingsHorizontalPadding)
                .padding(.vertical, SHCardRowMetrics.settingsVerticalPadding)
                .frame(minHeight: SH.Height.scaled(SHCardRowMetrics.settingsMinHeight) - (ruleAbove ? SHSettingsNavMetrics.borderWidth : 0))
        } else {
            content
                .padding(.horizontal, SH.Space.xl)
                .padding(.vertical, SH.Space.l)
                .frame(minHeight: SH.Height.scaled(SHCardRowMetrics.minHeight))
        }
    }
}

/// An inline problem in a Settings row (the listener's bind error, a failed host): a 12pt `xmark`
/// in `failed`, then one plain sentence in the description's size. The technical reason is only
/// its tooltip, never the message.
public struct SHInlineProblem: View {
    let text: String
    let help: String?

    public init(_ text: String, help: String? = nil) {
        self.text = text
        self.help = help
    }

    public var body: some View {
        let sh = Color.sh
        HStack(alignment: .firstTextBaseline, spacing: SH.Space.s) {
            Image(systemName: "xmark")
                .font(.shSans(SHCardRowMetrics.problemGlyphSize, .medium))
                .accessibilityHidden(true)
            Text(text)
                .shText(size: SHTextStyle.ui.size, lineHeight: SHCardRowMetrics.settingsDescriptionLineHeight)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .foregroundStyle(sh.failed)
        .modifier(SHOptionalHelp(text: help))
        .accessibilityElement(children: .combine)
    }
}

/// The Settings style of `SHCardRow` and its problem line.
public enum SHCardRowMetrics {
    /// Before density.
    public static let minHeight: CGFloat = 52
    /// A Settings row's least height, before density.
    public static let settingsMinHeight: CGFloat = 44
    /// A Settings row's top and bottom padding (the row's 44pt minimum holds a one-line title).
    public static let settingsVerticalPadding: CGFloat = SH.Space.m
    /// The Settings cards: radius `l`.
    public static let settingsCardRadius: CGFloat = SH.Radius.l
    /// A settings description (and its problem) sits on 1.45 lines.
    public static let settingsDescriptionLineHeight: CGFloat = 1.5
    /// A Settings row's side padding, the gap before its control, and the gap between its title and hint.
    public static let settingsHorizontalPadding: CGFloat = 14
    public static let settingsControlGap: CGFloat = SH.Space.xl
    public static let settingsTextSpacing: CGFloat = 1
    /// The title's and the hint's line (the boards' 18pt).
    public static let settingsLineHeight: CGFloat = 18
    public static let problemGlyphSize: CGFloat = 12
    /// A Settings row's status dot.
    public static let dotSize: CGFloat = 8
}

/// A tooltip only when there is something to say.
private struct SHOptionalHelp: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text, !text.isEmpty {
            content.help(text)
        } else {
            content
        }
    }
}

extension EnvironmentValues {
    /// A row under a rule inside a Settings card: the rule counts toward the row's least height.
    @Entry var shRuleAbove = false
}
