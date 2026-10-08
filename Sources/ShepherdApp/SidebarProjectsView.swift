import AppKit
import SwiftUI
import ShepherdCore
import ShepherdUI

/// The sidebar organized by project (Sidebar — Projects: SidebarTree, SidebarProjects,
/// SidebarProjectsHosts): Projects with its +, or a section per host while grouped, each project a
/// folder row (`NWProjectRow`) with its threads under it (`NWSidebarRow`, nested).
///
/// One lazy stack, as Recents is: each element is a plain value compared before it redraws, so a
/// status report redraws its row and its project's, and opening a project builds the rows it
/// shows. A project drags by its row (no per-row drop targets): the drag's offset picks the
/// project it lands before, and a line marks where. With the tree focused (a project clicked),
/// ← closes that project and → opens it; ⌥-click on a project opens or closes every project.
struct SidebarProjectsList: View {
    var vm: ShepherdViewModel
    @State private var drag: ProjectDrag?
    @State private var focusedProject: SidebarProjectID?
    /// A row's height and the gap under it, kept in state: the rows keep the closures they were
    /// first built with (they compare without them), so those read state, never a captured value.
    @State private var pitch: CGFloat = 0
    @FocusState private var focused: Bool
    @Environment(\.nwDensity) private var density

    var body: some View {
        let items = vm.presentedSidebarTree
        let hidden = vm.sidebarTree.hiddenProjects
        let plan = drag.flatMap { ProjectDrop.plan($0, items: items, pitch: pitch) }
        LazyVStack(alignment: .leading, spacing: AppLayout.sidebarRowSpacing) {
            ForEach(items) { item in
                SidebarTreeItemView(
                    vm: vm, item: item, hiddenProjects: Self.isProjectsHeader(item) ? hidden : [],
                    drop: plan?.line == item.id ? plan?.edge : nil, dragging: Self.projectID(item).map { $0 == drag?.id } ?? false,
                    focus: { focusedProject = $0; focused = true },
                    dragChanged: { id, offset in drag = ProjectDrag(id: id, offset: offset) },
                    dragEnded: { id, offset in
                        if case .local(let space) = id,
                           let landing = ProjectDrop.plan(ProjectDrag(id: id, offset: offset), items: vm.presentedSidebarTree, pitch: pitch) {
                            vm.moveProject(space, before: landing.before)
                        }
                        drag = nil
                    })
                .equatable()
                .nwTransition(.list)
            }
        }
        // Focused only by a click on a project (never by a click on a thread, which hands the
        // keyboard to its thread), so ← and → never reach the tree while someone types.
        .focusable(interactions: .activate)
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { disclose(false) }
        .onKeyPress(.rightArrow) { disclose(true) }
        .onChange(of: density.rowHeight, initial: true) { pitch = density.rowHeight + AppLayout.sidebarRowSpacing }
        // Rows arriving, leaving, and moving up animate; the key is the rows' ids, never the rows.
        .nwAnimation(.list, value: items.map(\.id))
    }

    /// ← and →: the project last clicked, else the one holding the row on screen.
    private func disclose(_ expanded: Bool) -> KeyPress.Result {
        let target = focusedProject ?? vm.selectedSidebarRow.flatMap { vm.sidebarTree.project(holding: $0)?.id }
        guard let target else { return .ignored }
        vm.setProject(target, expanded: expanded)
        return .handled
    }

    private static func isProjectsHeader(_ item: SidebarTreeItem) -> Bool {
        if case .header(.projects) = item { true } else { false }
    }

    private static func projectID(_ item: SidebarTreeItem) -> SidebarProjectID? {
        if case .project(let project) = item { project.id } else { nil }
    }
}

/// A project being dragged, and how far.
struct ProjectDrag: Equatable {
    let id: SidebarProjectID
    var offset: CGFloat
}

/// Where a dragged project lands: before `before` (last when nil), with the line drawn on the
/// top or bottom edge of the element `line`.
struct ProjectDrop: Equatable {
    enum Edge: Equatable { case top, bottom }

    let before: SpaceID?
    let line: AnyHashable
    let edge: Edge

    /// The landing for a drag `offset` points down (up while negative) from the dragged project's
    /// row, every row `pitch` apart. Only This Mac's projects move, among themselves; nil when
    /// the project would stay where it is.
    static func plan(_ drag: ProjectDrag, items: [SidebarTreeItem], pitch: CGFloat) -> ProjectDrop? {
        guard let source = items.compactMap({ item -> SidebarProjectRow? in
            if case .project(let project) = item, project.id == drag.id { return project }; return nil
        }).first else { return nil }
        // Only siblings can reorder. Descendant rows extend their parent's drop block.
        var movable: [(index: Int, space: SpaceID, id: AnyHashable)] = []
        var regionEnd = -1
        for (index, item) in items.enumerated() {
            switch item {
            case .project(let project) where project.movable && project.parentID == source.parentID:
                guard let space = project.space else { continue }
                movable.append((index, space, item.id))
                regionEnd = index
            case .project(let project) where source.parentID == nil && project.parentID != nil && !movable.isEmpty && regionEnd == index - 1:
                regionEnd = index
            case .row where !movable.isEmpty && regionEnd == index - 1:
                regionEnd = index
            default:
                continue
            }
        }
        guard pitch > 0, let from = movable.firstIndex(where: { AnyHashable(drag.id) == $0.id }),
              let first = movable.first else { return nil }
        let pointer = min(max(movable[from].index + Int((drag.offset / pitch).rounded()), first.index), regionEnd)
        // The project whose block the pointer is over.
        guard let over = movable.lastIndex(where: { $0.index <= pointer }) else { return nil }
        if pointer > movable[from].index {
            // Down: after the project under the pointer.
            guard over != from else { return nil }
            let next = over + 1
            if next < movable.count {
                return ProjectDrop(before: movable[next].space, line: movable[next].id, edge: .top)
            }
            return ProjectDrop(before: nil, line: items[regionEnd].id, edge: .bottom)
        }
        // Up: before the project under the pointer.
        guard over < from else { return nil }
        return ProjectDrop(before: movable[over].space, line: movable[over].id, edge: .top)
    }
}

/// One element of the tree, a single view whatever it shows (a lazy stack's fast path), redrawn
/// only when its values change.
private struct SidebarTreeItemView: View, Equatable {
    var vm: ShepherdViewModel
    let item: SidebarTreeItem
    /// The + beside Projects lists these to bring back.
    let hiddenProjects: [Space]
    let drop: ProjectDrop.Edge?
    let dragging: Bool
    let focus: (SidebarProjectID) -> Void
    let dragChanged: (SidebarProjectID, CGFloat) -> Void
    let dragEnded: (SidebarProjectID, CGFloat) -> Void

    static func == (a: SidebarTreeItemView, b: SidebarTreeItemView) -> Bool {
        a.vm === b.vm && a.item == b.item && a.hiddenProjects == b.hiddenProjects && a.drop == b.drop && a.dragging == b.dragging
    }

    var body: some View {
        VStack(spacing: 0) {
            switch item {
            case .header(.projects):
                NWProjectsHeader { ProjectsAddMenu(vm: vm, hidden: hiddenProjects) }
            case .header(.host(let name, _, let unreachable)):
                NWSidebarSection(.host(name, unreachable: unreachable))
            case .project(let project):
                projectRow(project)
            case .row(let row):
                NWSidebarRow(row.title, leading: row.leading, selected: row.selected, dimmed: row.offline,
                             accessory: row.accessory, hasGoal: row.hasGoal, nested: true)
                    .padding(.leading, row.inChildProject ? NWProjectMetrics.chevronSlot + NWProjectMetrics.gap : 0)
                    .help(row.help)
                    .sidebarTapRow { vm.selectSidebarRow(row.id) }
                    .accessibilityLabel(row.accessibilityLabel)
                    .accessibilityAddTraits(row.selected ? .isSelected : [])
                    .contextMenu { SidebarRowMenu(vm: vm, row: row) }
            }
        }
        .overlay(alignment: drop == .bottom ? .bottom : .top) {
            if let drop {
                NWDropIndicator()
                    .padding(.horizontal, NW.Space.xs)
                    .offset(y: (drop == .top ? -1 : 1) * (NWDropIndicator.thickness + AppLayout.sidebarRowSpacing) / 2)
            }
        }
    }

    private func projectRow(_ project: SidebarProjectRow) -> some View {
        let id = project.id
        return NWProjectRow(project.name, count: project.count, expanded: project.expanded, rollup: project.rollup,
                            dimmed: project.dimmed,
                            toggle: {
                                focus(id)
                                vm.toggleProject(id, all: NSEvent.modifierFlags.contains(.option))
                            },
                            newThread: project.newThreadSpace == nil ? nil : { vm.startThread(in: project) }) {
            SidebarProjectMenu(vm: vm, project: project)
        }
        .padding(.leading, project.parentID == nil ? 0 : NWProjectMetrics.chevronSlot + NWProjectMetrics.gap)
        .help(project.path)
        .contextMenu { SidebarProjectMenu(vm: vm, project: project) }
        .opacity(dragging ? NWProjectMetrics.draggedOpacity : 1)
        .gesture(DragGesture(minimumDistance: NW.Space.xs)
            .onChanged { dragChanged(id, $0.translation.height) }
            .onEnded { dragEnded(id, $0.translation.height) },
                 isEnabled: project.movable)
    }
}

/// The + beside Projects: add a project, or bring back one hidden from the sidebar.
private struct ProjectsAddMenu: View {
    var vm: ShepherdViewModel
    let hidden: [Space]

    var body: some View {
        Button("Add Project…", systemImage: "folder.badge.plus") { vm.addSpaceFromPanel() }
        if !hidden.isEmpty {
            Divider()
            Section("Hidden from Sidebar") {
                ForEach(hidden) { space in
                    Button("Show \(space.name)", systemImage: "eye") { vm.setProjectHiddenFromSidebar(space.id, false) }
                }
            }
        }
    }
}

/// The project menu (SidebarTree, `NWProjectMenu`): right-click a project, or ··· on hover.
/// Missions are not built, so there is no New Mission.
struct SidebarProjectMenu: View {
    var vm: ShepherdViewModel
    let project: SidebarProjectRow

    var body: some View {
        if project.newThreadSpace != nil {
            Button("New Thread in \(project.name)", systemImage: "plus") { vm.startThread(in: project) }
            Divider()
        }
        // Finder and Terminal reach This Mac's folders only.
        if project.space != nil {
            Button("Add Child Project…") {
                vm.addingChildProject = vm.childProjectModel(path: project.path, name: project.name)
            }
            Button("Reveal in Finder", systemImage: "folder") { vm.revealProjectInFinder(project.path) }
            Button("Open in Terminal", systemImage: "terminal") { vm.openProjectInTerminal(project.path) }
        }
        Button("Copy Path", systemImage: "doc.on.doc") { vm.copyProjectPath(project.path) }
        Divider()
        Button("Collapse All", systemImage: "arrow.down.and.line.horizontal.and.arrow.up") { vm.setAllProjects(expanded: false) }
        if let space = project.space {
            Button("Hide from Sidebar", systemImage: "eye.slash") { vm.setProjectHiddenFromSidebar(space, true) }
        }
    }
}
