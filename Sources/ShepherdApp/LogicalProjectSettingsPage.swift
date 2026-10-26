import SwiftUI
import ShepherdRemote
import ShepherdCore
import ShepherdProtocol
import ShepherdUI

// Project settings (ProjectLead-SettingsGeneral, -SettingsSpaces, -SettingsMemory,
// -SettingsAutomations): an in-workspace page with horizontal General, Spaces, Memory and Automations
// tabs. It is not the global Settings ▸ Spaces table and reuses none of it. Every control edits the
// owner's persisted record through `LogicalProjectsModel`, carrying the revision it was shown.

/// The page in the main column.
struct LogicalProjectSettingsDestination: View {
    var vm: ShepherdViewModel
    var chrome = PageHeaderChrome()

    var body: some View {
        let _ = SHRenderProbe.tick("page.projectSettings")
        VStack(spacing: 0) {
            if let showSidebar = chrome.showSidebar {
                HStack {
                    Button(action: showSidebar) { Image(systemName: "sidebar.left") }
                        .buttonStyle(.shIcon)
                        .shHelp("Show sidebar")
                        .accessibilityLabel("Show sidebar")
                    Spacer()
                }
                .padding(.leading, SHToolbarMetrics.leadingPadding + chrome.leadingInset)
                .frame(height: SHToolbarMetrics.height)
            }
            if let ref = vm.selectedLogicalProject, let project = vm.logicalProjects.project(ref) {
                LogicalProjectSettingsPage(vm: vm, ref: ref, project: project)
            } else {
                SHEmptyState(Text("This project is gone"), message: "It was deleted on its host.") {}
            }
        }
        .background(Color.sh.bgWindow)
    }
}

struct LogicalProjectSettingsPage: View {
    var vm: ShepherdViewModel
    let ref: LogicalProjectRef
    let project: Project
    /// nil until the owner has answered (an empty answer is a catalog with nothing in it).
    @State private var models: [String]?
    @State private var confirmingDelete = false

    private var tab: LogicalProjectSettingsTab { vm.logicalProjectSettingsTab }
    private var model: LogicalProjectsModel { vm.logicalProjects }

    var body: some View {
        let M = SHProjectSettingsMetrics.self
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: SH.Space.xl) {
                VStack(alignment: .leading, spacing: SH.Space.s) {
                    // The project's name leads back to its page (not on the boards; the user asked for a way back).
                    Button { vm.openLogicalProject(ref) } label: {
                        HStack(spacing: SH.Space.xs) {
                            SHGlyph.Settings.back.image.accessibilityHidden(true)
                            Text(project.name).lineLimit(1)
                        }
                        .frame(minHeight: SH.Height.controlS)  // the desktop's 24pt hit area
                    }
                    .buttonStyle(.shLink(color: Color.sh.textTertiary, font: .sh(.caption)))
                    .shHelp("Back to \(project.name)")
                    .accessibilityLabel("Back to \(project.name)")
                    Text("Project settings")
                        .font(.sh(.title))
                        .foregroundStyle(Color.sh.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                }
                tabs
                if let failure = model.failure {
                    Text(failure.message).font(.sh(.caption)).foregroundStyle(Color.sh.failed)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        .accessibilityLabel(failure.stale ? "This project changed. \(failure.message)" : failure.message)
                }
                switch tab {
                case .general: LogicalProjectGeneralTab(vm: vm, ref: ref, project: project, models: models,
                                                        confirmingDelete: $confirmingDelete)
                case .spaces: LogicalProjectSpacesTab(vm: vm, ref: ref, project: project)
                case .memory: LogicalProjectMemoryTab(vm: vm, ref: ref, project: project)
                case .automations: LogicalProjectAutomationsTab(vm: vm, ref: ref, project: project)
                }
            }
            .frame(maxWidth: M.columnWidth, alignment: .leading)
            .padding(.horizontal, SH.Space.xxxl)
            .frame(maxWidth: .infinity)
            .padding(.vertical, SH.Space.xxl)
        }
        .scrollBounceBehavior(.basedOnSize)
        .task(id: ref) { models = await vm.ownerModelIDs(of: ref.home) }
        .sheet(isPresented: $confirmingDelete) {
            DeleteLogicalProjectDialog(vm: vm, ref: ref, project: project) { confirmingDelete = false }
                .dialogSheetFrame()
        }
    }

    /// General, Spaces, Memory, Automations: a 32pt label (12.5, 400) with a 2pt `lantern` rule under the one shown, 6pt apart,
    /// all over a 1pt `lineSubtle` rail.
    private var tabs: some View {
        VStack(spacing: 0) {
            HStack(spacing: SH.Space.s) {
                ForEach(LogicalProjectSettingsTab.allCases) { item in
                    Button { vm.logicalProjectSettingsTab = item } label: {
                        SHProjectSettingsTab(item.rawValue, selected: item == tab)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.rawValue)
                    .accessibilityAddTraits(item == tab ? [.isButton, .isSelected] : .isButton)
                }
                Spacer(minLength: 0)
            }
            SHHairline()
        }
    }
}

// MARK: General

private struct LogicalProjectGeneralTab: View {
    var vm: ShepherdViewModel
    let ref: LogicalProjectRef
    let project: Project
    let models: [String]?
    @Binding var confirmingDelete: Bool
    @State private var goal = ""
    @State private var loaded: UInt64?
    @FocusState private var goalFocused: Bool

    private var model: LogicalProjectsModel { vm.logicalProjects }
    private var settings: LogicalProjectSettings { project.settings }
    private var saving: Bool { model.busy.contains(ref) }

    var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.xl) {
            ProjectSettingsCard {
                ProjectSettingsRow(title: "Goal", subtitle: "One line the project works toward. Optional.") {
                    TextField("", text: $goal)
                        .textFieldStyle(.plain)
                        .font(.sh(.ui, weight: .regular))
                        .foregroundStyle(Color.sh.textPrimary)
                        .tint(Color.sh.lantern)
                        .focused($goalFocused)
                        .padding(.horizontal, SH.Space.l + SHProjectSettingsMetrics.line)
                        .frame(width: SHProjectSettingsMetrics.goalFieldWidth, alignment: .leading)
                        .frame(minHeight: SHProjectSettingsMetrics.fieldHeight)
                        .shProjectSettingsField(focused: goalFocused)
                        .accessibilityLabel("Goal")
                        .onSubmit(commitText)
                }
                ProjectSettingsRow(title: "Conversation model", subtitle: "Plans the work and talks with you.") {
                    ProjectModelField(label: "Conversation model", current: settings.conversationModel, choices: models ?? [],
                                      disabled: saving || models == nil) { choice in
                        Task { _ = await model.saveSettings(ref) { $0.conversationModel = choice } }
                    }
                }
                ProjectSettingsRow(title: "Thread model", subtitle: "Each thread uses it unless the task says otherwise.") {
                    ProjectModelField(label: "Thread model", current: settings.threadModel, choices: models ?? [],
                                      disabled: saving || models == nil) { choice in
                        Task { _ = await model.saveSettings(ref) { $0.threadModel = choice } }
                    }
                }
                ProjectSettingsRow(title: "Threads at once", subtitle: "More wait for a slot. Counts across every host.") {
                    SHProjectSettingsPopup("\(settings.maxConcurrentWorkers)") {
                        ForEach(1...6, id: \.self) { count in
                            Button("\(count)") {
                                guard count != settings.maxConcurrentWorkers else { return }
                                Task { _ = await model.saveSettings(ref) { $0.maxConcurrentWorkers = count } }
                            }
                        }
                    }
                    .disabled(saving)
                    .shHelp("Threads at once")
                    .accessibilityLabel("Threads at once")
                    .accessibilityValue("\(settings.maxConcurrentWorkers)")
                }
            }
            ProjectSettingsCard {
                ProjectSettingsRow(title: "Delete project",
                            subtitle: "Removes the conversation, memory and automations. Threads stay in their spaces; branches and PRs are untouched.") {
                    ProjectSettingsButton(title: "Delete…", danger: true) { confirmingDelete = true }
                        .disabled(saving)
                }
            }
        }
        .onAppear(perform: load)
        // A newer revision from the host replaces what is shown unless the person is typing.
        .onChange(of: project.revision) { load() }
    }

    private func load() {
        guard loaded != project.revision, !goalFocused else { return }
        loaded = project.revision
        goal = project.goal
    }

    /// Goal saves as one revisioned edit, keeping the name the host has. The boards draw no Name field.
    private func commitText() {
        guard goal != project.goal else { return }
        Task { _ = await model.edit(ref, name: project.name, goal: goal) }
    }
}

/// A model preference from the owner's real catalog. "Use the default" clears it; the current value
/// stays listed even when the owner no longer offers it, so it can be seen and changed.
struct ProjectModelField: View {
    let label: String
    let current: String?
    let choices: [String]
    let disabled: Bool
    let choose: (String?) -> Void

    private static let useDefault = "Default"

    var body: some View {
        SHProjectSettingsPopup(current ?? Self.useDefault) {
            Button(Self.useDefault) { choose(nil) }
            Divider()
            ForEach(options, id: \.self) { id in
                Button(id) { choose(id) }
            }
        }
        .disabled(disabled)
        .shHelp(label)
        .accessibilityLabel(label)
        .accessibilityValue(current ?? Self.useDefault)
    }

    private var options: [String] {
        ([current].compactMap { $0 } + choices).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }
}

/// Delete project: the confirmation says what is removed and what stays, truthfully. The host keeps the
/// project's directory and every file in it.
struct DeleteLogicalProjectDialog: View {
    var vm: ShepherdViewModel
    let ref: LogicalProjectRef
    let project: Project
    let dismiss: () -> Void
    @State private var working = false
    @State private var failure: String?

    var body: some View {
        DialogSheet(
            title: "Delete project",
            subtitle: "Removes \(project.name)’s conversation, memory and automations from \(vm.ownerName(of: ref.home)). "
                + "Threads stay in their spaces; branches and pull requests are untouched. "
                + "The project’s files stay on that host: Shepherd does not delete them.",
            status: failure,
            actions: [
                DialogAction("Cancel", kind: .cancel) { if !working { dismiss() } },
                DialogAction(working ? "Deleting…" : "Delete project", kind: .destructive) {
                    working = true
                    failure = nil
                    Task {
                        let ok = await vm.logicalProjects.delete(ref)
                        working = false
                        if ok {
                            if vm.selectedLogicalProject == ref { vm.selectedLogicalProject = nil; vm.destination = nil }
                            dismiss()
                        } else {
                            failure = vm.logicalProjects.failure?.message ?? "The project was not deleted."
                        }
                    }
                },
            ]
        ) { EmptyView() }
    }
}
