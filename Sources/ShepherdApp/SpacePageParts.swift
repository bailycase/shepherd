import SwiftUI
import ShepherdUI

/// The measures the space pages (settings form, resources, MCP, browser) take from the Mac boards' `gspc` markup
/// (ProjectParentSettings, ProjectSkills, ProjectMCP, ProjectBrowser): a 680pt column 40pt in from the modal's sides,
/// 44pt under its top and 24pt between blocks, over a 52pt bar.
extension AppLayout {
    static let spacePageSides: CGFloat = 40
    static let spacePageTop: CGFloat = 44
    static let spacePageBottom: CGFloat = 40
    static let spacePageGap: CGFloat = SH.Space.xxl
    /// The "‹ parent" line sits 24pt above the column's top, 18pt tall, 4pt over the title.
    static let spacePageUpHeight: CGFloat = 18
    static let spacePageUpRaise: CGFloat = SH.Space.xxl
    static let spacePageTitleLine: CGFloat = 24
    static let spacePageBarHeight: CGFloat = 52
    static let spacePageBarLeading: CGFloat = 44
    static let spacePageIntroWidth: CGFloat = 560
    static let spaceRowMinHeight: CGFloat = 44
    static let spaceRowSides: CGFloat = 14
    static let spaceRowGap: CGFloat = SH.Space.xl
    static let spaceControlGap: CGFloat = 14
    static let spaceMenuWidth: CGFloat = 290
    static let spaceMenuHeight: CGFloat = 26
    static let spaceFieldWidth: CGFloat = 150
    static let spaceWideFieldWidth: CGFloat = 190
    static let spaceStepperButton: CGFloat = 26
    static let spaceStepperValue: CGFloat = 28
    static let spaceFilterHeight: CGFloat = 44
    static let spaceSearchWidth: CGFloat = 200
    static let spaceSearchHeight: CGFloat = 26
    static let spaceTabHeight: CGFloat = 22
    static let spaceKindHeight: CGFloat = 24
    static let spaceBannerRadius: CGFloat = 10
    static let spaceEmptyPadding: CGFloat = 36
    static let spaceCookieCountWidth: CGFloat = 40
    static let spaceCookieActionWidth: CGFloat = 110
    static let spaceLeadWidth: CGFloat = 600
    static let spaceEditorHeaderHeight: CGFloat = 40
    static let spaceEditorMinHeight: CGFloat = 120
    static let spaceDetailSize: CGFloat = 11.5
    static let spaceFromWidth: CGFloat = 128
    static let spaceRemoveWidth: CGFloat = 52
    static let spaceBarOffOpacity: Double = 0.3
    static let spaceToolsGap: CGFloat = 18
    /// The board's line boxes as multiples of the type size: a row's title 18 on 13, a hint 16 on 12, the intro 19 on 13, a status 17 on 12.
    static let spaceTitleLine: CGFloat = 18 / 13
    static let spaceHintLine: CGFloat = 16 / 12
    static let spaceIntroLine: CGFloat = 19 / 13
    static let spaceStatusLine: CGFloat = 17 / 12
}

// MARK: Page

/// A space page's header (`gspc-top`): the line back to the parent page, the title with its caption and trailing
/// links, and the line under it that says what the page is for.
struct SpacePageHeader<Trailing: View>: View {
    var up: (label: String, action: () -> Void)?
    let title: String
    var subtitle: String?
    var intro: String?
    var disabled = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.s) {
            if let up {
                Button(action: up.action) {
                    HStack(spacing: SH.Space.xs) {
                        Image(systemName: "chevron.left").font(.shSans(SHSettingsControlMetrics.popupChevronSize, .medium)).accessibilityHidden(true)
                        Text(up.label)
                    }
                    .font(.sh(.caption)).foregroundStyle(Color.sh.textSecondary)
                    .frame(height: AppLayout.spacePageUpHeight).contentShape(Rectangle())
                }
                .buttonStyle(.plain).shFocusRing(radius: SH.Radius.xs, color: .sh.running)
                .accessibilityLabel("Back to \(up.label)").disabled(disabled)
                // The board pulls the line 24pt above the column and sets the title 4pt under the column's top; a layout
                // size cannot go negative, so the line takes none and the title is drawn up.
                .offset(y: -AppLayout.spacePageUpRaise).frame(height: 0, alignment: .top)
            }
            HStack(alignment: .firstTextBaseline, spacing: SH.Space.xl) {
                HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
                    Text(title).font(.shSans(SHTextStyle.display.size - SH.Space.xs, .semibold)).foregroundStyle(Color.sh.textPrimary)
                        .lineLimit(1).accessibilityAddTraits(.isHeader)
                    if let subtitle {
                        Text(subtitle).font(.sh(.ui)).foregroundStyle(Color.sh.textTertiary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                HStack(alignment: .firstTextBaseline, spacing: SH.Space.xl) { trailing }.fixedSize()
            }
            .padding(.horizontal, SH.Space.xs).frame(minHeight: AppLayout.spacePageTitleLine)
            .padding(.top, up == nil ? 0 : -(SH.Space.xxs))
            if let intro {
                Text(intro).shText(size: SHTextStyle.ui.size, lineHeight: AppLayout.spaceIntroLine).foregroundStyle(Color.sh.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: AppLayout.spacePageIntroWidth, alignment: .leading).padding(.horizontal, SH.Space.xs)
            }
        }
    }
}

extension SpacePageHeader where Trailing == EmptyView {
    init(up: (label: String, action: () -> Void)? = nil, title: String, subtitle: String? = nil, intro: String? = nil, disabled: Bool = false) {
        self.init(up: up, title: title, subtitle: subtitle, intro: intro, disabled: disabled, trailing: { EmptyView() })
    }
}

/// The column of a space page and its bar: the header and blocks scroll, the bar stays.
struct SpacePageFrame<Content: View, Bar: View>: View {
    var scrolls = true
    @ViewBuilder var content: Content
    @ViewBuilder var bar: Bar

    var body: some View {
        VStack(spacing: 0) {
            if scrolls {
                ScrollView {
                    column
                }.scrollIndicators(.automatic)
            } else {
                column.frame(maxHeight: .infinity, alignment: .top)
            }
            bar
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: AppLayout.spacePageGap) { content }
            .padding(.horizontal, AppLayout.spacePageSides)
            .padding(.top, AppLayout.spacePageTop).padding(.bottom, AppLayout.spacePageBottom)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

extension SpacePageFrame where Bar == EmptyView {
    init(scrolls: Bool = true, @ViewBuilder content: () -> Content) {
        self.init(scrolls: scrolls, content: content, bar: { EmptyView() })
    }
}

/// The page's bar (`gspc-bar`): what state the page is in, what saving applies to, then its actions.
enum SpaceBarTone { case plain, warn, bad }

struct SpacePageBar<Actions: View>: View {
    let status: String
    var tone: SpaceBarTone = .plain
    let note: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: AppLayout.spaceControlGap) {
            if !status.isEmpty {
                Text(status).font(.sh(.caption, weight: tone == .plain ? .regular : .medium)).foregroundStyle(color).lineLimit(1)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            Text(note).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            actions
        }
        .padding(.leading, AppLayout.spacePageBarLeading).padding(.trailing, AppLayout.spacePageSides)
        .frame(height: AppLayout.spacePageBarHeight)
        .background(Color.sh.bgWindow)
        .overlay(alignment: .top) { SHHairline(color: Color.sh.lineSubtle) }
    }

    private var color: Color {
        switch tone { case .plain: Color.sh.textSecondary; case .warn: Color.sh.lanternText; case .bad: Color.sh.failed }
    }
}

// MARK: Sections

/// A section: its name and what it holds on one line (`gspc-shd`), the links at its right, then its card.
struct SpaceSection<Trailing: View, Content: View>: View {
    let title: String
    var note: String?
    /// A paragraph between the header and the card (`gspc-lead`).
    var lead: String?
    var footnote: String?
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.m) {
            if !title.isEmpty || note != nil {
            HStack(alignment: .firstTextBaseline, spacing: SH.Space.l) {
                Text(title).font(.sh(.ui, weight: .semibold)).foregroundStyle(Color.sh.textPrimary).lineLimit(1).fixedSize()
                    .accessibilityAddTraits(.isHeader)
                if let note {
                    Text(note).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 0)
                HStack(alignment: .firstTextBaseline, spacing: SH.Space.xl) { trailing }.fixedSize()
            }.padding(.horizontal, SH.Space.xs).frame(minHeight: AppLayout.spacePageUpHeight)
            }
            if let lead {
                Text(lead).shText(size: SHTextStyle.ui.size, lineHeight: AppLayout.spaceIntroLine).foregroundStyle(Color.sh.textSecondary)
                    .frame(maxWidth: AppLayout.spaceLeadWidth, alignment: .leading).padding(.horizontal, SH.Space.xs).padding(.bottom, SH.Space.xs)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SpaceCard { content }
            if let footnote {
                Text(footnote).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary).padding(.horizontal, SH.Space.xs)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.accessibilityElement(children: .contain).accessibilityLabel(title)
    }
}

extension SpaceSection where Trailing == EmptyView {
    init(_ title: String, note: String? = nil, lead: String? = nil, footnote: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, note: note, lead: lead, footnote: footnote, trailing: { EmptyView() }, content: content)
    }
}

/// A status line under a page's title (`gspc-status`).
struct SpacePageStatus: View {
    let text: String
    var alert = false
    var failed = false

    var body: some View {
        Text(text).shText(size: SHTextStyle.caption.size, lineHeight: AppLayout.spaceStatusLine)
            .foregroundStyle(failed ? Color.sh.failed : alert ? Color.sh.lanternText : Color.sh.textTertiary)
            .padding(.horizontal, SH.Space.xs).fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.updatesFrequently)
    }
}

// MARK: Rows

/// A form row (`gspc-row`): title, what it does, where its value comes from with an inline reset, and the control.
struct SpaceRow<Control: View>: View {
    let title: String
    var hint: String?
    var source: String?
    var reset: (label: String, accessibility: String, action: () -> Void, enabled: Bool)?
    var problem: String?
    var dim = false
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: AppLayout.spaceRowGap) {
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(title).shText(size: SHTextStyle.ui.size, lineHeight: AppLayout.spaceTitleLine)
                    .foregroundStyle(dim ? Color.sh.textTertiary : Color.sh.textPrimary)
                if let hint {
                    Text(hint).shText(size: SHTextStyle.caption.size, lineHeight: AppLayout.spaceHintLine)
                        .foregroundStyle(Color.sh.textTertiary).fixedSize(horizontal: false, vertical: true)
                }
                if source != nil || reset != nil {
                    HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
                        if let source {
                            Text(source).shText(size: SHTextStyle.caption.size, lineHeight: AppLayout.spaceHintLine)
                                .foregroundStyle(Color.sh.textTertiary).fixedSize(horizontal: false, vertical: true)
                        }
                        if let reset {
                            Button(reset.label, action: reset.action).buttonStyle(SpaceLinkStyle(tone: .strong, caption: true))
                                .disabled(!reset.enabled).accessibilityLabel(reset.accessibility)
                        }
                    }
                }
                if let problem {
                    Text(problem).font(.sh(.caption)).foregroundStyle(Color.sh.failed).fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: AppLayout.spaceControlGap) { control }.fixedSize()
        }
        .padding(.horizontal, AppLayout.spaceRowSides).padding(.vertical, SH.Space.m)
        .frame(minHeight: AppLayout.spaceRowMinHeight)
        .accessibilityElement(children: .contain)
    }
}

/// A button written as words (`gspc-btn`, `gspc-ha`, `gspc-a`): medium and `textPrimary`, or quiet.
struct SpaceLinkStyle: ButtonStyle {
    enum Tone { case strong, plain, quiet, danger }
    var tone: Tone = .plain
    /// An inline action in a hint's size, not a row's.
    var caption = false
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.sh(caption ? .caption : .ui, weight: tone == .quiet || tone == .danger ? .regular : .medium))
            .foregroundStyle(color(hover: hovering && enabled))
            .lineLimit(1).fixedSize()
            .opacity(configuration.isPressed ? 0.6 : 1)
            .shEnabledOpacity(enabled)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .shFocusRing(radius: SH.Radius.xs)
    }

    private func color(hover: Bool) -> Color {
        switch tone {
        case .strong: Color.sh.textPrimary
        case .plain: hover ? Color.sh.textPrimary : Color.sh.textSecondary
        case .quiet: hover ? Color.sh.textSecondary : Color.sh.textTertiary
        case .danger: Color.sh.failed
        }
    }
}

/// A pop-up in a row (`gspc-menu`): 26pt, a 1pt line at radius 7, the value then up-and-down chevrons.
struct SpaceMenu<Items: View>: View {
    let label: String
    let value: String
    var width: CGFloat = AppLayout.spaceMenuWidth
    var mono = false
    @ViewBuilder var items: Items

    var body: some View {
        Menu(content: { items }) {
            HStack(spacing: SH.Space.s) {
                Text(value).font(mono ? .sh(.mono) : .sh(.ui)).foregroundStyle(Color.sh.textPrimary).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                SHGlyph.popupChevrons.image.font(.shSans(SHSettingsControlMetrics.popupChevronSize)).foregroundStyle(Color.sh.textTertiary).accessibilityHidden(true)
            }
            .padding(.leading, SH.Space.l - SH.Space.xxs).padding(.trailing, SH.Space.m)
            .frame(width: width, height: AppLayout.spaceMenuHeight)
            .overlay { RoundedRectangle(cornerRadius: SH.Radius.s).strokeBorder(Color.sh.lineSubtle) }
            .contentShape(RoundedRectangle(cornerRadius: SH.Radius.s))
        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel(label).accessibilityValue(value)
    }
}

/// A text field in a row (`gspc-field`): 26pt, mono, a 1pt line at radius 6, the inherited value as its placeholder.
struct SpaceField: View {
    let label: String
    let prompt: String
    @Binding var text: String
    var width: CGFloat = AppLayout.spaceFieldWidth
    var invalid = false

    var body: some View {
        TextField(label, text: $text, prompt: Text(prompt).foregroundStyle(Color.sh.textTertiary))
            .textFieldStyle(.plain).font(.sh(.mono)).foregroundStyle(Color.sh.textPrimary)
            .padding(.horizontal, SH.Space.m).frame(width: width, height: AppLayout.spaceMenuHeight)
            .overlay { RoundedRectangle(cornerRadius: SH.Radius.s).strokeBorder(invalid ? Color.sh.failed : Color.sh.lineSubtle) }
            .accessibilityLabel(label)
    }
}

/// The retry count (`gspc-step`): a minus, the number between two lines, a plus.
struct SpaceStepper: View {
    let label: String
    @Binding var value: Int
    var range: ClosedRange<Int>

    var body: some View {
        HStack(spacing: 0) {
            step("minus", "Decrease \(label)") { value = max(range.lowerBound, value - 1) }.disabled(value <= range.lowerBound)
            Text("\(value)").font(.sh(.ui, weight: .medium)).foregroundStyle(Color.sh.textPrimary).monospacedDigit()
                .frame(minWidth: AppLayout.spaceStepperValue, maxHeight: .infinity)
                .overlay(alignment: .leading) { SHHairline(.vertical, color: Color.sh.lineSubtle) }
                .overlay(alignment: .trailing) { SHHairline(.vertical, color: Color.sh.lineSubtle) }
            step("plus", "Increase \(label)") { value = min(range.upperBound, value + 1) }.disabled(value >= range.upperBound)
        }.frame(height: AppLayout.spaceMenuHeight)
            .overlay { RoundedRectangle(cornerRadius: SH.Radius.s).strokeBorder(Color.sh.lineSubtle) }
            .accessibilityElement(children: .contain).accessibilityLabel(label).accessibilityValue("\(value)")
    }

    private func step(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.sh(.caption, weight: .medium)).foregroundStyle(Color.sh.textSecondary)
                .frame(width: AppLayout.spaceStepperButton, height: AppLayout.spaceMenuHeight).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(label)
    }
}

/// The tabs across the top of a page (`gspc-kinds`): a filled track with the shown one lifted.
struct SpaceKindTabs<Value: Hashable>: View {
    let label: String
    @Binding var selection: Value
    let options: [(Value, String)]

    var body: some View {
        HStack(spacing: SH.Space.xxs) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let on = option.0 == selection
                Button { selection = option.0 } label: {
                    Text(option.1).font(.sh(.ui, weight: on ? .medium : .regular)).foregroundStyle(on ? Color.sh.textPrimary : Color.sh.textSecondary)
                        .padding(.horizontal, SH.Space.l).frame(height: AppLayout.spaceKindHeight).fixedSize()
                        .modifier(SpaceLiftedIf(on: on))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(option.1).accessibilityAddTraits(on ? .isSelected : [])
            }
        }.padding(SH.Space.xxs).background(Color.sh.bgHover, in: RoundedRectangle(cornerRadius: SH.Radius.m))
            .accessibilityElement(children: .contain).accessibilityLabel(label)
    }
}

/// The chosen tab: a card lifted at radius `s`.
private struct SpaceLiftedIf: ViewModifier {
    let on: Bool

    func body(content: Content) -> some View {
        if on { content.shLift(RoundedRectangle(cornerRadius: SH.Radius.s), fill: Color.sh.bgRaised) } else { content }
    }
}

/// A bar's actions (`gspc-b`): words, `strong` in medium, `quiet` in `textSecondary`; the primary one a filled pill.
struct SpaceBarStyle: ButtonStyle {
    enum Kind { case quiet, strong, primary }
    var kind: Kind = .quiet
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let primary = kind == .primary
        configuration.label
            .font(.sh(.ui, weight: primary || kind == .strong ? .medium : .regular))
            .foregroundStyle(primary ? Color.sh.textOnPrimary : !enabled ? Color.sh.textTertiary
                             : kind == .strong || hovering ? Color.sh.textPrimary : Color.sh.textSecondary)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, primary ? SH.Space.l : 0)
            .frame(height: primary ? AppLayout.spaceMenuHeight : nil)
            .background { if primary { Capsule().fill(configuration.isPressed ? Color.sh.primaryPressed : hovering && enabled ? Color.sh.primaryHover : Color.sh.primary) } }
            .offset(y: configuration.isPressed ? SHProjectSettingsMetrics.pressOffset : 0)
            .opacity(enabled || !primary ? 1 : AppLayout.spaceBarOffOpacity)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .shFocusRing(radius: SH.Radius.s)
    }
}

/// A section's card (`gspc-card`): the raised fill and a lift at radius 12, a rule between its rows.
struct SpaceCard<Content: View>: View {
    /// Build only the rows near the screen: a list that can run to hundreds of rows.
    var lazy = false
    @ViewBuilder var content: Content

    var body: some View {
        Group {
            if lazy { LazyVStack(spacing: 0) { rows } } else { VStack(spacing: 0) { rows } }
        }.shCard(radius: SH.Radius.l, lift: true)
    }

    private var rows: some View {
        Group(subviews: content) { subviews in
            ForEach(subviews) { subview in
                if subview.id != subviews.first?.id { SHHairline() }
                subview
            }
        }
    }
}

/// A list's search field (`gspc-search`): 26pt, a `bgHover` fill at radius 7.
struct SpaceSearchField: View {
    let prompt: String
    @Binding var text: String
    var width: CGFloat = AppLayout.spaceSearchWidth

    var body: some View {
        HStack(spacing: SH.Space.s) {
            Image(systemName: "magnifyingglass").font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary).accessibilityHidden(true)
            TextField(prompt, text: $text, prompt: Text(prompt).foregroundStyle(Color.sh.textTertiary))
                .textFieldStyle(.plain).font(.sh(.ui)).foregroundStyle(Color.sh.textPrimary)
        }.padding(.horizontal, SH.Space.m).frame(width: width, height: AppLayout.spaceSearchHeight)
            .background(Color.sh.bgHover, in: RoundedRectangle(cornerRadius: SH.Radius.s))
            .accessibilityElement(children: .contain)
    }
}

/// A list's filter tabs (`gspc-ftabs`): words, the chosen one on a `bgSelected` pill.
struct SpaceFilterTabs<Value: Hashable>: View {
    let label: String
    @Binding var selection: Value
    let options: [(Value, String)]

    var body: some View {
        HStack(spacing: SH.Space.xxs) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let on = option.0 == selection
                Button { selection = option.0 } label: {
                    Text(option.1).font(.sh(.ui)).foregroundStyle(on ? Color.sh.textPrimary : Color.sh.textSecondary)
                        .padding(.horizontal, SH.Space.l - SH.Space.xxs).frame(height: AppLayout.spaceTabHeight).fixedSize()
                        .background(on ? Color.sh.bgSelected : .clear, in: RoundedRectangle(cornerRadius: SH.Radius.s))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(option.1).accessibilityAddTraits(on ? .isSelected : [])
            }
        }.accessibilityElement(children: .contain).accessibilityLabel(label)
    }
}

/// The empty state inside a card (`gspc-empty`): a medium title, a line under it and an action.
struct SpaceEmpty<Action: View>: View {
    let title: String
    var message: String?
    @ViewBuilder var action: Action

    var body: some View {
        VStack(spacing: SH.Space.xs) {
            Text(title).font(.sh(.body, weight: .medium)).foregroundStyle(Color.sh.textPrimary)
            if let message { Text(message).font(.sh(.ui)).foregroundStyle(Color.sh.textSecondary).multilineTextAlignment(.center) }
            action.padding(.top, SH.Space.m)
        }.frame(maxWidth: .infinity).padding(.vertical, AppLayout.spaceEmptyPadding).padding(.horizontal, SH.Space.xl + SH.Space.xs)
    }
}

extension SpaceEmpty where Action == EmptyView {
    init(_ title: String, message: String? = nil) { self.init(title: title, message: message, action: { EmptyView() }) }
}
