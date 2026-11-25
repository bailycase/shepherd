import SwiftUI
import ShepherdUI

// The phone, iPad and iPhone Duo boards' page parts (MobileSettings, MobileHooks, MobileAutomations,
// FleetA-phone and the iPad and Duo sets): a card of 52pt rows on the lift, a quiet caption over it,
// a pill switch, pill buttons. Settings, Automations, Fleet, Hosts and Projects draw their lists
// with these, so one board value lives in one place.

// MARK: Card

/// A card of rows: 16pt corners, a hairline and the board's lift, a rule between rows that starts
/// `inset` in (16pt; 56pt where a leading glyph does, as the Instructions files do).
struct SettingsCard<Content: View>: View {
    let inset: CGFloat
    @ViewBuilder let content: () -> Content

    init(inset: CGFloat = MobileLayout.settingsRowInset, @ViewBuilder content: @escaping () -> Content) {
        self.inset = inset
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content()) { subviews in
                ForEach(subviews) { subview in
                    if subview.id != subviews.first?.id { SHHairline().padding(.leading, inset) }
                    subview
                }
            }
        }
        .shCard(radius: MobileLayout.settingsCardRadius, lift: true)
    }
}

/// One card for a lazy stack, a segment per row (`SHLazyListCard`'s way, in the boards' corners and lift).
struct SettingsLazyCard<Data: RandomAccessCollection, Row: View>: View where Data.Element: Identifiable {
    let data: Data
    @ViewBuilder let row: (Data.Element) -> Row

    init(_ data: Data, @ViewBuilder row: @escaping (Data.Element) -> Row) {
        self.data = data
        self.row = row
    }

    var body: some View {
        let first = data.first?.id
        let last = data.last?.id
        LazyVStack(spacing: 0) {
            ForEach(data) { element in
                SettingsCardSegment(first: element.id == first, last: element.id == last) { row(element) }
            }
        }
    }
}

/// One row's share of a card: its corners where it ends the card, the rule above it otherwise.
struct SettingsCardSegment<Content: View>: View {
    let first: Bool
    let last: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        let radius = MobileLayout.settingsCardRadius
        let shape = UnevenRoundedRectangle(topLeadingRadius: first ? radius : 0, bottomLeadingRadius: last ? radius : 0,
                                           bottomTrailingRadius: last ? radius : 0, topTrailingRadius: first ? radius : 0)
        VStack(spacing: 0) {
            if !first { SHHairline().padding(.leading, MobileLayout.settingsRowInset) }
            content()
        }
        .background(Color.sh.bgRaised, in: shape)
        .clipShape(shape)
        .overlay {
            Color.clear
                .shBorder(.sh.lineSubtle, radius: radius)
                .padding(.top, first ? 0 : -radius)
                .padding(.bottom, last ? 0 : -radius)
                .clipped()
                .allowsHitTesting(false)
        }
    }
}

// MARK: Headings

/// A group's caption (the boards' `gt-sh`): quiet 13/500 secondary by default, or the loud 15/600
/// ("Running now 2"), lantern while it is what needs you. `code` is the mono word after it
/// ("SessionStart"); `count` the tertiary number; the trailing view sits at the right.
struct SettingsCaption<Trailing: View>: View {
    enum Tone { case quiet, loud, attention }

    let title: String
    let tone: Tone
    let code: String?
    let count: Int?
    @ViewBuilder let trailing: () -> Trailing

    init(_ title: String, tone: Tone = .quiet, code: String? = nil, count: Int? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.tone = tone
        self.code = code
        self.count = count
        self.trailing = trailing
    }

    var body: some View {
        let sh = Color.sh
        let loud = tone != .quiet
        HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
            Text(title)
                .font(loud ? .sh(.ui, weight: .semibold) : .shSans(MobileLayout.settingsCaptionSize, .medium))
                .foregroundStyle(tone == .attention ? sh.lanternText : loud ? sh.textPrimary : sh.textSecondary)
            if let code {
                Text(code)
                    .font(.shMono(MobileLayout.settingsCaptionSize))
                    .foregroundStyle(sh.textTertiary)
            }
            if let count {
                Text("\(count)")
                    .font(.shSans(loud ? SHTextStyle.ui.size : MobileLayout.settingsCaptionSize))
                    .foregroundStyle(tone == .attention ? sh.lanternText : sh.textTertiary)
            }
            Spacer(minLength: SH.Space.xs)
            trailing()
        }
        .lineLimit(1)
        .padding(.horizontal, SH.Space.xs)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

extension SettingsCaption where Trailing == EmptyView {
    init(_ title: String, tone: Tone = .quiet, code: String? = nil, count: Int? = nil) {
        self.init(title, tone: tone, code: code, count: count) { EmptyView() }
    }
}

/// The sentence under a page's title (the boards' `gt-lead`): 13pt secondary.
struct SettingsLead: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.shSans(MobileLayout.settingsCaptionSize))
            .foregroundStyle(Color.sh.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, SH.Space.xs)
    }
}

// MARK: Rows

/// One row of a card (the boards' `gt-r`): what leads it, a title over a note, a trailing value
/// and a chevron. 52pt at least, 16pt in at the sides.
struct SettingsRow: View, Equatable {
    /// What leads a row.
    enum Leading: Equatable, Sendable {
        case none
        /// A status dot.
        case state(AgentState)
        /// An SF Symbol, tinted by a state (lantern for attention) or secondary.
        case symbol(String, AgentState? = nil)
        /// A state's glyph.
        case glyph(AgentState)
        /// A symbol in the leading column.
        case badge(String)
    }

    /// What trails a row.
    enum Trailing: Equatable, Sendable {
        case none
        /// A plain value in tertiary.
        case value(String)
        /// Why it needs you, in lantern.
        case reason(String)
        /// A problem, in failed.
        case alert(String)
        /// The host it lives on.
        case host(String)
        /// A quiet word.
        case meta(String)
    }

    let title: String
    let subtitle: String?
    let subtitleMono: Bool
    let subtitleTone: AgentState?
    let leading: SettingsRow.Leading
    let trailing: SettingsRow.Trailing
    let chevron: Bool
    let selected: Bool
    let dimmed: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    init(_ title: String, subtitle: String? = nil, subtitleMono: Bool = false, subtitleTone: AgentState? = nil,
         leading: SettingsRow.Leading = .none, trailing: SettingsRow.Trailing = .none, chevron: Bool = true,
         selected: Bool = false, dimmed: Bool = false) {
        self.title = title
        self.subtitle = subtitle
        self.subtitleMono = subtitleMono
        self.subtitleTone = subtitleTone
        self.leading = leading
        self.trailing = trailing
        self.chevron = chevron
        self.selected = selected
        self.dimmed = dimmed
    }

    nonisolated static func == (a: SettingsRow, b: SettingsRow) -> Bool {
        a.title == b.title && a.subtitle == b.subtitle && a.subtitleMono == b.subtitleMono && a.subtitleTone == b.subtitleTone
            && a.leading == b.leading && a.trailing == b.trailing && a.chevron == b.chevron
            && a.selected == b.selected && a.dimmed == b.dimmed
    }

    var body: some View {
        let sh = Color.sh
        HStack(spacing: SH.Space.l) {
            leadingView
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(title)
                    .font(.sh(.ui, weight: selected ? .semibold : .medium))
                    .foregroundStyle(sh.textPrimary)
                    .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                if let subtitle {
                    Text(subtitle)
                        .font(subtitleMono ? .shMono(MobileLayout.settingsNoteCodeSize) : .shSans(MobileLayout.settingsCaptionSize))
                        .foregroundStyle(subtitleTone?.textColor ?? sh.textSecondary)
                        .lineLimit(typeSize.isAccessibilitySize ? SHListMetrics.accessibilityStatusLines : 1)
                }
                if typeSize.isAccessibilitySize { SettingsRowValue(trailing: trailing) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !typeSize.isAccessibilitySize { SettingsRowValue(trailing: trailing) }
            if chevron { SettingsChevron() }
        }
        .padding(.horizontal, MobileLayout.settingsRowInset)
        .padding(.vertical, MobileLayout.settingsRowPadding)
        .frame(maxWidth: .infinity, minHeight: MobileLayout.settingsRowHeight, alignment: .leading)
        .background(selected ? sh.bgSelected : .clear)
        .opacity(dimmed ? SHListMetrics.dimmedOpacity : 1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var leadingView: some View {
        switch leading {
        case .none:
            EmptyView()
        case .state(let state):
            SettingsLeading { SHStatusDot(state, size: SHListMetrics.dot) }
        case .symbol(let name, let tone):
            SettingsLeading {
                Image(systemName: name)
                    .font(.shSans(MobileLayout.settingsGlyphSize, .regular))
                    .foregroundStyle(tone == .attention ? Color.sh.lanternText : tone?.color ?? Color.sh.textSecondary)
            }
        case .glyph(let state):
            SettingsLeading { SHStateGlyph(state) }
        case .badge(let name):
            SettingsLeading {
                Image(systemName: name)
                    .font(.shSans(MobileLayout.settingsGlyphSize, .regular))
                    .foregroundStyle(Color.sh.textPrimary)
            }
        }
    }
}

/// The leading column of a row: 28pt, its glyph centered.
private struct SettingsLeading<Glyph: View>: View {
    @ViewBuilder let glyph: () -> Glyph

    var body: some View {
        glyph()
            .frame(width: MobileLayout.settingsLeadingWidth)
            .accessibilityHidden(true)
    }
}

/// A row's trailing text, by what it says.
struct SettingsRowValue: View {
    let trailing: SettingsRow.Trailing

    var body: some View {
        switch trailing {
        case .none:
            EmptyView()
        case .value(let text), .meta(let text):
            Text(text).font(.shSans(MobileLayout.settingsCaptionSize)).foregroundStyle(Color.sh.textTertiary).lineLimit(1)
        case .reason(let text):
            Text(text).font(.shSans(MobileLayout.settingsCaptionSize, .medium)).foregroundStyle(Color.sh.lanternText).lineLimit(1).fixedSize()
        case .alert(let text):
            Text(text).font(.shSans(MobileLayout.settingsCaptionSize)).foregroundStyle(Color.sh.failed).lineLimit(1).fixedSize()
        case .host(let name):
            SHHostBadge(name)
        }
    }
}

/// A row's chevron, tertiary.
struct SettingsChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.shSans(MobileLayout.settingsChevronSize, .medium))
            .foregroundStyle(Color.sh.textTertiary)
            .accessibilityHidden(true)
    }
}

// MARK: Controls

/// The boards' switch (`gt-sw`): 52×32, ink while on, a 28pt knob. On a native `Toggle`:
/// `.toggleStyle(.settingsSwitch)`; VoiceOver and the keyboard still see a real toggle.
struct SettingsSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        SettingsSwitch(configuration: configuration)
    }
}

extension ToggleStyle where Self == SettingsSwitchStyle {
    static var settingsSwitch: SettingsSwitchStyle { SettingsSwitchStyle() }
}

private struct SettingsSwitch: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let sh = Color.sh
        let on = configuration.isOn
        Button { configuration.isOn.toggle() } label: {
            Capsule()
                .fill(on ? sh.primary : sh.bgSelected)
                .frame(width: MobileLayout.settingsSwitchWidth, height: MobileLayout.settingsSwitchHeight)
                .overlay(alignment: on ? .trailing : .leading) {
                    Circle()
                        .fill(on ? sh.knobOn : sh.knobOff)
                        .shadow(color: sh.knobShadow, radius: SH.Space.xxs, y: SH.Space.xxs / 2)
                        .padding(MobileLayout.settingsSwitchInset)
                }
                .frame(minHeight: SH.Height.touch)
                .contentShape(Rectangle())
                .shComponentAnimation(.content, value: on)
        }
        .buttonStyle(.plain)
        .shEnabledOpacity(enabled)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

/// A pill button (the boards' `gt-btn`): 36pt, filled `bgSelected`; `.dark` is the ink one, `.edge`
/// a hairline only.
struct SettingsPillStyle: ButtonStyle {
    enum Kind { case plain, dark, edge }

    let kind: Kind
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let sh = Color.sh
        configuration.label
            .font(.shSans(MobileLayout.settingsPillTextSize, .medium))
            .foregroundStyle(kind == .dark ? sh.textOnPrimary : sh.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, MobileLayout.settingsPillInset)
            .frame(minHeight: MobileLayout.settingsPillHeight)
            .background(kind == .dark ? AnyShapeStyle(sh.primary) : AnyShapeStyle(kind == .plain ? sh.bgSelected : .clear), in: Capsule())
            .overlay { Capsule().strokeBorder(kind == .edge ? sh.lineSubtle : .clear) }
            .opacity(configuration.isPressed ? 0.7 : 1)
            .shEnabledOpacity(enabled)
            .contentShape(Capsule())
    }
}

extension ButtonStyle where Self == SettingsPillStyle {
    static var settingsPill: SettingsPillStyle { SettingsPillStyle(kind: .plain) }
    static func settingsPill(_ kind: SettingsPillStyle.Kind) -> SettingsPillStyle { SettingsPillStyle(kind: kind) }
}

/// The page's one primary action (the boards' `gt-pri`): a 50pt ink capsule across the width, 15/600.
struct SettingsPrimaryStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let sh = Color.sh
        configuration.label
            .font(.sh(.ui, weight: .semibold))
            .foregroundStyle(enabled ? sh.textOnPrimary : sh.textTertiary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: MobileLayout.settingsPrimaryHeight)
            .background(enabled ? sh.primary : sh.bgSelected, in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Capsule())
    }
}

extension ButtonStyle where Self == SettingsPrimaryStyle {
    static var settingsPrimary: SettingsPrimaryStyle { SettingsPrimaryStyle() }
}

/// A word that acts (the boards' `gt-lk`): "Unmute", "Retry", "Add another command", `Delete hook` in `failed`.
struct SettingsLinkStyle: ButtonStyle {
    enum Tone { case ink, dim, failed }

    let tone: Tone
    /// In a caption's line, where the 44pt touch height would grow the line.
    var compact = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let sh = Color.sh
        configuration.label
            .font(.sh(.ui, weight: tone == .dim ? .regular : .medium))
            .foregroundStyle(tone == .failed ? sh.failed : tone == .dim ? sh.textSecondary : sh.textPrimary)
            .lineLimit(1)
            .frame(minHeight: compact ? nil : SH.Height.touch)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .shEnabledOpacity(enabled)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == SettingsLinkStyle {
    static var settingsLink: SettingsLinkStyle { SettingsLinkStyle(tone: .ink) }
    static func settingsLink(_ tone: SettingsLinkStyle.Tone) -> SettingsLinkStyle { SettingsLinkStyle(tone: tone) }
    static var settingsLinkCompact: SettingsLinkStyle { SettingsLinkStyle(tone: .ink, compact: true) }
}

/// The search field (`gt-search`): a 40pt capsule on `bgSelected`, the glass, the field, a clear button.
struct SettingsSearchCapsule: View {
    let placeholder: String
    @Binding var text: String
    let focus: FocusState<Bool>.Binding

    var body: some View {
        let sh = Color.sh
        HStack(spacing: SH.Space.m) {
            Image(systemName: "magnifyingglass")
                .font(.shSans(MobileLayout.settingsGlyphSize, .regular))
                .foregroundStyle(sh.textTertiary)
                .accessibilityHidden(true)
            TextField(placeholder, text: $text, prompt: Text(placeholder).foregroundStyle(sh.textTertiary))
                .textFieldStyle(.plain)
                .font(.sh(.ui, weight: .regular))
                .foregroundStyle(sh.textPrimary)
                .tint(sh.lantern)
                .focused(focus)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityLabel(placeholder)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.shSans(MobileLayout.settingsGlyphSize, .regular))
                        .foregroundStyle(sh.textTertiary)
                        .contentShape(Rectangle().inset(by: -SH.Space.m))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, MobileLayout.settingsSearchInset)
        .frame(minHeight: MobileLayout.settingsSearchHeight)
        .background(sh.bgSelected, in: Capsule())
    }
}

/// A short list of choices as a pill (`gt-seg`): 36pt on `bgSelected`, the open one raised.
struct SettingsSegments<Value: Hashable>: View {
    let label: String
    @Binding var selection: Value
    let options: [(value: Value, title: String)]

    init(_ label: String, selection: Binding<Value>, options: [(Value, String)]) {
        self.label = label
        _selection = selection
        self.options = options.map { (value: $0.0, title: $0.1) }
    }

    var body: some View {
        let sh = Color.sh
        HStack(spacing: SH.Space.xxs) {
            ForEach(options, id: \.value) { option in
                let on = selection == option.value
                Button { selection = option.value } label: {
                    Text(option.title)
                        .font(.shSans(MobileLayout.settingsCaptionSize, .medium))
                        .foregroundStyle(on ? sh.textPrimary : sh.textSecondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: MobileLayout.settingsSegmentHeight - MobileLayout.settingsSegmentInset * 2)
                        .background(on ? sh.bgRaised : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(MobileLayout.settingsSegmentInset)
        .background(sh.bgSelected, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

// MARK: Titles

/// A page's title on the phone and iPhone Duo (the boards' `gt-h1`): 28pt bold, tracked, in the content
/// under the bar, so it scrolls away with the page; the native bar keeps only its buttons.
struct SettingsHeading: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.sh(.display, weight: .bold))
            .tracking(-SHTextStyle.display.size * MobileLayout.settingsHeadingTracking)
            .foregroundStyle(Color.sh.textPrimary)
            .padding(.horizontal, SH.Space.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A column's bar on the iPad (the boards' `gpad-bar`): the title 18/600 over a 12pt subtitle on the left,
/// the page's actions as glass on the right.
struct PadColumnBar<Actions: View>: View {
    let title: String
    let subtitle: String?
    /// The detail's bar sits further in than the list's.
    var inset = MobileLayout.settingsPadBarInset
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: SH.Space.m + SH.Space.xxs) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.shSans(MobileLayout.settingsPadBarTitleSize, .semibold))
                    .foregroundStyle(Color.sh.textPrimary)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(.shSans(SHTextStyle.caption.size))
                        .foregroundStyle(Color.sh.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: SH.Space.m)
            actions()
        }
        .buttonBorderShape(.capsule)
        .padding(.leading, inset)
        .padding(.trailing, SH.Space.xl)
        .frame(minHeight: MobileLayout.settingsPadBarHeight)
    }
}

extension PadColumnBar where Actions == EmptyView {
    init(_ title: String, subtitle: String? = nil, inset: CGFloat = MobileLayout.settingsPadBarInset) {
        self.init(title: title, subtitle: subtitle, inset: inset) { EmptyView() }
    }
}

/// A bar button on the iPad as glass: a word, or its glyph alone.
struct PadBarButton: View {
    let title: String
    var systemImage: String?
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if let systemImage {
                Label(title, systemImage: systemImage).labelStyle(.iconOnly)
            } else {
                Text(title)
            }
        }
        .buttonStyle(.glass)
        .tint(Color.sh.textPrimary)
        .disabled(disabled)
    }
}

/// The bar's main action on the iPad: ink glass.
struct PadBarPrimary: View {
    let title: String
    var systemImage: String?
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if let systemImage {
                Label(title, systemImage: systemImage).labelStyle(.iconOnly)
            } else {
                Text(title)
            }
        }
        .buttonStyle(.glassProminent)
        .tint(Color.sh.primary)
        .disabled(disabled)
    }
}
