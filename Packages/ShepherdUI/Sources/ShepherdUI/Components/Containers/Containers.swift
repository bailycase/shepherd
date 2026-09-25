import SwiftUI

/// A section label ("THIS MAC  19"): micro mono caps in tertiary, with an optional trailing
/// count or accessory.
public struct NWSectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder let trailing: () -> Trailing

    public init(_ title: String, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.trailing = trailing
    }

    public var body: some View {
        HStack(spacing: NW.Space.s) {
            Text(title).nwSectionLabel().lineLimit(1)
            Spacer(minLength: NW.Space.xs)
            trailing()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

extension NWSectionHeader where Trailing == Text? {
    public init(_ title: String, count: Int? = nil) {
        self.init(title) {
            count.map { Text("\($0)").font(.nw(.micro)).foregroundStyle(.nw.textTertiary) }
        }
    }
}

/// A grouped card (settings groups, lists of rows): `.nwCard()` with a 1px `lineSubtle` rule
/// between its children. Pass rows; the rules are inserted. `fill` replaces the raised fill
/// (Settings' cards are flat on `bgWindow`, drawn by their line alone).
public struct NWGroupCard<Content: View>: View {
    let fill: Color?
    @ViewBuilder let content: () -> Content

    public init(fill: Color? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.fill = fill
        self.content = content
    }

    public var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content()) { subviews in
                ForEach(subviews) { subview in
                    if subview.id != subviews.first?.id { NWHairline() }
                    subview
                }
            }
        }
        .nwCard(fill: fill)
    }
}

/// How an `NWCardRow` sets its text.
public enum NWCardRowStyle: Sendable {
    /// The compact card row of sheets and the phone's forms: `ui` over `caption`, 16pt before the
    /// control.
    case standard
    /// The Settings boards' row: a 13.5/500 title over a 12.5/1.45 description with inline markup
    /// (`NWMarkupText`), 2pt apart, 24pt before the control, and a problem led by an `xmark`.
    case settings
}

/// A card row (settings): title, optional description and inline problem (in `failed`), and a
/// trailing control. At least 52pt, scaled by density. The problem line discloses; animate the
/// page around it (`nwAnimation(.disclosure, value: problem)`) so the card grows in step.
/// `problemHelp` is the problem's tooltip: the technical reason behind the plain sentence.
public struct NWCardRow<Control: View>: View {
    let title: String
    let description: String?
    let problem: String?
    let problemHelp: String?
    let style: NWCardRowStyle
    @ViewBuilder let control: () -> Control

    public init(_ title: String, description: String? = nil, problem: String? = nil, problemHelp: String? = nil,
                style: NWCardRowStyle = .standard, @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.description = description
        self.problem = problem
        self.problemHelp = problemHelp
        self.style = style
        self.control = control
    }

    public var body: some View {
        let nw = Color.nw
        let settings = style == .settings
        HStack(alignment: .center, spacing: settings ? NW.Space.xxl : NW.Space.xl) {
            VStack(alignment: .leading, spacing: settings ? NW.Space.xxs : 3) {
                Text(title)
                    .font(settings ? .nw(.body, weight: .medium) : .nw(.ui))
                    .foregroundStyle(nw.textPrimary)
                if let description {
                    Group {
                        if settings {
                            NWMarkupText(description, size: NWTextStyle.ui.size,
                                           lineHeight: NWCardRowMetrics.settingsDescriptionLineHeight)
                        } else {
                            Text(description).nwText(.caption)
                        }
                    }
                    .foregroundStyle(nw.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if let problem {
                    Group {
                        if settings {
                            NWInlineProblem(problem, help: problemHelp)
                                .padding(.top, NW.Space.xs - NW.Space.xxs)
                        } else {
                            Text(problem).nwText(.caption).foregroundStyle(nw.failed)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                    .nwTransition(.disclosure)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
        }
        .padding(.horizontal, NW.Space.xl)
        .padding(.vertical, NW.Space.l)
        .frame(minHeight: NW.Height.scaled(52))
    }
}

/// An inline problem in a Settings row (the listener's bind error, a failed host): a 12pt `xmark`
/// in `failed`, then one plain sentence in the description's size. The technical reason is only
/// its tooltip, never the message.
public struct NWInlineProblem: View {
    let text: String
    let help: String?

    public init(_ text: String, help: String? = nil) {
        self.text = text
        self.help = help
    }

    public var body: some View {
        let nw = Color.nw
        HStack(alignment: .firstTextBaseline, spacing: NW.Space.s) {
            Image(systemName: "xmark")
                .font(.nwSans(NWCardRowMetrics.problemGlyphSize, .medium))
                .accessibilityHidden(true)
            Text(text)
                .nwText(size: NWTextStyle.ui.size, lineHeight: NWCardRowMetrics.settingsDescriptionLineHeight)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .foregroundStyle(nw.failed)
        .modifier(NWOptionalHelp(text: help))
        .accessibilityElement(children: .combine)
    }
}

/// The Settings style of `NWCardRow` and its problem line.
public enum NWCardRowMetrics {
    /// A settings description (and its problem) is 12.5 on 1.45 lines.
    public static let settingsDescriptionLineHeight: CGFloat = 1.45
    public static let problemGlyphSize: CGFloat = 12
}

/// A tooltip only when there is something to say.
private struct NWOptionalHelp: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text, !text.isEmpty {
            content.help(text)
        } else {
            content
        }
    }
}
