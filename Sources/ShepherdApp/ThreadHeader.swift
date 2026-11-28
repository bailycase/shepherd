import SwiftUI
import AppKit
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdSidebar

/// The thread toolbar (`SHThreadToolbar`; Main, Review, QuestionAsk, FleetMove, FleetRemote boards)
/// for the agent on screen: "space / parent / title" (the parent only for a thread another thread
/// started), then the one side-pane button, the options menu (where it runs, Refresh Thread,
/// Rename…, Pin, Mute Notifications, Move to), and another host's thread's branch chip. A thread on another Mac names it after the
/// title ("on mini ⌄", FleetRemote), and that menu takes where it runs, Move to and Sent by. Everything comes in as values, compared by
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
            && a.muted == b.muted && (a.toggleMute == nil) == (b.toggleMute == nil)
            && a.apps == b.apps && a.move == b.move && (a.moveTo == nil) == (b.moveTo == nil) && a.remoteHost == b.remoteHost && a.sentBy == b.sentBy && a.sentByOnline == b.sentByOnline && (a.openSender == nil) == (b.openSender == nil)
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
    /// Whether the thread's pushes are muted on its host, and Mute or Unmute; nil where its host takes no Mute.
    var muted: Bool?
    var toggleMute: (() -> Void)?
    /// Where the thread runs and where it can move to (FleetMove): "Runs on" and "Move to" in the options menu. Nil shows neither;
    /// `moveTo` asks first while a turn runs (`ShepherdViewModel.requestFleetMove`).
    var move: FleetMoveHeader?
    var moveTo: ((FleetMoveMenu.Target) -> Void)?
    /// A thread another thread (or the person) started: the sender in the breadcrumb with its link, and the Mac it runs on in the
    /// options menu (FleetRemote).
    var sentBy: FleetSentBy?
    var sentByOnline = true
    var openSender: (() -> Void)?
    /// The Mac a thread runs on when it is not this one: "on mini ⌄" after the title, whose menu has where it runs, Move to and who
    /// sent it (GXRemote). Those leave the options menu and the breadcrumb for such a thread.
    var remoteHost: String?
    /// The space's quick actions (AppsQuickAction board); nil draws no Run button.
    var apps: QuickApps?
    var runApp: (AppKey) -> Void = { _ in }
    var stopApp: (AppKey) -> Void = { _ in }
    var restartApp: (AppKey) -> Void = { _ in }
    var appOutput: (AppKey) -> Void = { _ in }
    var editApps: () -> Void = {}
    @State private var hostMenu = false

    var body: some View {
        let _ = SHRenderProbe.tick("thread.header")
        // A thread the person started on another Mac is a thread like any other: only one a thread started names its parent.
        let parent = sentBy?.fromThread == true ? sentBy?.sender : nil
        let shownParent = remoteHost == nil ? parent : nil
        let crumbs = [project, parent, title].compactMap { $0 }.joined(separator: " / ")
        SHThreadToolbar(title, project: project, titleHelp: crumbs, parent: shownParent, openParent: shownParent == nil ? nil : openSender,
                        leadingInset: leadingInset, sidebar: showSidebar) {
            if let remoteHost {
                SHHostChip(host: remoteHost) { hostMenu = true }
                    .popover(isPresented: $hostMenu, arrowEdge: .bottom) {
                        RemoteThreadMenu(host: remoteHost, movedFrom: move?.chip.movedFrom, online: sentByOnline,
                                         targets: move?.menu.targets ?? [], busy: move?.busy ?? false, sender: parent, openSender: openSender,
                                         moveTo: { moveTo?($0) }, close: { hostMenu = false })
                    }
            }
        } trailing: {
            ThreadGoalHeader(store: store)
            if let apps {
                ThreadAppsButton(apps: apps, run: runApp, stop: stopApp, restart: restartApp, output: appOutput, edit: editApps)
            }
            if let togglePane {
                SHSidePaneButton(isOn: paneOpen, news: paneNews, shortcut: paneShortcut, action: togglePane)
            }
            SHOptionsMenu("Thread options") {
                if let runsOn, remoteHost == nil {
                    Section("Runs on") {
                        Text(runsOn)
                        if let movedFrom = move?.chip.movedFrom { Text(movedFrom) }
                    }
                }
                Button("Refresh Thread") { Task { await store.refresh(fresh: true) } }
                if rename != nil || togglePin != nil || toggleMute != nil { Divider() }
                if let rename {
                    Button("Rename…", action: rename)
                }
                if let pinned, let togglePin {
                    Button(PinWords.menuTitle(pinned: pinned), systemImage: PinWords.symbol(pinned: pinned), action: togglePin)
                }
                if let muted, let toggleMute {
                    Button(MuteWords.menuTitle(muted: muted), systemImage: MuteWords.symbol(muted: muted), action: toggleMute)
                }
                if let move, let moveTo, remoteHost == nil {
                    Divider()
                    Menu(move.busy ? "Moving…" : "Move to") {
                        ForEach(move.menu.targets) { target in
                            Button { moveTo(target) } label: {
                                Text(target.name)
                                Text(target.note)
                            }
                            .disabled(!target.enabled)
                            // A menu has no room for the board's footnote under the Macs: each one says it on hover.
                            .help(FleetMoveMenu.footnote)
                            .accessibilityLabel(target.accessibilityLabel)
                        }
                    }
                    .disabled(move.busy)
                }
            }
            // A thread whose branch this Mac can't read a card for (another host's) keeps the plain
            // chip here; this Mac's threads draw the branch card beside their transcript.
            if let branch {
                BranchChipMenu(branch: branch, directory: directory, showChanges: showChanges)
            }
        }
    }

    /// "This Mac · 72% CPU · on battery" for a thread that can move; the Mac a thread from another Mac runs on, and whether it answers.
    private var runsOn: String? {
        if let move { return move.menu.here.detail.isEmpty ? move.chip.text : "\(move.chip.text) · \(move.menu.here.detail)" }
        guard let sentBy, sentBy.showsHost else { return nil }
        return sentByOnline ? sentBy.host : "\(sentBy.host) · offline"
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
            SHComposerBranchLabel(branch: branch.branch, changes: branch.changedFiles,
                                  checkout: branch.kind == .checkout, host: branch.host)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.shComposerChip())
        .fixedSize(horizontal: false, vertical: true)
        .help(branch.help(directory: directory.map { ($0 as NSString).abbreviatingWithTildeInPath }))
        .accessibilityLabel(SHBranchChip.accessibilityLabel(kind: branch.kind == .worktree ? .worktree : .checkout, branch: branch.branch,
                                                            changedFiles: branch.changedFiles, host: branch.host))
        // A count that moves rolls; switching agents replaces the header at once.
        .shAnimation(.content, value: branch)
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
        SHThreadToolbar(title, leadingInset: leadingInset, sidebar: showSidebar)
    }
}
