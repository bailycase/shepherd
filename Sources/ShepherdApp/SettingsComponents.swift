import SwiftUI
import AppKit
import ShepherdUI

// MARK: Page chrome

/// A settings page: the title (`title` style), then its groups 16pt apart. No explanation line.
struct SettingsPage<Content: View, Accessory: View>: View {
    let title: String
    /// A caption beside the title ("Synced 2 min ago", a space's path).
    var subtitle: String?
    /// Trailing the header, bottom-aligned (Models' Re-import from your pi).
    let accessory: Accessory
    let content: Content

    init(title: String, subtitle: String? = nil, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppLayout.settingsGroupSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: SH.Space.xl) {
                SettingsHeader(title: title, subtitle: subtitle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                accessory.fixedSize()
            }
            .padding(.bottom, SH.Space.xs)
            content
        }
        .shControlScale(.settings)
    }
}

extension SettingsPage where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, accessory: { EmptyView() }, content: content)
    }
}

/// A page's title, in `title` style (15/600), and the line under it that says what it is for
/// where a page still has one (a space's resources).
struct SettingsHeader: View {
    let title: String
    var subtitle: String?
    var explanation: String?
    var titleSize = SHTextStyle.title.size
    var explanationSize = SHTextStyle.body.size

    var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
                Text(title)
                    .font(.shSans(titleSize, .semibold))
                    .foregroundStyle(Color.sh.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary).lineLimit(1)
                }
            }
            if let explanation {
                SHMarkupText(explanation, size: explanationSize, codeSize: SHTextStyle.code.size,
                               lineHeight: AppLayout.settingsExplanationLineHeight)
                    .foregroundStyle(Color.sh.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A titled group: the label (`caption` 600, sentence case) with an optional link at its right, a
/// flat group card of rows (rules inserted between them), and an optional footnote under it.
struct SettingsGroup<Content: View>: View {
    let title: String
    var footnote: String?
    /// Trailing the label in mono `caption` `textTertiary` (Custom providers' file).
    var trailing: String?
    /// Plain links at the label's right ("Add space", "Import…"), in order.
    var links: [SettingsLink] = []
    /// Build only the rows near the screen: a list that can run to hundreds of rows.
    var lazy = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.s) {
            if !title.isEmpty || !links.isEmpty || trailing != nil {
            HStack(alignment: .firstTextBaseline) {
                if links.isEmpty {
                    SHSectionHeader(title, style: .settings)
                } else {
                    SHSectionHeader(title, style: .settings) {
                        HStack(spacing: SH.Space.l) {
                            ForEach(links) { link in
                                if link.menu.isEmpty {
                                    SHSectionLink(title: link.title, action: link.action).disabled(!link.isEnabled).accessibilityLabel(link.label ?? link.title).help(link.help ?? "")
                                } else {
                                    Menu {
                                        ForEach(link.menu) { item in Button(item.title, action: item.action) }
                                    } label: {
                                        Text(link.title).font(.sh(.caption)).foregroundStyle(Color.sh.running)
                                    }
                                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                                }
                            }
                        }
                    }
                }
                if let trailing, links.isEmpty {
                    Spacer(minLength: SH.Space.l)
                    Text(trailing).font(.shMono(SHTextStyle.caption.size)).foregroundStyle(Color.sh.textTertiary).lineLimit(1).truncationMode(.middle)
                        .help(trailing)
                }
            }
            .padding(.horizontal, SH.Space.xs)
            }
            SHGroupCard(radius: SHCardRowMetrics.settingsCardRadius, lazy: lazy) { content }
            if let footnote {
                SettingsNote(text: footnote).padding(.horizontal, SH.Space.xs)
            }
        }
        .shControlScale(.settings)
    }
}

/// A link at a group label's right.
struct SettingsLink: Identifiable {
    let title: String
    let action: () -> Void
    /// Items of a menu the link opens instead of acting (Import…).
    var menu: [SettingsLink] = []
    /// What VoiceOver says when the link needs more than its words ("Add app to payments-api").
    var label: String?
    var isEnabled = true
    /// A tooltip: why the link is off, or what it does.
    var help: String?
    var id: String { title }
    init(_ title: String, label: String? = nil, enabled: Bool = true, help: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.label = label
        self.help = help
        self.isEnabled = enabled
        self.action = action
    }
    init(_ title: String, menu: [SettingsLink]) {
        self.title = title
        self.action = {}
        self.menu = menu
    }
}

/// One row: title, optional description (inline markup: `` `code` `` and `**option**`) and
/// inline problem, control trailing. `problemHelp` is the problem's tooltip: the technical
/// reason, never the message.
struct SettingsRow<Control: View>: View {
    let title: String
    var subtitle: String?
    var problem: String?
    var problemHelp: String?
    /// A status dot before the title.
    var dot: SHRowDot?
    /// The title in mono (a server, a provider id).
    var mono = false
    var indented = false
    @ViewBuilder var control: Control

    var body: some View {
        SHCardRow(title, description: subtitle, problem: problem, problemHelp: problemHelp, style: .settings,
                  dot: dot, monoTitle: mono, indented: indented) { control }
            .accessibilityElement(children: .contain)
    }
}

/// A row with no title: its own content leading, actions trailing (a form's Save, pi's update
/// buttons). Same padding and minimum height as `SettingsRow`.
struct SettingsActionRow<Leading: View, Actions: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: SH.Space.xxl) {
            leading
            Spacer(minLength: 0)
            HStack(spacing: SH.Space.s) { actions }
        }
        .modifier(SHCardRowFrame(settings: true))
    }
}

extension SettingsActionRow where Leading == EmptyView {
    init(@ViewBuilder actions: () -> Actions) {
        self.init(leading: { EmptyView() }, actions: actions)
    }
}

/// Footnote under a group: `caption` in `textTertiary`, a sentence or two about the whole
/// group, never a mono paragraph.
struct SettingsNote: View {
    let text: String

    var body: some View {
        Text(text)
            .shText(size: SHTextStyle.caption.size, lineHeight: AppLayout.settingsFootnoteLineHeight)
            .foregroundStyle(Color.sh.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The lantern switch every boolean setting uses. The row title is its accessibility label.
struct SettingsSwitch: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(label, isOn: $isOn).labelsHidden().toggleStyle(.shSwitch)
    }
}

/// A labelled text field in a settings row: the label is for VoiceOver, the prompt is the
/// example shown while empty.
struct SettingsTextField: View {
    let label: String
    let prompt: String
    @Binding var text: String
    var mono = false
    var secure = false
    var width: CGFloat = AppLayout.settingsFieldWidth
    /// The field's own value refused: its line turns `failed` and this says why under it.
    var error: String? = nil

    var body: some View {
        Group {
            if secure {
                SecureField(label, text: $text, prompt: Text(prompt).foregroundStyle(Color.sh.textTertiary))
            } else {
                TextField(label, text: $text, prompt: Text(prompt).foregroundStyle(Color.sh.textTertiary))
            }
        }
        .textFieldStyle(.sh(mono: mono, error: error != nil))
        .frame(width: width)
        .shFieldMessage(error, alignment: .trailing)
    }
}

/// A file Shepherd owns: its name in mono (the full path on hover) and a Reveal button.
struct PathRow: View {
    let title: String
    let subtitle: String
    let url: URL

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle) {
            HStack(spacing: SH.Space.m) {
                Text(url.lastPathComponent)
                    .font(.sh(.mono))
                    .foregroundStyle(Color.sh.textSecondary)
                    .help(url.path)
                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(.sh(.secondary, size: .s))
                    .accessibilityLabel("Reveal \(url.lastPathComponent) in Finder")
            }
        }
    }
}

/// A read-only value in a row's control spot: `caption` in `textSecondary`, tinted by `tone`.
struct SettingsValue: View {
    enum Tone { case plain, good, bad, note }
    let text: String
    var tone: Tone = .plain
    var mono = false

    var body: some View {
        Text(text)
            .font(mono ? .sh(.mono) : .sh(.caption))
            .foregroundStyle(color)
            .lineLimit(1).truncationMode(.middle)
    }

    private var color: Color {
        switch tone {
        case .plain: Color.sh.textSecondary
        case .good: Color.sh.done
        case .bad: Color.sh.failed
        case .note: Color.sh.lanternText
        }
    }
}

/// A row that opens a sub-page or a detail: title and hint, an optional value, then a chevron.
/// The whole row is the button.
struct SettingsDrillRow<Extra: View>: View {
    let title: String
    var subtitle: String?
    var value: String?
    var valueTone: SettingsValue.Tone = .plain
    var dot: SHRowDot?
    var mono = false
    var indented = false
    /// What VoiceOver calls the row when the title alone is not enough ("Open payments-api").
    var accessibilityName: String?
    let action: () -> Void
    /// Controls between the value and the chevron (a switch on a skill's row).
    @ViewBuilder var extra: Extra

    var body: some View {
        // The row opens its page on a click anywhere but its own controls (a switch), so it is a
        // tap target with a button's accessibility, not a Button around a Button.
        SHCardRow(title, description: subtitle, style: .settings, dot: dot, monoTitle: mono, indented: indented) {
            HStack(spacing: SH.Space.m) {
                if let value { SettingsValue(text: value, tone: valueTone) }
                extra
                Image(systemName: "chevron.right")
                    .font(.sh(.caption))
                    .foregroundStyle(Color.sh.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(accessibilityName ?? title)
        .accessibilityAction(.default, action)
    }
}

extension SettingsDrillRow where Extra == EmptyView {
    init(title: String, subtitle: String? = nil, value: String? = nil, dot: SHRowDot? = nil, mono: Bool = false,
         indented: Bool = false, accessibilityName: String? = nil, action: @escaping () -> Void) {
        self.init(title: title, subtitle: subtitle, value: value, dot: dot, mono: mono, indented: indented,
                  accessibilityName: accessibilityName, action: action, extra: { EmptyView() })
    }
}

/// A filter row inside a card: a segmented filter, a note, and an optional button.
struct SettingsFilterRow<Value: Hashable>: View {
    let label: String
    @Binding var selection: Value
    let options: [(Value, String)]
    var note: String?
    var buttonTitle: String?
    var button: () -> Void = {}

    var body: some View {
        HStack(spacing: SH.Space.m) {
            SHSegmentedPicker(label, selection: $selection, options: options)
            if let note {
                Text(note).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let buttonTitle {
                Button(buttonTitle, action: button).buttonStyle(.sh(.secondary, size: .s))
            }
        }
        .padding(.horizontal, SH.Space.l)
        .padding(.vertical, SH.Space.s)
        .frame(minHeight: SH.Height.scaled(SHCardRowMetrics.settingsMinHeight))
    }
}

/// The first row of a list card: a filter field at the left, an optional count or note at the right.
struct SettingsSearchRow: View {
    let prompt: String
    @Binding var text: String
    var note: String?

    var body: some View {
        HStack(spacing: SH.Space.m) {
            SHSearchField(prompt, text: $text).frame(width: AppLayout.settingsFilterWidth)
            Spacer(minLength: 0)
            if let note {
                Text(note).font(.sh(.caption)).foregroundStyle(Color.sh.textSecondary).lineLimit(1)
            }
        }
        .padding(.horizontal, SH.Space.l)
        .padding(.vertical, SH.Space.s)
        .frame(minHeight: SH.Height.scaled(SHCardRowMetrics.settingsMinHeight))
    }
}

/// The editor card the Settings boards draw: a header row (the file's name in mono, "● edited", the
/// Open in slot, then its actions), a rule, and the editor under it. It takes the height of the
/// window's remaining space, never less than `AppLayout.settingsEditorHeight`.
struct SettingsEditorCard<Actions: View, Content: View>: View {
    let name: String
    var edited = false
    /// The draft the Open in ▾ button hands to another app (`name` is its file's name).
    var openIn: Binding<String>?
    /// A fixed height instead of filling the window (a card among other groups).
    var fixedHeight: CGFloat?
    @ViewBuilder var actions: Actions
    @ViewBuilder var content: Content

    var body: some View {
        card
    }

    @ViewBuilder private var card: some View {
        if let fixedHeight {
            base.frame(height: fixedHeight)
        } else {
            base.containerRelativeFrame(.vertical, alignment: .top) { height, _ in
                max(AppLayout.settingsEditorHeight, height - AppLayout.settingsEditorChrome)
            }
        }
    }

    private var base: some View {
        VStack(spacing: 0) {
            HStack(spacing: SH.Space.s) {
                Text(name)
                    .font(.sh(.mono, weight: .medium))
                    .foregroundStyle(Color.sh.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
                if edited {
                    Text("● edited").font(.sh(.caption)).foregroundStyle(Color.sh.lanternText).lineLimit(1).fixedSize()
                        .shTransition(.disclosure)
                }
                Spacer(minLength: SH.Space.m)
                if let openIn { SettingsOpenIn(text: openIn, name: (name as NSString).lastPathComponent).id(name) }
                actions
            }
            .padding(.vertical, SH.Space.s)
            .padding(.horizontal, SH.Space.l)
            .frame(minHeight: SH.Height.scaled(SHCardRowMetrics.settingsMinHeight))
            SHHairline()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity)
        .shCard(radius: SHCardRowMetrics.settingsCardRadius)
        .shAnimation(.hover, value: edited)
    }
}

/// A sheet field's label: `caption` 600 in `textSecondary`, with the Open in slot at its right for a
/// multi-line input.
struct SettingsSheetLabel: View {
    let title: String
    /// A multi-line input's draft, for the Open in ▾ button at the label's right, and the file name it opens as.
    var openIn: Binding<String>?
    var file = "draft.txt"
    /// What the draft belongs to (a space, say): a new value ends the old watch, so a late save there can't reach this input.
    var scope: AnyHashable = 0

    var body: some View {
        HStack(spacing: SH.Space.s) {
            Text(title).font(.sh(.caption, weight: .semibold)).foregroundStyle(Color.sh.textSecondary)
            Spacer(minLength: 0)
            if let openIn { SettingsOpenIn(text: openIn, name: file).id(scope) }
        }
        .accessibilityAddTraits(.isHeader)
    }
}
