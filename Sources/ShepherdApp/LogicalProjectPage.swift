import SwiftUI
import ShepherdRemote
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
        let _ = SHRenderProbe.tick("page.project")
        VStack(spacing: 0) {
            if let ref = vm.selectedLogicalProject, let project = vm.logicalProjects.project(ref) {
                let presentation = ProjectPagePresentation(project)
                // The toolbar and conversation are one column; the Threads pane runs the window's full height beside it, with
                // its own header (ProjectLead-Started). It is a thread's side pane: the same divider to drag (or adjust with
                // VoiceOver, or double-click for half the page), the same bounds, and in a page too narrow to keep the
                // conversation 400pt it overlays it. Expand gives the pane the whole page, the conversation hidden under it.
                RightPaneSplit(state: vm.logicalProjectPane, showPane: vm.logicalProjectPaneOpen,
                               maximized: vm.logicalProjectPaneExpanded) {
                    VStack(spacing: 0) {
                        LogicalProjectToolbar(vm: vm, ref: ref, project: project, presentation: presentation, chrome: chrome)
                        LogicalProjectConversation(vm: vm, ref: ref, project: project, presentation: presentation)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } pane: {
                    LogicalProjectPane(vm: vm, ref: ref, project: project, presentation: presentation)
                }
            } else {
                PlainHeader(title: "Project", leadingInset: chrome.leadingInset, showSidebar: chrome.showSidebar)
                SHEmptyState(Text("This project is gone"), message: "It was deleted on its host.") {}
            }
        }
        .background(Color.sh.bgWindow)
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
        SHLeadToolbar(project.name, leadingInset: chrome.leadingInset, sidebar: chrome.showSidebar) {
            // Overview is the page shown; a dot says something waits on you (Paused, Resolved boards).
            // Overview is the Threads pane's switch: selected while the pane is open (ProjectLead-Started vs -Question).
            SHLeadToolbarButton("Overview", symbol: "list.bullet", selected: vm.logicalProjectPaneOpen && vm.logicalProjectPaneTask == nil,
                                dot: presentation.needsYou > 0) { vm.logicalProjectPaneOpen.toggle() }
            Button { vm.openLogicalProjectSettings(ref) } label: { Image(systemName: "gearshape") }
                .buttonStyle(.shIcon)
                .shHelp("Project settings")
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
        VStack(alignment: .leading, spacing: SHLeadMetrics.overviewGap) {
            HStack(spacing: SHLeadMetrics.overviewTitleGap) {
                SHProjectGlyphView(tint: .sh.lantern, size: SHLeadMetrics.overviewGlyph)
                Text(project.name).font(.sh(.title, weight: .semibold)).foregroundStyle(Color.sh.textPrimary).lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
            }
            if !project.goal.isEmpty {
                Text(project.goal).font(.sh(.body)).lineSpacing(SHLeadMetrics.overviewGoalLineSpacing)
                    .foregroundStyle(Color.sh.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            contextCard
            if !suggestions.isEmpty { suggestionsCard }
        }
        .frame(maxWidth: SHLeadMetrics.columnWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.top, SHLeadMetrics.overviewTop)
    }

    private var contextCard: some View {
        VStack(spacing: 0) {
            contextRow(symbol: "folder", title: "Spaces",
                       detail: spaceNames.isEmpty ? "None yet · add in settings"
                           : spaceNames.prefix(2).joined(separator: ", ") + (spaceNames.count > 2 ? " +\(spaceNames.count - 2)" : "") + " · add more in settings",
                       tab: .spaces)
            SHHairline()
            contextRow(symbol: SHGlyph.document.symbolName, title: "Instructions, memory", detail: "In project settings", tab: .memory)
        }
        .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Radius.l))
        .shBorder(Color.sh.lineStrong, radius: SH.Radius.l)
    }

    private func contextRow(symbol: String, title: String, detail: String, tab: LogicalProjectSettingsTab) -> some View {
        Button { vm.openLogicalProjectSettings(ref, tab: tab) } label: {
            HStack(spacing: SH.Space.l) {
                Image(systemName: symbol).font(.system(size: SHLeadMetrics.toolbarGlyph)).foregroundStyle(Color.sh.textSecondary)
                    .accessibilityHidden(true)
                Text(title).font(.sh(.ui, weight: .regular)).foregroundStyle(Color.sh.textPrimary)
                Spacer(minLength: SH.Space.l)
                Text(detail).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary).lineLimit(1).truncationMode(.tail)
            }
            .padding(.horizontal, SH.Space.l)
            .padding(.vertical, SH.Space.m)
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
            Text("Suggestions").font(.sh(.caption, weight: .medium)).foregroundStyle(Color.sh.textSecondary)
                .padding(EdgeInsets(top: SH.Space.m, leading: SH.Space.l, bottom: SH.Space.xs, trailing: SH.Space.l))
            ForEach(suggestions, id: \.self) { (text: String) in
                Button { vm.useProjectSuggestion(text, in: ref) } label: {
                    HStack(spacing: SH.Space.l) {
                        Image(systemName: "sparkles").font(.system(size: SHLeadMetrics.toolbarGlyph)).foregroundStyle(Color.sh.textSecondary)
                            .accessibilityHidden(true)
                        Text(text).font(.sh(.ui, weight: .regular)).foregroundStyle(Color.sh.textPrimary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, SH.Space.l)
                    .frame(minHeight: SHLeadMetrics.suggestionRow)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(text)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Radius.l))
        .shBorder(Color.sh.lineStrong, radius: SH.Radius.l)
    }
}
