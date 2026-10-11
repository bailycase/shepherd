import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

// The Spaces, Memory and Automations tabs of Project settings. Spaces are the owner's, named by the
// owner's own IDs; this device never resolves them against its own list unless it is the owner.

// MARK: Spaces

struct LogicalProjectSpacesTab: View {
    var vm: ShepherdViewModel
    let ref: LogicalProjectRef
    let project: Project

    @State private var hostOptions: [ProjectHostOption]?
    private var model: LogicalProjectsModel { vm.logicalProjects }
    private var ownerName: String { vm.ownerName(of: ref.home) }
    private var saving: Bool { model.busy.contains(ref.id) }
    /// Each link resolved against its own destination (the owner's Spaces for this Mac, the owner's inventory for a host), never by a
    /// bare SpaceID: see `ProjectSpaceLinks`.
    private var rows: [ProjectSpaceLinks.Row] {
        ProjectSpaceLinks.rows(links: project.linkedSpaces, ownerSpaces: vm.ownerSpaces(of: ref.home), options: hostOptions,
                               ownerName: ownerName, abbreviatesHome: ref.home == .local)
    }
    private var addable: [ProjectSpaceLinks.AddChoice] {
        ProjectSpaceLinks.addChoices(links: project.linkedSpaces, ownerSpaces: vm.ownerSpaces(of: ref.home), options: hostOptions,
                                     ownerName: ownerName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NW.Space.xl) {
            VStack(alignment: .leading, spacing: 0) {
                NWProjectSettingsLabel("Spaces")
                if project.linkedSpaces.isEmpty {
                    emptyCard
                } else {
                    ProjectSettingsCard {
                        ForEach(rows) { row in linkRow(row) }
                    }
                }
                addMenu.padding(.top, NW.Space.m)
            }
            ProjectSettingsCard {
                ProjectSettingsRow(title: "The project can add spaces",
                            subtitle: "When work needs a folder that isn’t here, the project asks in the conversation. With this off it only suggests.") {
                    Toggle("The project can add spaces", isOn: Binding(
                        get: { project.settings.canRequestSpaceLinks },
                        set: { value in Task { _ = await model.saveSettings(ref) { $0.canRequestSpaceLinks = value } } }))
                    .toggleStyle(.nwSwitch)
                    .labelsHidden()
                    .disabled(saving)
                }
                hostsRow
            }
        }
        .task(id: ref) { hostOptions = await model.hostOptions(ref.home) }
    }

    /// Where threads may run, from the owner's own host list. Choosing one saves the policy against the revision shown; nothing
    /// pretends a Space can already be placed on another host before the owner's execution adapter runs there.
    private var hostsRow: some View {
        let hosts = ProjectHostChoices(settings: project.settings, options: hostOptions, ownerName: vm.ownerName(of: ref.home))
        return ProjectSettingsRow(title: "Hosts", subtitle: "Where threads may run. A space must be set up on a host first.") {
            NWProjectSettingsPopup(hosts.current) {
                ForEach(hosts.choices) { choice in
                    Button(choice.title) {
                        guard choice != hosts.selected else { return }
                        Task { _ = await model.saveSettings(ref) { $0.hostPolicy = choice.policy; $0.allowedHosts = choice.allowedHosts } }
                    }
                }
            }
            .disabled(saving)
            .nwHelp("Hosts")
            .accessibilityLabel("Hosts")
            .accessibilityValue(hosts.current)
        }
    }

    private var emptyCard: some View {
        ProjectSettingsCard {
            Text("No spaces yet. Add one, or let the project ask when the work needs a folder.")
                .font(.nw(.ui, weight: .regular)).foregroundStyle(Color.nw.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(ProjectSettingsRowFrame())
        }
    }

    /// "Added by you", or "Added by the project · Oct 9": the link's own provenance and day.
    static func provenance(_ link: ProjectSpaceLink) -> String {
        switch link.provenance {
        case .user: "Added by you"
        case .project: "Added by the project · " + Date(timeIntervalSince1970: link.linkedAt / 1000).formatted(.dateTime.month(.abbreviated).day())
        }
    }

    private func linkRow(_ row: ProjectSpaceLinks.Row) -> some View {
        let M = NWProjectSettingsMetrics.self
        return HStack(spacing: NW.Space.l) {
            Image(systemName: "folder").font(.nwSans(M.rowGlyphSize)).foregroundStyle(Color.nw.textSecondary)
                .frame(width: M.rowGlyphBox, height: M.rowGlyphBox)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: NW.Space.xxs) {
                Text(row.name).font(.nw(.ui)).foregroundStyle(Color.nw.textPrimary).lineLimit(1)
                // `path · host` on one line as the board draws it; when that does not fit, the host takes its own line under the path
                // (which shortens in the middle), so the host that tells two links apart is always read in full.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 0) {
                        if let path = row.path { Text(path + " · ") }
                        Text(row.hostName)
                    }
                    .lineLimit(1).fixedSize()
                    VStack(alignment: .leading, spacing: 0) {
                        if let path = row.path { Text(path).lineLimit(1).truncationMode(.middle) }
                        Text(row.hostName).lineLimit(2)
                    }
                }
                .nwText(size: M.pathSize, mono: true, lineHeight: M.pathLineHeight)
                .foregroundStyle(Color.nw.textTertiary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(row.detail)
            }
            // The text column may shrink to nothing, so a narrow window shortens it instead of widening the card.
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            Text(Self.provenance(row.link)).font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary).lineLimit(1).fixedSize()
            // Remove names the link's own destination: another host's Space with the same ID is a different link and is left alone.
            ProjectSettingsButton(title: "Remove", kind: .ghost) {
                Task { _ = await model.unlink(ref, space: row.link.spaceID, host: row.link.host) }
            }
            .disabled(saving)
            .accessibilityLabel(row.removeLabel)
        }
        .modifier(ProjectSettingsRowFrame())
        .accessibilityElement(children: .contain)
    }

    private var addMenu: some View {
        NWProjectSettingsPopup("Add a space…") {
            ForEach(addable) { choice in
                Button(choice.title) { Task { _ = await model.link(ref, space: choice.space.id, host: choice.host) } }
            }
        }
        .disabled(addable.isEmpty || saving)
        .accessibilityLabel("Add a space…")
        .help(addable.isEmpty ? "Every space on \(ownerName) and its hosts is already added." : "Add a space…")
    }
}

// MARK: Memory

struct LogicalProjectMemoryTab: View {
    var vm: ShepherdViewModel
    let ref: LogicalProjectRef
    let project: Project
    @State private var draft = ""
    @State private var loaded: UInt64?
    @State private var saveTask: Task<Void, Never>?

    private var model: LogicalProjectsModel { vm.logicalProjects }
    private var saving: Bool { model.busy.contains(ref.id) }
    private var limit: Int { Project.maximumInstructionsLength }

    var body: some View {
        let M = NWProjectSettingsMetrics.self
        VStack(alignment: .leading, spacing: NW.Space.xl) {
            VStack(alignment: .leading, spacing: 0) {
                NWProjectSettingsLabel("Project instructions")
                TextEditor(text: $draft)
                    .nwText(size: NWTextStyle.ui.size, lineHeight: NWProjectSettingsMetrics.fieldLineHeight)
                    .foregroundStyle(Color.nw.textPrimary)
                    .tint(Color.nw.lantern)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, M.editorInsetX - M.editorFragmentPadding + M.line)
                    .padding(.vertical, M.editorInsetY + M.line)
                    .frame(minHeight: M.editorMinHeight)
                    .nwProjectSettingsField()
                    .accessibilityLabel("Project instructions")
                    .disabled(saving)
                Text("Sent to the conversation and to every new thread, after each space’s AGENTS.md. \(draft.count.formatted()) of \(limit.formatted()) characters.")
                    .nwText(size: NWTextStyle.caption.size, lineHeight: NWCardRowMetrics.settingsDescriptionLineHeight)
                    .foregroundStyle(draft.count > limit ? Color.nw.failed : Color.nw.textTertiary)
                    .frame(minHeight: NWTextStyle.caption.size * NWCardRowMetrics.settingsDescriptionLineHeight, alignment: .top)
                    .padding(.top, NW.Space.s + M.editorFootnoteGap)
                    .accessibilityLabel("\(draft.count) of \(limit) characters")
                if draft != project.settings.instructions {
                    HStack(spacing: NW.Space.s) {
                        Button("Save") { save() }
                            .buttonStyle(.nw(.primary))
                            .disabled(saving || draft.count > limit)
                        Button("Revert") { draft = project.settings.instructions }
                            .buttonStyle(.nw(.ghost))
                            .disabled(saving)
                    }
                    .padding(.top, NW.Space.m)
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                NWProjectSettingsLabel("What the project remembers")
                if project.memory.isEmpty {
                    ProjectSettingsCard {
                        Text("Nothing yet. What you decide and what the project learns is kept here, and you can make it forget any of it.")
                            .font(.nw(.ui, weight: .regular)).foregroundStyle(Color.nw.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .modifier(ProjectSettingsRowFrame())
                    }
                } else {
                    ProjectSettingsCard {
                        ForEach(project.memory) { entry in memoryRow(entry) }
                    }
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: project.revision) { load() }
    }

    private func memoryRow(_ entry: ProjectMemory) -> some View {
        HStack(spacing: NW.Space.l) {
            Text(entry.text)
                .nwText(size: NWTextStyle.ui.size, lineHeight: NWProjectSettingsMetrics.memoryLineHeight)
                .foregroundStyle(Color.nw.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            ProjectSettingsButton(title: "Forget", kind: .ghost) { Task { _ = await model.forget(ref, memory: entry.id) } }
                .disabled(saving)
                .accessibilityLabel("Forget: \(entry.text)")
        }
        .modifier(ProjectSettingsRowFrame())
        .accessibilityElement(children: .contain)
    }

    /// A newer revision replaces the text only while there are no unsaved edits, so typing is never overwritten.
    private func load() {
        guard loaded != project.revision else { return }
        let clean = draft == (loaded == nil ? draft : lastSaved)
        if loaded == nil || clean { draft = project.settings.instructions }
        loaded = project.revision
        lastSaved = project.settings.instructions
    }

    @State private var lastSaved = ""

    private func save() {
        let text = draft
        Task { _ = await model.saveSettings(ref) { $0.instructions = text } }
    }
}

// MARK: Automations

/// Project automations (ProjectLead-SettingsAutomations): each saved automation the owner associates with this Project, with a
/// switch that is a revisioned `setEnabled` through the owner. The caption is only what the record and its run log hold: the
/// first line of its prompt, where it works, the owner, and its newest real run (word and age). The records store no schedule
/// or trigger, so none is drawn; no run read means no run word, never a made-up success.
struct LogicalProjectAutomationsTab: View {
    var vm: ShepherdViewModel
    let ref: LogicalProjectRef
    let project: Project

    private var model: LogicalProjectsModel { vm.logicalProjects }
    private var saving: Bool { model.busy.contains(ref.id) }
    private var rows: [ProjectAutomationSnapshot] {
        let host: AutomationHost
        switch ref.home {
        case .local: host = AutomationHost(id: PageHost.localID, name: vm.ownerName(of: .local), connected: true, manageable: true, state: vm.state)
        case .host(let id):
            guard let connection = vm.remoteHosts.connections.first(where: { $0.id == id }) else { return [] }
            host = AutomationHost(id: id, name: connection.config.name, connected: connection.phase == .connected,
                                  manageable: connection.supportsLogicalProjectAutomations, state: connection.state)
        }
        let runs = Dictionary(uniqueKeysWithValues: vm.automationRunsByKey.compactMap { key, value in
            key.host == host.id ? (key.automation, value) : nil
        })
        return ProjectAutomationSnapshot.rows(projectID: ref.id, host: host, runs: runs)
    }

    var body: some View {
        ProjectSettingsCard {
            if rows.isEmpty {
                VStack(alignment: .leading, spacing: NW.Space.xxs) {
                    Text("No automations yet").font(.nw(.ui)).foregroundStyle(Color.nw.textPrimary)
                    Text("Automations that belong to \(project.name) show here with a switch for each.")
                        .font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(ProjectSettingsRowFrame())
            } else {
                ForEach(rows) { row in automationRow(row) }
            }
        }
        .task(id: vm.automationRunsSignature) { await vm.loadAutomationPageRuns() }
    }

    private func automationRow(_ row: ProjectAutomationSnapshot) -> some View {
        let M = NWProjectSettingsMetrics.self
        return HStack(spacing: NW.Space.l) {
            NWGlyph.automation.image.font(.nwSans(M.rowGlyphSize)).foregroundStyle(Color.nw.textSecondary)
                .frame(width: M.rowGlyphBox, height: M.rowGlyphBox)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: NW.Space.xxs) {
                Text(row.automation.name).font(.nw(.ui)).foregroundStyle(Color.nw.textPrimary).lineLimit(1)
                Text(Self.caption(row, space: vm.ownerSpaces(of: ref.home).first { $0.path == row.automation.cwd }?.name))
                    .nwText(size: NWTextStyle.caption.size, lineHeight: NWCardRowMetrics.settingsDescriptionLineHeight)
                    .foregroundStyle(Color.nw.textTertiary).lineLimit(1).truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("Run \(row.automation.name)", isOn: Binding(
                get: { row.automation.enabled },
                set: { value in Task { _ = await model.automation(ref, row.automation.id, .setEnabled(value)) } }))
            .toggleStyle(.nwSwitch)
            .labelsHidden()
            .disabled(saving)
        }
        .modifier(ProjectSettingsRowFrame())
        .accessibilityElement(children: .contain)
    }

    /// "<prompt's first line> · <space> · <owner> · <run word> · <age>": each part only if the record or its run log has it.
    static func caption(_ row: ProjectAutomationSnapshot, space: String? = nil) -> String {
        var parts: [String] = []
        let line = row.automation.prompt.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        if !line.isEmpty { parts.append(line) }
        if let space { parts.append(space) }
        parts.append(row.ownerName)
        if let run = row.latestRun {
            parts.append(AutomationsModel.word(run.result))
            parts.append(LogicalProjectPane.age(run.startedAt * 1000) + " ago")
        } else {
            parts.append("never run")
        }
        return parts.joined(separator: " · ")
    }
}
