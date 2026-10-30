import SwiftUI

// A triggered automation's inbox on the Mac (the Automations page's detail and the sidebar):
// a run with what fired it, an event waiting for a free slot, and the sidebar's group of an
// automation's run threads. Plain values in; what a button does is the caller's.

/// One run in an automation's inbox: an unread dot, what fired it ("#12 Fix login crash · issue
/// labeled shepherd", else "Run now"), then how it went with its start and length, why it
/// didn't start, and its pull request. The row opens its thread while the thread exists; the
/// pull request is its own button beside it.
public struct SHAutomationInboxRun: View, Equatable {
    let title: String
    let started: String
    let word: String
    let state: AgentState?
    let duration: String?
    let unread: Bool
    let failure: String?
    let open: (() -> Void)?
    let openPullRequest: (() -> Void)?
    private let opens: Bool
    private let hasPullRequest: Bool

    public init(_ title: String, started: String, word: String, state: AgentState?, duration: String? = nil,
                unread: Bool = false, failure: String? = nil, open: (() -> Void)? = nil, openPullRequest: (() -> Void)? = nil) {
        self.title = title
        self.started = started
        self.word = word
        self.state = state
        self.duration = duration
        self.unread = unread
        self.failure = failure
        self.open = open
        self.openPullRequest = openPullRequest
        opens = open != nil
        hasPullRequest = openPullRequest != nil
    }

    public nonisolated static func == (a: SHAutomationInboxRun, b: SHAutomationInboxRun) -> Bool {
        a.title == b.title && a.started == b.started && a.word == b.word && a.state == b.state && a.duration == b.duration
            && a.unread == b.unread && a.failure == b.failure && a.opens == b.opens && a.hasPullRequest == b.hasPullRequest
    }

    public var body: some View {
        HStack(alignment: .top, spacing: SH.Space.xs) {
            Group {
                if let open {
                    Button(action: open) { content }
                        .buttonStyle(.shRow(radius: SH.Radius.s))
                        .accessibilityHint("Opens its thread")
                } else {
                    content
                }
            }
            .accessibilityLabel(accessibilityText)
            if let openPullRequest {
                Button("PR", systemImage: SHGlyph.gitBranch.symbolName, action: openPullRequest)
                    .buttonStyle(.sh(.ghost, size: .s))
                    .help("Open the pull request")
                    .accessibilityLabel("Open pull request")
                    .padding(.top, SH.Space.xs)
            }
        }
    }

    private var content: some View {
        let sh = Color.sh
        return HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
            // The unread slot keeps every row's title on one edge.
            Circle()
                .fill(unread ? sh.running : Color.clear)
                .frame(width: SHPageMetrics.dot, height: SHPageMetrics.dot)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(title)
                    .font(.sh(.ui, weight: unread ? .semibold : .regular))
                    .foregroundStyle(sh.textPrimary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: SH.Space.s) {
                    if let state {
                        SHStatusDot(state, size: SHPageMetrics.dot)
                    } else {
                        Circle().strokeBorder(sh.textTertiary, lineWidth: 1)
                            .frame(width: SHPageMetrics.dot, height: SHPageMetrics.dot)
                            .accessibilityHidden(true)
                    }
                    Text(word).font(.sh(.caption)).foregroundStyle(state?.textColor ?? sh.textTertiary).lineLimit(1)
                    Text([started, duration].compactMap { $0 }.joined(separator: " · "))
                        .font(.sh(.micro, weight: .regular))
                        .foregroundStyle(sh.textTertiary)
                        .lineLimit(1)
                }
                if let failure {
                    Text(failure)
                        .font(.sh(.caption))
                        .foregroundStyle(AgentState.failed.textColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, SH.Space.s)
        .padding(.trailing, SH.Space.xs)
        .contentShape(Rectangle())
    }

    private var accessibilityText: String {
        [unread ? "unread" : nil, title, word, started, duration, failure].compactMap { $0 }.joined(separator: ", ")
    }
}

/// An event waiting for a free slot (runs at once, or today's runs, are used up): what it is,
/// how long it has waited, and Run now (past the limits) or Dismiss.
public struct SHAutomationPendingEvent: View, Equatable {
    let title: String
    let waited: String
    let enabled: Bool
    let run: () -> Void
    let dismiss: () -> Void

    public init(_ title: String, waited: String, enabled: Bool = true, run: @escaping () -> Void, dismiss: @escaping () -> Void) {
        self.title = title
        self.waited = waited
        self.enabled = enabled
        self.run = run
        self.dismiss = dismiss
    }

    public nonisolated static func == (a: SHAutomationPendingEvent, b: SHAutomationPendingEvent) -> Bool {
        a.title == b.title && a.waited == b.waited && a.enabled == b.enabled
    }

    public var body: some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: SH.Space.s) {
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(title)
                    .font(.sh(.ui, weight: .regular))
                    .foregroundStyle(sh.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(waited)
                    .font(.sh(.micro, weight: .regular))
                    .foregroundStyle(sh.textTertiary)
            }
            .accessibilityElement(children: .combine)
            HStack(spacing: SH.Space.s) {
                Button("Run now", action: run)
                    .buttonStyle(.sh(.secondary, size: .s))
                    .help("Starts it now, past the automation's limits")
                    .accessibilityLabel("Run \(title) now")
                Button("Dismiss", action: dismiss)
                    .buttonStyle(.sh(.ghost, size: .s))
                    .accessibilityLabel("Dismiss \(title)")
            }
            .disabled(!enabled)
        }
        .padding(SH.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Radius.m))
        .shBorder(sh.lineSubtle, radius: SH.Radius.m)
    }
}

/// An automation's run threads in a space of the sidebar's tree, folded into one row: a
/// chevron, the bolt, the automation's name, and how many runs. Like a space row the count
/// rolls up what is inside: a glowing lantern dot while a run asks you, a running dot while one
/// works, and a `running` count badge for runs not opened yet. A tap opens or closes it; the
/// row's menu is the caller's.
public struct SHAutomationGroupRow: View, Equatable {
    public enum Rollup: Equatable, Sendable {
        case quiet
        case running
        case waiting
    }

    let name: String
    let count: Int
    let unread: Int
    let expanded: Bool
    let rollup: Rollup
    let paused: Bool
    let toggle: () -> Void
    @Environment(\.shDensity) private var density
    @State private var hovering = false

    public init(_ name: String, count: Int, unread: Int = 0, expanded: Bool, rollup: Rollup = .quiet, paused: Bool = false,
                toggle: @escaping () -> Void) {
        self.name = name
        self.count = count
        self.unread = unread
        self.expanded = expanded
        self.rollup = rollup
        self.paused = paused
        self.toggle = toggle
    }

    public nonisolated static func == (a: SHAutomationGroupRow, b: SHAutomationGroupRow) -> Bool {
        a.name == b.name && a.count == b.count && a.unread == b.unread && a.expanded == b.expanded && a.rollup == b.rollup
            && a.paused == b.paused
    }

    public var body: some View {
        let _ = SHRenderProbe.tick("sidebar.automationGroup")
        let sh = Color.sh
        HStack(spacing: SHProjectMetrics.gap) {
            Image(systemName: "chevron.right")
                .font(.system(size: SHProjectMetrics.chevron, weight: .semibold))
                .foregroundStyle(sh.textTertiary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .shAnimation(.disclosure, value: expanded)
                .frame(width: SHProjectMetrics.chevronSlot)
            SHGlyph.automation.image
                .font(.system(size: SHProjectMetrics.folder, weight: .regular))
                .foregroundStyle(rollup == .waiting ? sh.lanternText : sh.textSecondary)
                .frame(width: SHSidebarMetrics.rowSlot)
            Text(name)
                .font(density.rowTitleFont(weight: .medium))
                .foregroundStyle(sh.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: SH.Space.xs)
            HStack(spacing: SHProjectMetrics.rollupGap) {
                if paused {
                    Text("paused").font(.sh(.micro, weight: .regular)).foregroundStyle(sh.textTertiary).fixedSize()
                }
                switch rollup {
                case .waiting: SHStatusDot(.attention, size: SHPageMetrics.dot)
                case .running: SHStatusDot(.running, size: SHPageMetrics.dot)
                case .quiet: EmptyView()
                }
                if unread > 0 {
                    Text("\(unread)")
                        .font(.sh(.micro, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(sh.running)
                        .shContentTransition(.numeric())
                } else if count > 0 {
                    Text("\(count)")
                        .font(.sh(.micro, weight: .regular))
                        .monospacedDigit()
                        .foregroundStyle(rollup == .waiting ? sh.lanternText : sh.textTertiary)
                        .shContentTransition(.numeric())
                }
            }
            // The name truncates, never the counts.
            .fixedSize()
        }
        // Nested as a child space is: the caller adds a level's indent.
        .padding(.leading, density.projectRowLeading)
        .padding(.trailing, density.sidebarRowPadding)
        .frame(maxWidth: .infinity, minHeight: density.rowHeight, alignment: .leading)
        .shRowBackground(selected: false, hovering: hovering, radius: SH.Radius.m)
        .contentShape(RoundedRectangle(cornerRadius: SH.Radius.m))
        .onTapGesture(perform: toggle)
        .onHover { hovering = $0 }
        .shAnimation(.hover, value: hovering)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityValue(expanded ? "expanded" : "collapsed")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, toggle)
    }

    private var accessibilityText: String {
        var parts = [name, "automation", count == 1 ? "1 run" : "\(count) runs"]
        if unread > 0 { parts.append("\(unread) unread") }
        if paused { parts.append("paused") }
        switch rollup {
        case .waiting: parts.append("needs you")
        case .running: parts.append("running")
        case .quiet: break
        }
        return parts.joined(separator: ", ")
    }
}

#Preview("Automation inbox") {
    VStack(alignment: .leading, spacing: SH.Space.m) {
        SHAutomationGroupRow("pr-loop", count: 3, unread: 2, expanded: false, rollup: .running) {}
        SHAutomationGroupRow("triage", count: 1, expanded: true, rollup: .waiting, paused: true) {}
        SHAutomationPendingEvent("#14 Crash on launch · issue labeled shepherd", waited: "waiting 12m", run: {}, dismiss: {})
        SHAutomationInboxRun("#12 Fix login crash · issue labeled shepherd", started: "Today 09:12", word: "finished",
                             state: .done, duration: "4m", unread: true, open: {}, openPullRequest: {})
        SHAutomationInboxRun("#9 Flaky test · PR comment", started: "Yesterday 17:40", word: "didn't start", state: .failed,
                             failure: "The folder isn't a git repository.")
    }
    .padding()
    .frame(width: 360)
    .background(Color.sh.bgWindow)
}
