import SwiftUI

// Automations (MobileAutomations, iPadAutomations, NavAutomations boards): a row with its
// switch, the facts of one automation, its prompt, the chart of its latest runs, and a run's
// row. Plain values in; what a switch or a row does is the caller's.

/// The automation surfaces' own measures.
public enum SHAutomationMetrics {
    /// The runs chart's plot (the boards' 96pt).
    public static let chartHeight: CGFloat = 96
    /// Between two bars.
    public static let barSpacing: CGFloat = SH.Space.xs
    /// The widest a bar gets, so a few runs still read as bars.
    public static let barMaxWidth: CGFloat = 32
    /// A bar's top corners.
    public static let barRadius: CGFloat = SH.Radius.xs
    /// A fact's label column (iPadAutomations: "Trigger", "Runs on").
    public static let factLabelWidth: CGFloat = 110
    /// The switch as drawn (`.shSwitch`); touch grows its hit area.
    public static let switchSize = CGSize(width: 30, height: 18)
    /// A live run's card: its ring outside the running line, and its spinner.
    public static let runRing: CGFloat = 3
    public static let runSpinner: CGFloat = 13
    /// How a live run is going ("Running · 4m"): the board's 13pt, between caption and ui.
    public static let runStatusSize: CGFloat = 13
}

/// A run going now, as its own card (MobileAutomations' Running now): a spinner, the
/// automation's name, and its host trailing, then how the run is going ("Running · 4m"). A
/// working run's card takes a `running` line inside a 3pt `runningTint` ring; one that asked
/// you a `lanternText` line, the bolt and "Asked you" in lanternText. A tap opens the automation.
public struct SHAutomationRunCard: View, Equatable {
    let title: String
    let host: String?
    let status: String
    let asking: Bool
    let since: Date?
    let open: (() -> Void)?

    public init(_ title: String, host: String? = nil, status: String, asking: Bool = false, since: Date? = nil,
                open: (() -> Void)? = nil) {
        self.title = title
        self.host = host
        self.status = status
        self.asking = asking
        self.since = since
        self.open = open
    }

    public nonisolated static func == (a: Self, b: Self) -> Bool {
        a.title == b.title && a.host == b.host && a.status == b.status && a.asking == b.asking && a.since == b.since
            && (a.open == nil) == (b.open == nil)
    }

    public var body: some View {
        if let open {
            Button(action: open) { card }.buttonStyle(.plain)
        } else {
            card
        }
    }

    private var card: some View {
        let sh = Color.sh
        let shape = RoundedRectangle(cornerRadius: SHListMetrics.cardRadius)
        return VStack(alignment: .leading, spacing: SH.Space.m) {
            HStack(spacing: SH.Space.m) {
                Group {
                    if asking {
                        Image(systemName: "bolt").font(.sh(.caption, weight: .semibold)).foregroundStyle(sh.lanternText)
                    } else {
                        ProgressView().progressViewStyle(.shSpinner(size: SHAutomationMetrics.runSpinner))
                    }
                }
                .accessibilityHidden(true)
                Text(title).font(.sh(.ui, weight: .semibold)).foregroundStyle(sh.textPrimary).lineLimit(2)
                Spacer(minLength: SH.Space.m)
                if let host {
                    Text(host).font(.sh(.micro, weight: .regular)).foregroundStyle(sh.textTertiary).lineLimit(1)
                }
            }
            statusLine
                .font(.shSans(SHAutomationMetrics.runStatusSize))
                .foregroundStyle(asking ? sh.lanternText : sh.textSecondary)
        }
        .padding(SH.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(sh.bgRaised, in: shape)
        .shBorder(asking ? sh.lanternText : sh.running, radius: SHListMetrics.cardRadius)
        .background {
            if !asking {
                RoundedRectangle(cornerRadius: SHListMetrics.cardRadius + SHAutomationMetrics.runRing)
                    .inset(by: -SHAutomationMetrics.runRing).fill(sh.runningTint)
            }
        }
        .contentShape(shape)
        .accessibilityElement(children: .combine)
        .accessibilityHint(open == nil ? "" : "Opens the automation")
    }

    @ViewBuilder private var statusLine: some View {
        if let since {
            TimelineView(SHElapsedSchedule(start: since)) { context in
                Text(status + " · " + SHDuration.text(context.date.timeIntervalSince(since)))
            }
        } else {
            Text(status)
        }
    }
}

/// One automation in a list: what leads it, its name, when it runs and where, and how its run
/// is going (with a live or "ago" time), then its switch. The row opens the automation (or its
/// run) on a tap; the switch turns it on or off without opening it.
public struct SHAutomationRow: View, Equatable {
    public enum Leading: Equatable, Sendable {
        case none
        /// A spinner: its run is working.
        case running
        /// An SF Symbol, tinted by a state or secondary ("bolt").
        case symbol(String, AgentState? = nil)
    }

    let title: String
    let when: String
    let status: String
    let statusTone: AgentState?
    let clock: SHRowClock?
    let leading: Leading
    /// The switch's value; nil draws no switch.
    let isOn: Bool?
    let switchEnabled: Bool
    let selected: Bool
    let dimmed: Bool
    let chevron: Bool
    let toggle: ((Bool) -> Void)?
    let open: (() -> Void)?
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(_ title: String, when: String, status: String, statusTone: AgentState? = nil, clock: SHRowClock? = nil,
                leading: Leading = .none, isOn: Bool? = nil, switchEnabled: Bool = true, selected: Bool = false,
                dimmed: Bool = false, chevron: Bool = false, toggle: ((Bool) -> Void)? = nil, open: (() -> Void)? = nil) {
        self.title = title
        self.when = when
        self.status = status
        self.statusTone = statusTone
        self.clock = clock
        self.leading = leading
        self.isOn = isOn
        self.switchEnabled = switchEnabled
        self.selected = selected
        self.dimmed = dimmed
        self.chevron = chevron
        self.toggle = toggle
        self.open = open
    }

    public nonisolated static func == (a: SHAutomationRow, b: SHAutomationRow) -> Bool {
        a.title == b.title && a.when == b.when && a.status == b.status && a.statusTone == b.statusTone && a.clock == b.clock
            && a.leading == b.leading && a.isOn == b.isOn && a.switchEnabled == b.switchEnabled && a.selected == b.selected
            && a.dimmed == b.dimmed && a.chevron == b.chevron && (a.open == nil) == (b.open == nil)
    }

    public var body: some View {
        HStack(spacing: SH.Space.m) {
            // Dimming reaches the words, never the switch: an off switch must still read as one.
            if let open {
                Button(action: open) { content.opacity(dimmed ? SHListMetrics.dimmedOpacity : 1) }
                    .buttonStyle(.shRow(radius: 0))
            } else {
                content.opacity(dimmed ? SHListMetrics.dimmedOpacity : 1)
            }
            if let isOn {
                SHAutomationSwitch(title, isOn: isOn, toggle: switchEnabled ? toggle : nil)
                    .padding(.trailing, SH.Space.l)
            }
        }
        // The whole row, switch included, is the selection.
        .background(selected ? Color.sh.bgSelected : .clear)
    }

    private var content: some View {
        let sh = Color.sh
        return HStack(alignment: .firstTextBaseline, spacing: SH.Space.l) {
            leadingView
                .frame(width: SHListMetrics.leadingWidth)
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(title)
                    .font(.sh(.ui, weight: selected ? .semibold : .medium))
                    .foregroundStyle(sh.textPrimary)
                    .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                Text(when)
                    .font(.sh(.mono))
                    .foregroundStyle(sh.textTertiary)
                    .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                statusLine
                    .font(.sh(.caption))
                    .foregroundStyle(statusTone?.textColor ?? sh.textTertiary)
                    .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.sh(.caption, weight: .semibold))
                    .foregroundStyle(sh.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.leading, SH.Space.l)
        .padding(.trailing, isOn == nil ? SH.Space.l : 0)
        .padding(.vertical, SH.Space.m)
        .frame(maxWidth: .infinity, minHeight: SH.Height.touch, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var statusLine: some View {
        switch clock {
        case .none:
            Text(status)
        case .elapsed(let since)?:
            TimelineView(SHElapsedSchedule(start: since, style: .long)) { context in
                Text(status + " · " + SHDuration.text(context.date.timeIntervalSince(since), .long))
            }
        case .ago(let at)?:
            TimelineView(SHElapsedSchedule(start: at)) { context in
                Text(status + " · " + SHDuration.text(context.date.timeIntervalSince(at)) + " ago")
            }
        }
    }

    @ViewBuilder private var leadingView: some View {
        switch leading {
        case .none:
            EmptyView()
        case .running:
            ProgressView().progressViewStyle(.shSpinner(size: SHListMetrics.symbol))
                .accessibilityHidden(true)
        case .symbol(let name, let tone):
            // A glyph that needs you is lanternText; only a status dot glows in lantern.
            Image(systemName: name)
                .font(.sh(.ui, weight: .medium))
                .foregroundStyle(tone == .attention ? Color.sh.lanternText : tone?.color ?? Color.sh.textSecondary)
                .accessibilityHidden(true)
        }
    }
}

/// An automation's on/off switch, with an optional caption beside it. One button covers the
/// drawn switch and the caption, so its whole touch target (44pt on iOS) flips it once;
/// VoiceOver sees a toggle. A nil `toggle` draws it disabled.
public struct SHAutomationSwitch: View {
    let title: String
    let isOn: Bool
    let caption: String?
    let toggle: ((Bool) -> Void)?

    public init(_ title: String, isOn: Bool, caption: String? = nil, toggle: ((Bool) -> Void)?) {
        self.title = title
        self.isOn = isOn
        self.caption = caption
        self.toggle = toggle
    }

    public var body: some View {
        let binding = Binding(get: { isOn }, set: { toggle?($0) })
        Button { toggle?(!isOn) } label: {
            HStack(spacing: SH.Space.m) {
                Toggle(title, isOn: binding)
                    .toggleStyle(.shSwitch)
                    .labelsHidden()
                    .allowsHitTesting(false)
                if let caption {
                    Text(caption)
                        .font(.sh(.caption))
                        .foregroundStyle(Color.sh.textTertiary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .shTouchTarget(height: SHAutomationMetrics.switchSize.height,
                           width: caption == nil ? SHAutomationMetrics.switchSize.width : nil)
        }
        .buttonStyle(.plain)
        .disabled(toggle == nil)
        .accessibilityRepresentation { Toggle(title, isOn: binding) }
        .accessibilityHint("Starts a run when Shepherd starts")
    }
}

/// A fact about an automation: a label, then its value ("Runs on  build-01 · a new thread
/// each run") or a control (its switch), with a hairline under it. At accessibility sizes the
/// value drops under the label.
public struct SHFactRow<Value: View>: View {
    let label: String
    let value: Value
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(_ label: String, @ViewBuilder value: () -> Value) {
        self.label = label
        self.value = value()
    }

    public var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: SH.Space.xxs))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: SH.Space.l))
        VStack(spacing: 0) {
            layout {
                Text(label)
                    .font(.sh(.caption))
                    .foregroundStyle(Color.sh.textSecondary)
                    .frame(width: typeSize.isAccessibilitySize ? nil : SHAutomationMetrics.factLabelWidth, alignment: .leading)
                value
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, SH.Space.m)
            SHHairline()
        }
        .accessibilityElement(children: .contain)
    }
}

extension SHFactRow where Value == SHFactText {
    public init(_ label: String, value: String, mono: Bool = false) {
        self.init(label) { SHFactText(value, mono: mono) }
    }
}

/// A fact's value as text: sans, or mono for a host, a path or a model.
public struct SHFactText: View {
    let text: String
    let mono: Bool

    public init(_ text: String, mono: Bool = false) {
        self.text = text
        self.mono = mono
    }

    public var body: some View {
        Text(text)
            .font(mono ? .sh(.mono) : .sh(.ui, weight: .regular))
            .foregroundStyle(Color.sh.textPrimary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// An automation's prompt: a caption over the text, in a raised card.
public struct SHAutomationPrompt: View {
    let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.s) {
            Text("Prompt")
                .font(.sh(.caption))
                .foregroundStyle(Color.sh.textTertiary)
                .accessibilityAddTraits(.isHeader)
            Text(text)
                .shText(.body)
                .foregroundStyle(Color.sh.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(SH.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .shCard(radius: SH.Radius.l)
    }
}

/// The latest runs as bars (iPadAutomations' "Last 14 runs"): oldest first, each as tall as its
/// run was long and colored by how it went, over the first run's date, what went other than
/// finished, and the last run's date. VoiceOver reads each bar.
public struct SHRunBars: View, Equatable {
    public struct Bar: Identifiable, Equatable, Sendable {
        public var id: String
        /// A share of the plot's height (0...1).
        public var height: Double
        public var state: AgentState
        /// "Sep 24 02:00, finished, 43s".
        public var label: String

        public init(id: String, height: Double, state: AgentState, label: String) {
            self.id = id
            self.height = height
            self.state = state
            self.label = label
        }
    }

    let bars: [Bar]
    let first: String?
    let summary: String?
    let last: String?

    public init(_ bars: [Bar], first: String? = nil, summary: String? = nil, last: String? = nil) {
        self.bars = bars
        self.first = first
        self.summary = summary
        self.last = last
    }

    /// "Last run" for one bar, "Last 14 runs" for more.
    static func title(runs: Int) -> String {
        runs == 1 ? "Last run" : "Last \(runs) runs"
    }

    public var body: some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: SH.Space.s) {
            HStack {
                Text(Self.title(runs: bars.count).uppercased())
                    .font(.sh(.micro, weight: .regular))
                    .foregroundStyle(sh.textTertiary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: SH.Space.s)
                Text("bar height = duration")
                    .font(.sh(.micro, weight: .regular))
                    .foregroundStyle(sh.textTertiary)
                    .accessibilityHidden(true)
            }
            HStack(alignment: .bottom, spacing: SHAutomationMetrics.barSpacing) {
                ForEach(bars) { bar in
                    UnevenRoundedRectangle(topLeadingRadius: SHAutomationMetrics.barRadius,
                                           topTrailingRadius: SHAutomationMetrics.barRadius)
                        .fill(bar.state.color)
                        .frame(maxWidth: SHAutomationMetrics.barMaxWidth)
                        .frame(height: max(SH.Space.xxs, SHAutomationMetrics.chartHeight * min(1, max(0, bar.height))))
                        .accessibilityElement()
                        .accessibilityLabel(bar.label)
                }
            }
            .frame(maxWidth: .infinity, minHeight: SHAutomationMetrics.chartHeight, maxHeight: SHAutomationMetrics.chartHeight,
                   alignment: .bottomLeading)
            .accessibilityElement(children: .contain)
            // The dates and what went other than finished share a line when they fit; otherwise
            // the summary takes its own line under the dates.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: SH.Space.s) {
                    Text(first ?? "").fixedSize()
                    Spacer(minLength: SH.Space.xs)
                    if let summary { Text(summary).fixedSize() }
                    Spacer(minLength: SH.Space.xs)
                    Text(last ?? "").fixedSize()
                }
                VStack(alignment: .leading, spacing: SH.Space.xxs) {
                    HStack(spacing: SH.Space.s) {
                        Text(first ?? "")
                        Spacer(minLength: SH.Space.xs)
                        Text(last ?? "")
                    }
                    if let summary { Text(summary) }
                }
            }
            .font(.sh(.micro, weight: .regular))
            .foregroundStyle(sh.textTertiary)
            .lineLimit(1)
        }
    }
}

/// One run in a history list: its state's dot, when it started, what happened, how long it
/// took, and Open while its thread still exists.
public struct SHRunRow: View, Equatable {
    let started: String
    let word: String
    let state: AgentState
    let duration: String?
    let open: (() -> Void)?
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(started: String, word: String, state: AgentState, duration: String? = nil, open: (() -> Void)? = nil) {
        self.started = started
        self.word = word
        self.state = state
        self.duration = duration
        self.open = open
    }

    public nonisolated static func == (a: SHRunRow, b: SHRunRow) -> Bool {
        a.started == b.started && a.word == b.word && a.state == b.state && a.duration == b.duration
            && (a.open == nil) == (b.open == nil)
    }

    public var body: some View {
        if let open {
            Button(action: open) { content }
                .buttonStyle(.shRow(radius: SH.Radius.s))
                .accessibilityHint("Opens its thread")
        } else {
            content
        }
    }

    private var content: some View {
        let sh = Color.sh
        return HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
            SHStatusDot(state, size: SHListMetrics.dot - 1)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: SH.Space.xxs) {
                    Text(started).font(.sh(.mono)).foregroundStyle(sh.textPrimary)
                    Text(word).font(.sh(.caption)).foregroundStyle(state.textColor)
                }
            } else {
                Text(started).font(.sh(.mono)).foregroundStyle(sh.textPrimary).fixedSize()
                Text(word).font(.sh(.caption)).foregroundStyle(state.textColor).lineLimit(1)
            }
            Spacer(minLength: SH.Space.s)
            if let duration {
                Text(duration).font(.sh(.mono)).foregroundStyle(sh.textTertiary).fixedSize()
            }
            if open != nil {
                Image(systemName: "chevron.right")
                    .font(.sh(.caption, weight: .semibold))
                    .foregroundStyle(sh.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, SH.Space.s)
        .frame(maxWidth: .infinity, minHeight: SHPlatform.showsHoverDetails ? SH.Height.touch : SH.Height.controlM, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
