import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// The thread toolbar (Navigation board, `NWThreadToolbar`) for the agent on screen: title ·
/// status pill · spacer · "n turns · 42k ctx" · the subagents and review toggles (lantern while
/// their pane is open) · options. Observes the thread store; everything else comes in as values.
struct ThreadHeader: View {
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

    var body: some View {
        NWThreadToolbar(title, titleHelp: "\(project) / \(title)", counters: ThreadCounters.text(store),
                        countersHelp: nativeContextTooltip(store.snapshot?.stats), leadingInset: leadingInset,
                        sidebar: showSidebar, toggles: toggles) {
            ThreadStatusPill(store: store)
        } options: {
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

    private var toggles: [(NWPaneToggle, () -> Void)] {
        var toggles: [(NWPaneToggle, () -> Void)] = []
        if let toggleSubagents, !store.subagents.isEmpty {
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

/// Idle / Running · elapsed / Needs you / Error (a lost connection, drawn as `failed`), from the
/// thread snapshot. A subagent waiting on the user outranks the parent's own state.
struct ThreadStatusPill: View {
    var store: NativeThreadStore

    var body: some View {
        let state = threadPillState(store)
        if state == .running {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                NWStatusPill(.running, label: "Running · \(threadRunElapsed(store, now: context.date))")
            }
        } else {
            NWStatusPill(state, label: label(state))
        }
    }

    private func label(_ state: AgentState) -> String? {
        switch state {
        case .attention: nativeSubagentNeedsYouLabel(store.subagents) ?? AgentState.attention.label
        case .failed: "Error"
        default: nil
        }
    }
}

/// "18 turns · 46k ctx" plus the subagent rollup; the turn count shows once the whole history
/// is loaded.
enum ThreadCounters {
    @MainActor static func text(_ store: NativeThreadStore) -> String? {
        let parts = [
            store.olderCursor == nil && store.snapshot != nil ? turns(store) : nil,
            store.snapshot?.stats?.contextTokens.map { "\(nativeTokenCount($0)) ctx" },
            nativeSubagentRollup(store.subagents),
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @MainActor private static func turns(_ store: NativeThreadStore) -> String {
        let turns = store.turns.count(where: \.isUser)
        return "\(turns) turn\(turns == 1 ? "" : "s")"
    }
}

@MainActor
func threadPillState(_ store: NativeThreadStore) -> AgentState {
    if store.loadError != nil { return .failed }
    if store.snapshot?.dialogs.isEmpty == false || nativeSubagentNeedsYouLabel(store.subagents) != nil { return .attention }
    if store.settledRunning { return .running }
    return .idle
}

/// Time since the turn began: the last user message's timestamp while running.
@MainActor
func threadRunElapsed(_ store: NativeThreadStore, now: Date) -> String {
    let start = store.lastPromptAt.map { Date(timeIntervalSince1970: $0 / 1000) } ?? now
    return nativeDurationText(max(0, now.timeIntervalSince(start)), live: true)
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
