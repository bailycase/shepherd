import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// The thread toolbar (Navigation board, `NWThreadToolbar`) for the agent on screen: title ·
/// spacer · "n turns · 42k ctx" · the subagents and review toggles (lantern while their pane is
/// open) · options. Observes the thread store; everything else comes in as values.
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
