import SwiftUI
import AppKit
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// The thread toolbar (`NWThreadToolbar`; Main, Review, QuestionAsk boards) for the agent on
/// screen: "space / title", the branch chip only while a question replaces the composer,
/// then the one side-pane button and the options menu (Refresh Thread, Rename…, Pin). Everything comes in as values, compared by
/// value (closures by presence), so the workspace header rerunning for a status report or a
/// selection elsewhere leaves it alone (`.equatable()`). The terminal panel has no button here:
/// ⌘J, the Terminal menu and the palette show it.
struct ThreadHeader: View, Equatable {
    static func == (a: ThreadHeader, b: ThreadHeader) -> Bool {
        a.store === b.store && a.project == b.project && a.title == b.title && a.leadingInset == b.leadingInset
            && (a.showSidebar == nil) == (b.showSidebar == nil) && a.branch == b.branch && a.directory == b.directory
            && a.paneOpen == b.paneOpen && a.paneNews == b.paneNews && a.paneShortcut == b.paneShortcut
            && (a.togglePane == nil) == (b.togglePane == nil) && (a.showChanges == nil) == (b.showChanges == nil)
            && (a.rename == nil) == (b.rename == nil) && a.pinned == b.pinned && (a.togglePin == nil) == (b.togglePin == nil)
    }

    var store: NativeThreadStore
    let project: String
    let title: String
    var leadingInset: CGFloat = 0
    var showSidebar: (() -> Void)?
    /// Where the agent works; nil draws no chip.
    var branch: AgentBranchLabel?
    /// The checkout's directory, for the chip's tooltip and menu (local agents only).
    var directory: String?
    /// The side pane: showing, and what pi opened while its tabs are out of sight.
    var paneOpen = false
    var paneNews: String?
    var paneShortcut: String?
    var togglePane: (() -> Void)?
    /// The chip's Show Changes.
    var showChanges: (() -> Void)?
    var rename: (() -> Void)?
    /// Whether the thread is pinned, and Pin or Unpin; nil for a thread that can't be pinned (an
    /// automation's run, or the project tree on screen).
    var pinned: Bool?
    var togglePin: (() -> Void)?

    var body: some View {
        let _ = NWRenderProbe.tick("thread.header")
        NWThreadToolbar(title, project: project, titleHelp: "\(project) / \(title)", leadingInset: leadingInset, sidebar: showSidebar) {
            // A question takes the composer's place, so its checkout menu moves back here.
            if let branch {
                QuestionBranchMenu(store: store, branch: branch, directory: directory, showChanges: showChanges)
            }
        } trailing: {
            ThreadGoalHeader(store: store)
            if let togglePane {
                NWSidePaneButton(isOn: paneOpen, news: paneNews, shortcut: paneShortcut, action: togglePane)
            }
            NWOptionsMenu("Thread options") {
                Button("Refresh Thread") { Task { await store.refresh(fresh: true) } }
                if rename != nil || togglePin != nil { Divider() }
                if let rename {
                    Button("Rename…", action: rename)
                }
                if let pinned, let togglePin {
                    Button(PinWords.menuTitle(pinned: pinned), systemImage: PinWords.symbol(pinned: pinned), action: togglePin)
                }
            }
        }
    }
}

/// Observe question changes here, not in the toolbar that hosts the fallback.
private struct QuestionBranchMenu: View {
    let store: NativeThreadStore
    let branch: AgentBranchLabel
    let directory: String?
    let showChanges: (() -> Void)?

    var body: some View {
        if !store.dialogs.isEmpty {
            BranchChipMenu(branch: branch, directory: directory, showChanges: showChanges)
        }
    }
}

/// The branch chip, and its menu (the chevron): Show Changes, Copy Branch Name, and for a
/// checkout on this Mac Copy Path and Show in Finder. Its tooltip has the branch, the count, and
/// the directory in full.
struct BranchChipMenu: View {
    let branch: AgentBranchLabel
    let directory: String?
    let showChanges: (() -> Void)?

    var body: some View {
        Menu {
            if let showChanges {
                Button("Show Changes", action: showChanges)
                Divider()
            }
            Button("Copy Branch Name") { copy(branch.branch) }
            if let directory {
                Button("Copy Path") { copy(directory) }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: (directory as NSString).expandingTildeInPath)])
                }
            }
        } label: {
            NWComposerBranchLabel(branch: branch.branch, changes: branch.changedFiles,
                                  checkout: branch.kind == .checkout, host: branch.host)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.nwComposerChip())
        .fixedSize(horizontal: false, vertical: true)
        .help(branch.help(directory: directory.map { ($0 as NSString).abbreviatingWithTildeInPath }))
        .accessibilityLabel(NWBranchChip.accessibilityLabel(kind: branch.kind == .worktree ? .worktree : .checkout, branch: branch.branch,
                                                            changedFiles: branch.changedFiles, host: branch.host))
        // A count that moves rolls; switching agents replaces the header at once.
        .nwAnimation(.content, value: branch)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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
