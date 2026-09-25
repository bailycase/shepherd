import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// The thread toolbar (Navigation board, `NWThreadToolbar`) for the agent on screen: title ·
/// spacer · "n turns · 42k ctx" · the subagents and review toggles (lantern while their pane is
/// open) · options. Observes the thread store; everything else comes in as values, compared by
/// value (closures by presence), so the workspace header rerunning for a status report or a
/// selection elsewhere leaves it alone (`.equatable()`).
struct ThreadHeader: View, Equatable {
    static func == (a: ThreadHeader, b: ThreadHeader) -> Bool {
        a.store === b.store && a.project == b.project && a.title == b.title && a.leadingInset == b.leadingInset
            && (a.showSidebar == nil) == (b.showSidebar == nil) && a.reviewOpen == b.reviewOpen && a.inspectorOpen == b.inspectorOpen
            && a.reviewShortcut == b.reviewShortcut && a.inspectShortcut == b.inspectShortcut
            && (a.toggleReview == nil) == (b.toggleReview == nil) && (a.toggleSubagents == nil) == (b.toggleSubagents == nil)
            && (a.rename == nil) == (b.rename == nil)
            && a.terminalOpen == b.terminalOpen && a.terminalNews == b.terminalNews && a.terminalShortcut == b.terminalShortcut
            && (a.toggleTerminal == nil) == (b.toggleTerminal == nil)
    }

    var store: NativeThreadStore
    let project: String
    let title: String
    var leadingInset: CGFloat = 0
    var showSidebar: (() -> Void)?
    var reviewOpen = false
    var inspectorOpen = false
    var reviewShortcut: String?
    var inspectShortcut: String?
    var toggleReview: (() -> Void)?
    var toggleSubagents: (() -> Void)?
    var rename: (() -> Void)?
    /// The terminal panel under the thread: open, and whether a hidden tab printed.
    var terminalOpen = false
    var terminalNews = false
    var terminalShortcut: String?
    var toggleTerminal: (() -> Void)?

    var body: some View {
        let _ = NWRenderProbe.tick("thread.header")
        let toggles = toggles
        // The counters are read in their own view: a poll that moves only them (the context
        // count) redraws the toolbar, not this.
        ThreadCountersReader(store: store) { counters, help in
            NWThreadToolbar(title, titleHelp: "\(project) / \(title)", counters: counters, countersHelp: help,
                            leadingInset: leadingInset, sidebar: showSidebar, toggles: toggles) {
                NWOptionsMenu("Thread options") {
                    Button("Refresh Thread") { Task { await store.refresh(fresh: true) } }
                    if store.olderCursor != nil {
                        Button("Load Older Messages") { Task { await store.loadOlder() } }
                    }
                    if let rename {
                        Divider()
                        Button("Rename…", action: rename)
                    }
                }
            }
        }
    }

    private var toggles: [(NWPaneToggle, () -> Void)] {
        var toggles: [(NWPaneToggle, () -> Void)] = []
        if let toggleTerminal {
            toggles.append((NWPaneToggle(systemImage: "terminal", label: terminalOpen ? "Hide terminal" : "Show terminal",
                                         shortcut: terminalShortcut, isOn: terminalOpen, badge: terminalNews && !terminalOpen), toggleTerminal))
        }
        if let toggleSubagents, store.hasSubagents {
            toggles.append((NWPaneToggle(systemImage: "arrow.triangle.branch", label: inspectorOpen ? "Close subagent" : "Inspect subagents",
                                         shortcut: inspectShortcut, isOn: inspectorOpen), toggleSubagents))
        }
        if let toggleReview {
            toggles.append((NWPaneToggle(systemImage: "plus.forwardslash.minus", label: reviewOpen ? "Close review" : "Review changes",
                                         shortcut: reviewShortcut, isOn: reviewOpen), toggleReview))
        }
        return toggles
    }
}

/// "18 turns · 46k ctx" plus the subagent rollup; the turn count shows once the whole history
/// is loaded.
enum ThreadCounters {
    @MainActor static func text(_ store: NativeThreadStore) -> String? {
        let parts = [
            store.olderCursor == nil && store.session != nil ? turns(store) : nil,
            store.stats?.contextTokens.map { "\(nativeTokenCount($0)) ctx" },
            nativeSubagentRollup(store.subagents),
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @MainActor private static func turns(_ store: NativeThreadStore) -> String {
        let turns = store.userTurnCount
        return "\(turns) turn\(turns == 1 ? "" : "s")"
    }
}

/// Reads the toolbar's counters and their tooltip for `content`, in a view of its own.
private struct ThreadCountersReader<Content: View>: View {
    var store: NativeThreadStore
    @ViewBuilder let content: (_ counters: String?, _ help: String) -> Content

    var body: some View {
        let _ = NWRenderProbe.tick("thread.counters")
        content(ThreadCounters.text(store), nativeContextTooltip(store.stats))
    }
}

/// The toolbar when no thread is on screen (the space, or Shepherd) or over a remote utility
/// terminal: the same 44pt strip with the title only.
struct PlainHeader: View {
    let title: String
    var leadingInset: CGFloat = 0
    var showSidebar: (() -> Void)?

    var body: some View {
        NWThreadToolbar(title, leadingInset: leadingInset, sidebar: showSidebar)
    }
}
