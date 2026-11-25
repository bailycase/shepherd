import SwiftUI
import ShepherdUI
import ShepherdRemote

// The automations list's rows (MobileAutomations, iPadAutomations): a run going now, and one of all of
// them with its switch. Plain values in; what a switch or a row does is the caller's.

/// The words under an automation's name: when it runs, and where.
enum AutomationLines {
    static func when(_ row: AutomationListRow) -> String {
        ((row.unread > 0 ? ["\(row.unread) unread"] : []) + [row.when, row.hostTag ?? row.place]).joined(separator: " · ")
    }
}

/// An automation's status and how long: counting up while it runs, or how long ago it moved.
struct AutomationStatusText: View {
    let status: String
    let clock: AutomationListRow.Clock?
    /// Beside the name ("Running, 4m") rather than under it ("Passed · 12h ago").
    var inline = false

    var body: some View {
        switch clock {
        case .none:
            Text(status)
        case .elapsed(let since)?:
            TimelineView(SHElapsedSchedule(start: since)) { context in
                Text(status + (inline ? ", " : " · ") + SHDuration.text(context.date.timeIntervalSince(since)))
            }
        case .ago(let at)?:
            TimelineView(SHElapsedSchedule(start: at)) { context in
                Text(status + " · " + SHDuration.text(context.date.timeIntervalSince(at)) + " ago")
            }
        }
    }
}

/// A run going now, one row of Running now's card (MobileAutomations): the name over when and where, how the
/// run is going trailing (in lantern while it asks you), and a chevron. A tap opens the automation.
struct AutomationLiveRow: View, Equatable {
    let row: AutomationListRow
    let selected: Bool
    let chevron: Bool
    let open: () -> Void

    static func == (a: Self, b: Self) -> Bool { a.row == b.row && a.selected == b.selected && a.chevron == b.chevron }

    var body: some View {
        let _ = SHRenderProbe.tick("ios.automation.runRow")
        let sh = Color.sh
        let asking = row.tone == .attention
        Button(action: open) {
            HStack(spacing: SH.Space.l) {
                VStack(alignment: .leading, spacing: SH.Space.xxs) {
                    Text(row.name).font(.sh(.ui, weight: selected ? .semibold : .medium)).foregroundStyle(sh.textPrimary).lineLimit(1)
                    Text(AutomationLines.when(row))
                        .font(.shSans(MobileLayout.settingsCaptionSize)).foregroundStyle(sh.textSecondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                AutomationStatusText(status: row.status, clock: row.clock, inline: true)
                    .font(.shSans(MobileLayout.settingsCaptionSize, asking ? .medium : .regular))
                    .foregroundStyle(asking ? sh.lanternText : sh.textTertiary)
                    .shShimmer(active: !asking)
                    .lineLimit(1)
                    .fixedSize()
                if chevron { SettingsChevron() }
            }
            .padding(.horizontal, MobileLayout.settingsRowInset)
            .padding(.vertical, MobileLayout.settingsRowPadding)
            .frame(maxWidth: .infinity, minHeight: MobileLayout.settingsRowHeight, alignment: .leading)
            .background(selected ? sh.bgSelected : .clear)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
        .buttonStyle(.shRow(radius: 0))
    }
}

/// One automation of All (MobileAutomations): its name over when and where, and its last run; its switch flips it
/// without opening it. Off or offline, the words dim, never the switch.
struct AutomationAllRow: View, Equatable {
    let row: AutomationListRow
    let isOn: Bool
    let busy: Bool
    let selected: Bool
    let toggle: (Bool) -> Void
    let open: () -> Void

    static func == (a: Self, b: Self) -> Bool {
        a.row == b.row && a.isOn == b.isOn && a.busy == b.busy && a.selected == b.selected
    }

    /// How its last run went: a failure in `failed`, one that asked you in lantern, the rest quiet.
    @MainActor static func statusColor(_ tone: AutomationTone) -> Color {
        switch tone {
        case .failed: AgentState.failed.textColor
        case .attention: Color.sh.lanternText
        case .running, .done, .stopped, .off: Color.sh.textTertiary
        }
    }

    var body: some View {
        let _ = SHRenderProbe.tick("ios.automation.row")
        let sh = Color.sh
        HStack(spacing: SH.Space.l) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: SH.Space.xxs) {
                    Text(row.name).font(.sh(.ui, weight: selected ? .semibold : .medium)).foregroundStyle(sh.textPrimary)
                    Text(AutomationLines.when(row))
                        .font(.shSans(MobileLayout.settingsCaptionSize)).foregroundStyle(sh.textSecondary)
                    AutomationStatusText(status: row.status, clock: row.clock)
                        .font(.shSans(MobileLayout.settingsCaptionSize))
                        .foregroundStyle(Self.statusColor(row.tone))
                        .shShimmer(active: row.tone == .running)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(row.offline || !isOn ? SHListMetrics.dimmedOpacity : 1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if row.abilities.toggle {
                Toggle(row.name, isOn: Binding(get: { isOn }, set: toggle))
                    .toggleStyle(.settingsSwitch)
                    .labelsHidden()
                    .disabled(busy)
            }
        }
        .padding(.horizontal, MobileLayout.settingsRowInset)
        .padding(.vertical, MobileLayout.settingsRowPadding)
        .frame(maxWidth: .infinity, minHeight: MobileLayout.settingsRowHeight, alignment: .leading)
        .background(selected ? sh.bgSelected : .clear)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: The detail's parts

/// A fact about an automation (iPadAutomations' "Status", "Runs on"): its label in a column, then the value
/// (text, or a control). At accessibility sizes the value drops under the label.
struct AutomationFactRow<Value: View>: View {
    let label: String
    let value: Value
    @Environment(\.dynamicTypeSize) private var typeSize

    init(_ label: String, @ViewBuilder value: () -> Value) {
        self.label = label
        self.value = value()
    }

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: SH.Space.xxs))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: SH.Space.l))
        layout {
            Text(label)
                .font(.shSans(MobileLayout.automationFactSize))
                .foregroundStyle(Color.sh.textSecondary)
                .frame(width: typeSize.isAccessibilitySize ? nil : MobileLayout.automationFactLabelWidth, alignment: .leading)
            value
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, SH.Space.xs)
        .padding(.horizontal, SH.Space.xs)
        .accessibilityElement(children: .contain)
    }
}

extension AutomationFactRow where Value == AutomationFactText {
    init(_ label: String, value: String, mono: Bool = false) {
        self.init(label) { AutomationFactText(value, mono: mono) }
    }
}

/// A fact's value: sans, or mono for a host, a path or a model.
struct AutomationFactText: View {
    let text: String
    let mono: Bool

    init(_ text: String, mono: Bool = false) {
        self.text = text
        self.mono = mono
    }

    var body: some View {
        Text(text)
            .font(mono ? .shMono(MobileLayout.settingsNoteSize + 1) : .shSans(MobileLayout.automationFactSize))
            .foregroundStyle(Color.sh.textPrimary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// An automation's on or off (iPadAutomations' On card): the word over what it does, and the switch. A nil `toggle`
/// draws it disabled.
struct AutomationOnCard: View {
    let title: String
    let isOn: Bool
    let caption: String
    let toggle: ((Bool) -> Void)?

    var body: some View {
        let binding = Binding(get: { isOn }, set: { toggle?($0) })
        SettingsCard {
            HStack(spacing: SH.Space.l) {
                VStack(alignment: .leading, spacing: SH.Space.xxs) {
                    Text(title).font(.sh(.ui)).foregroundStyle(Color.sh.textPrimary)
                    Text(caption).font(.shSans(MobileLayout.settingsCaptionSize)).foregroundStyle(Color.sh.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(true)
                Toggle(title, isOn: binding)
                    .toggleStyle(.settingsSwitch)
                    .labelsHidden()
                    .disabled(toggle == nil)
            }
            .padding(.horizontal, MobileLayout.settingsRowInset)
            .padding(.vertical, MobileLayout.settingsRowPadding)
            .frame(maxWidth: .infinity, minHeight: MobileLayout.settingsRowHeight, alignment: .leading)
        }
    }
}

/// An automation's prompt: a caption over the text, in a card.
struct AutomationPromptCard: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        VStack(alignment: .leading, spacing: MobileLayout.headerSpacing) {
            SettingsCaption("Prompt")
            Text(text)
                .font(.sh(.ui, weight: .regular))
                .foregroundStyle(Color.sh.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, MobileLayout.settingsRowInset)
                .padding(.vertical, SH.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
                .shCard(radius: MobileLayout.settingsCardRadius, lift: true)
        }
    }
}

/// A run's row (a finished one in Runs): when it started over how it ended, its state trailing, a chevron
/// while its thread still exists.
struct AutomationRunLine: View {
    let run: AutomationRunRow
    let open: (() -> Void)?

    var body: some View {
        let sh = Color.sh
        let row = HStack(spacing: SH.Space.l) {
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(run.started).font(.sh(.ui)).foregroundStyle(sh.textPrimary).lineLimit(1)
                if let failure = run.failure {
                    Text(failure).font(.shSans(MobileLayout.settingsCaptionSize)).foregroundStyle(sh.failed).lineLimit(2)
                } else if let duration = run.duration {
                    Text(duration).font(.shSans(MobileLayout.settingsCaptionSize)).foregroundStyle(sh.textSecondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(run.word.prefix(1).uppercased() + run.word.dropFirst())
                .font(.shSans(MobileLayout.settingsCaptionSize))
                .foregroundStyle(run.tone == .failed ? sh.failed : run.tone == .attention ? sh.lanternText : sh.textTertiary)
                .lineLimit(1)
            if open != nil { SettingsChevron() }
        }
        .padding(.horizontal, MobileLayout.settingsRowInset)
        .padding(.vertical, MobileLayout.settingsRowPadding)
        .frame(maxWidth: .infinity, minHeight: MobileLayout.settingsRowHeight, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        if let open {
            Button(action: open) { row }.buttonStyle(.shRow(radius: 0)).accessibilityHint("Opens its thread")
        } else {
            row
        }
    }
}

/// The detail's actions (iPadAutomations' footer): one pill across the page, its words apart by hairlines, the
/// last one the page's main action in 600.
struct AutomationActionBar<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 0) {
            Group(subviews: content()) { subviews in
                ForEach(subviews) { subview in
                    if subview.id != subviews.first?.id { SHHairline(.vertical).frame(height: MobileLayout.automationActionDivider) }
                    subview.frame(maxWidth: .infinity)
                }
            }
        }
        .buttonStyle(AutomationActionStyle())
        .frame(minHeight: MobileLayout.automationActionHeight)
        .shLift(Capsule())
        .overlay { Capsule().strokeBorder(Color.sh.lineSubtle) }
    }
}

/// One word of the action bar: 15/500, ink.
struct AutomationActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.sh(.ui))
            .foregroundStyle(Color.sh.textPrimary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: MobileLayout.automationActionHeight)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .shEnabledOpacity(enabled)
            .contentShape(Capsule())
    }
}
