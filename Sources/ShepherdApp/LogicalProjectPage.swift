import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdUI

// A Project's page (ProjectLead-EmptyV2): its name and goal, the Spaces it works in, Instructions
// and memory, and Suggestions. The conversation, the task list, questions and the pause banner come
// from the project runtime (a coordinator thread and its tasks); until the runtime reports them the
// page shows the real initial context only, never a sample conversation or a send that did nothing.

struct LogicalProjectDestination: View {
    var vm: ShepherdViewModel
    var chrome = PageHeaderChrome()

    var body: some View {
        let _ = NWRenderProbe.tick("page.project")
        VStack(spacing: 0) {
            if let ref = vm.selectedLogicalProject, let project = vm.logicalProjects.project(ref) {
                let presentation = ProjectPagePresentation(project)
                // The toolbar and conversation are one column; the Threads pane runs the window's full height beside it, with
                // its own header (ProjectLead-Started).
                HStack(spacing: 0) {
                    // Expand gives the pane the whole page; pressing it again brings the conversation back.
                    let expanded = vm.logicalProjectPaneOpen && vm.logicalProjectPaneExpanded
                    if !expanded {
                        VStack(spacing: 0) {
                            LogicalProjectToolbar(vm: vm, ref: ref, project: project, presentation: presentation, chrome: chrome)
                            LogicalProjectConversation(vm: vm, ref: ref, project: project, presentation: presentation)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    if vm.logicalProjectPaneOpen {
                        LogicalProjectPane(vm: vm, ref: ref, project: project, presentation: presentation)
                            .frame(width: expanded ? nil : NWLeadMetrics.paneWidth)
                            .frame(maxWidth: expanded ? .infinity : NWLeadMetrics.paneWidth)
                    }
                }
            } else {
                PlainHeader(title: "Project", leadingInset: chrome.leadingInset, showSidebar: chrome.showSidebar)
                NWEmptyState(Text("This project is gone"), message: "It was deleted on its host.") {}
            }
        }
        .background(Color.nw.bgWindow)
    }
}

/// The toolbar: the project's glyph and name, then Overview (the page shown) and Project settings at the
/// trailing edge (ProjectLead-EmptyV2).
private struct LogicalProjectToolbar: View {
    var vm: ShepherdViewModel
    let ref: LogicalProjectRef
    let project: Project
    let presentation: ProjectPagePresentation
    let chrome: PageHeaderChrome

    var body: some View {
        NWLeadToolbar(project.name, leadingInset: chrome.leadingInset, sidebar: chrome.showSidebar) {
            // Overview is the page shown; a dot says something waits on you (Paused, Resolved boards).
            // Overview is the Threads pane's switch: selected while the pane is open (ProjectLead-Started vs -Question).
            NWLeadToolbarButton("Overview", symbol: "list.bullet", selected: vm.logicalProjectPaneOpen && vm.logicalProjectPaneTask == nil,
                                dot: presentation.needsYou > 0) { vm.logicalProjectPaneOpen.toggle() }
            Button { vm.openLogicalProjectSettings(ref) } label: { Image(systemName: "gearshape") }
                .buttonStyle(.nwIcon)
                .nwHelp("Project settings")
                .accessibilityLabel("Project settings")
        }
    }
}

/// The Empty overview (ProjectLead-EmptyV2): real data only. Every measure is the board's: a 680pt column 104pt in from
/// the section's edge (the thread column's own), the glyph 16pt and the name 15/600 on one line 60pt down, the goal 13.5
/// on 1.6 lines, then two cards at radius 12: a 69pt context card (34pt rows, 12/8 padding, 12pt gaps) and a 116pt
/// Suggestions card (a 27pt caption row, then 29pt rows).
struct LogicalProjectOverview: View {
    var vm: ShepherdViewModel
    let ref: LogicalProjectRef
    let project: Project

    private var spaceNames: [String] {
        let known = vm.ownerSpaces(of: ref.home)
        return project.linkedSpaces.compactMap { link in known.first { $0.id == link.spaceID }?.name }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NWLeadMetrics.overviewGap) {
            HStack(spacing: NWLeadMetrics.overviewTitleGap) {
                NWProjectGlyphView(tint: .nw.lantern, size: NWLeadMetrics.overviewGlyph)
                Text(project.name).font(.nw(.title, weight: .semibold)).foregroundStyle(Color.nw.textPrimary).lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
            }
            if !project.goal.isEmpty {
                Text(project.goal).font(.nw(.body)).lineSpacing(NWLeadMetrics.overviewGoalLineSpacing)
                    .foregroundStyle(Color.nw.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            contextCard
            if !suggestions.isEmpty { suggestionsCard }
        }
        .frame(maxWidth: NWLeadMetrics.columnWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.top, NWLeadMetrics.overviewTop)
    }

    private var contextCard: some View {
        VStack(spacing: 0) {
            contextRow(symbol: "folder", title: "Spaces",
                       detail: spaceNames.isEmpty ? "None yet · add in settings"
                           : spaceNames.prefix(2).joined(separator: ", ") + (spaceNames.count > 2 ? " +\(spaceNames.count - 2)" : "") + " · add more in settings",
                       tab: .spaces)
            NWHairline()
            contextRow(symbol: NWGlyph.document.symbolName, title: "Instructions, memory", detail: "In project settings", tab: .memory)
        }
        .background(Color.nw.bgRaised, in: RoundedRectangle(cornerRadius: NW.Radius.l))
        .nwBorder(Color.nw.lineStrong, radius: NW.Radius.l)
    }

    private func contextRow(symbol: String, title: String, detail: String, tab: LogicalProjectSettingsTab) -> some View {
        Button { vm.openLogicalProjectSettings(ref, tab: tab) } label: {
            HStack(spacing: NW.Space.l) {
                Image(systemName: symbol).font(.system(size: NWLeadMetrics.toolbarGlyph)).foregroundStyle(Color.nw.textSecondary)
                    .accessibilityHidden(true)
                Text(title).font(.nw(.ui, weight: .regular)).foregroundStyle(Color.nw.textPrimary)
                Spacer(minLength: NW.Space.l)
                Text(detail).font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary).lineLimit(1).truncationMode(.tail)
            }
            .padding(.horizontal, NW.Space.l)
            .padding(.vertical, NW.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(detail)")
    }

    // MARK: Suggestions

    /// Prompts a person could send. They name only real context: the first linked Space's own name, never a sample's.
    private var suggestions: [String] {
        var items = ["Set up this project from my recent threads", "Help me work out a plan for this project"]
        if let first = spaceNames.first { items.append("Look around \(first) and suggest first threads") }
        return items
    }

    private var suggestionsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Suggestions").font(.nw(.caption, weight: .medium)).foregroundStyle(Color.nw.textSecondary)
                .padding(EdgeInsets(top: NW.Space.m, leading: NW.Space.l, bottom: NW.Space.xs, trailing: NW.Space.l))
            ForEach(suggestions, id: \.self) { (text: String) in
                Button { vm.useProjectSuggestion(text, in: ref) } label: {
                    HStack(spacing: NW.Space.l) {
                        Image(systemName: "sparkles").font(.system(size: NWLeadMetrics.toolbarGlyph)).foregroundStyle(Color.nw.textSecondary)
                            .accessibilityHidden(true)
                        Text(text).font(.nw(.ui, weight: .regular)).foregroundStyle(Color.nw.textPrimary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, NW.Space.l)
                    .frame(minHeight: NWLeadMetrics.suggestionRow)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(text)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.nw.bgRaised, in: RoundedRectangle(cornerRadius: NW.Radius.l))
        .nwBorder(Color.nw.lineStrong, radius: NW.Radius.l)
    }
}
