import SwiftUI
import AppKit
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// The thread toolbar (`NWThreadToolbar`; Main, Review, QuestionAsk boards) for the agent on
/// screen: "space / title", the branch chip (where the agent works and the files changed there),
/// then the one side-pane button and the options menu. Everything comes in as values, compared by
/// value (closures by presence), so the workspace header rerunning for a status report or a
/// selection elsewhere leaves it alone (`.equatable()`). The terminal panel has no button here:
/// ⌘J, the Pane menu and the palette show it.
struct ThreadHeader: View, Equatable {
    static func == (a: ThreadHeader, b: ThreadHeader) -> Bool {
        a.store === b.store && a.project == b.project && a.title == b.title && a.leadingInset == b.leadingInset
            && (a.showSidebar == nil) == (b.showSidebar == nil) && a.branch == b.branch && a.directory == b.directory
            && a.paneOpen == b.paneOpen && a.paneNews == b.paneNews && a.paneShortcut == b.paneShortcut
            && (a.togglePane == nil) == (b.togglePane == nil) && (a.showChanges == nil) == (b.showChanges == nil)
            && (a.rename == nil) == (b.rename == nil)
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

    var body: some View {
        let _ = NWRenderProbe.tick("thread.header")
        NWThreadToolbar(title, project: project, titleHelp: "\(project) / \(title)", leadingInset: leadingInset, sidebar: showSidebar) {
            if let branch {
                BranchChipMenu(branch: branch, directory: directory, showChanges: showChanges)
            }
        } trailing: {
            if let togglePane {
                NWSidePaneButton(isOn: paneOpen, news: paneNews, shortcut: paneShortcut, action: togglePane)
            }
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

/// The branch chip, and its menu (the chevron): Show Changes, Copy Branch Name, and for a
/// checkout on this Mac Copy Path and Show in Finder. Its tooltip has the branch, the count, and
/// the directory in full.
private struct BranchChipMenu: View {
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
            NWBranchChip(kind: branch.kind == .worktree ? .worktree : .checkout, branch: branch.branch,
                         changedFiles: branch.changedFiles, host: branch.host)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
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
