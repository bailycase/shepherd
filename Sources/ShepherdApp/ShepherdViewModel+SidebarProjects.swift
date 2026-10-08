import AppKit
import Foundation
import ShepherdCore
import ShepherdUI

/// The sidebar organized by project (Sidebar — Projects): the tree's values, its projects'
/// disclosure, order and visibility, and the project menu's actions.
@MainActor
extension ShepherdViewModel {
    // MARK: Style

    /// Settings ▸ Appearance ▸ Sidebar ▸ Organize by.
    var sidebarStyle: NWSidebarStyle { settings.sidebarStyle }

    /// View ▸ Organize Sidebar By: the thread on screen stays selected and scrolls into view.
    func setSidebarStyle(_ style: NWSidebarStyle) {
        guard settings.sidebarStyle != style else { return }
        settings.sidebarStyle = style
        sidebarRevealRequest += 1
    }

    // MARK: Values

    /// Group by host and Keep idle threads, as the tree reads them.
    var sidebarTreeOptions: SidebarTreeOptions {
        SidebarTreeOptions(groupByHost: settings.sidebarGroupByHost,
                           idleCutoff: SidebarTreeOptions.idleCutoff(days: settings.sidebarKeepIdleDays, now: Date()))
    }

    /// The project tree, derived again only when what it reads changed.
    var sidebarTree: SidebarTree {
        let source = sidebarSource
        let options = sidebarTreeOptions
        if let cached = sidebarTreeCache, cached.source == source, cached.options == options { return cached.tree }
        let tree = SidebarDerivation.tree(source, options: options)
        sidebarTreeCache = (source, options, tree)
        return tree
    }

    /// Hosts a new thread can start on now.
    var connectedHostIDs: Set<UUID> {
        Set(remoteHosts.connections.filter { $0.phase == .connected }.map(\.id))
    }

    /// The tree as the sidebar draws it: closed projects closed, the row on screen marked, and
    /// ⌘-digits while ⌘ is held.
    var presentedSidebarTree: [SidebarTreeItem] {
        sidebarTree.items(collapsed: collapsedProjects, selected: selectedSidebarRow, shortcuts: showAgentShortcutBadges,
                          connected: connectedHostIDs)
    }

    /// The rows ⌘↑/↓ walk, in the style on screen: Needs you then Recents, or the open projects'
    /// threads in order.
    var sidebarWalkRows: [SidebarListRow] {
        sidebarStyle == .projects ? sidebarTree.visibleRows(collapsed: collapsedProjects)
            : sidebarLists.visibleRows(collapsed: collapsedActivitySections)
    }

    /// The rows ⌘1–9 reach, in the style on screen.
    var sidebarShortcutRows: [SidebarListRow] {
        sidebarStyle == .projects ? sidebarTree.visibleRows(collapsed: collapsedProjects)
            : sidebarLists.shortcutRows(collapsed: collapsedActivitySections)
    }

    // MARK: Disclosure

    /// A project's chevron: ⌥-click opens or closes every project with it.
    func toggleProject(_ id: SidebarProjectID, all: Bool = false) {
        let expand = collapsedProjects.contains(id.key)
        if all {
            setAllProjects(expanded: expand)
        } else {
            setProject(id, expanded: expand)
        }
    }

    /// → and ← with the tree focused.
    func setProject(_ id: SidebarProjectID, expanded: Bool) {
        if expanded {
            if collapsedProjects.contains(id.key) { collapsedProjects.remove(id.key) }
        } else if !collapsedProjects.contains(id.key) {
            collapsedProjects.insert(id.key)
        }
    }

    /// The project menu's Collapse All, and ⌥-click.
    func setAllProjects(expanded: Bool) {
        let keys = Set(sidebarTree.projects.map(\.id.key))
        let next = expanded ? collapsedProjects.subtracting(keys) : collapsedProjects.union(keys)
        if next != collapsedProjects { collapsedProjects = next }
    }

    /// A row selected by the keyboard, the palette or a switch of style: its project opens so
    /// the row is there to scroll to.
    func openProjectHoldingSelection() {
        guard sidebarStyle == .projects, let selected = selectedSidebarRow,
              let project = sidebarTree.project(holding: selected) else { return }
        if let parent = project.parentID { setProject(parent, expanded: true) }
        setProject(project.id, expanded: true)
    }

    // MARK: Order and visibility

    /// A project dropped on the line before `target`, or under the last project (nil). Only
    /// This Mac's projects move: their order is the spaces' order.
    func moveProject(_ space: SpaceID, before target: SpaceID?) {
        guard let moved = state.spaces.moving(space, before: target), moved != state.spaces else { return }
        state.spaces = moved
        sessions.stateDidChange(state)
        enqueuePersistence("move project") { try await $0.moveSpace(space, before: target) }
    }

    /// The project menu's Hide from Sidebar: its threads stay in ⌘K and Activity, and the +
    /// beside Projects brings it back.
    func setProjectHiddenFromSidebar(_ id: SpaceID, _ hidden: Bool) {
        guard let index = state.spaces.firstIndex(where: { $0.id == id }), state.spaces[index].sidebarHidden != hidden else { return }
        state.spaces[index].sidebarHidden = hidden
        sessions.stateDidChange(state)
        let space = state.spaces[index]
        enqueuePersistence(hidden ? "hide project" : "show project") { try await $0.updateSpace(space) }
    }

    // MARK: Project menu

    /// + on a project, and New thread in <project>: the New thread page in it, on the host its
    /// newest thread runs on.
    func startThread(in project: SidebarProjectRow) {
        guard let space = project.newThreadSpace else { return }
        openNewThread(in: space, hostID: project.newThreadHost)
    }

    func revealProjectInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: (path as NSString).expandingTildeInPath)])
    }

    /// Open in Terminal: the Mac's Terminal in the project's folder.
    func openProjectInTerminal(_ path: String) {
        let folder = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    func copyProjectPath(_ path: String) {
        Self.copyToPasteboard(path)
    }
}
