import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// Settings ▸ Skills (SettingsSkills, SkillsStates): the agent skills every thread and
/// automation in the fleet can use, kept in each Mac's own pi home (`<support>/pi/skills`, the
/// only folder its pi reads skills from) and the same on every Mac: a change here is made on this
/// Mac and the fleet carries it. A wide page: the installed skills (a filter, All / On /
/// Updates, when This Mac last checked, Update N; a row opens in place, one at a time), then the
/// skills its pi loads from elsewhere, read-only, beside a 280pt rail (how the agent
/// uses skills, what they cost in every prompt, the options, and where they live). Browse skills.sh and
/// Add from repo open sheets.
struct SkillsSettings: View {
    var vm: ShepherdViewModel
    var model: ClientSkills
    @State private var filter: ClientSkills.Filter = .all
    @State private var sheet: SkillsSheet?
    @State private var toast: SHToast?
    @Bindable private var settings = AppSettings.shared
    /// A row open when the page appears (previews draw an open row).
    private let initiallyOpen: String?

    init(vm: ShepherdViewModel, model: ClientSkills, open: String? = nil) {
        self.vm = vm
        self.model = model
        initiallyOpen = open
    }

    @State private var query = ""

    var body: some View {
        let hosts = vm.skillsHosts
        Group {
            if let name = vm.skillsOpenSkill, let row = model.rows(in: hosts, filter: .all, query: "").first(where: { $0.id == name }) {
                SettingsPage(title: row.skill.name) { SkillDetailPage(vm: vm, model: model, hosts: hosts, row: row) }
            } else {
                list(hosts)
            }
        }
        .task { await model.refresh(vm.skillsHosts) }
        .onAppear { if let initiallyOpen { vm.skillsOpenSkill = initiallyOpen } }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .browse:
                SkillsDirectorySheet(vm: vm, model: model, openRepo: { self.sheet = .repo($0) }) { self.sheet = nil }
            case .repo(let repo):
                AddSkillsSheet(vm: vm, model: model, initialRepo: repo) { self.sheet = nil }
            }
        }
        .shToast(item: $toast)
        .onChange(of: model.removal) { _, removal in
            guard let removal else { return }
            vm.skillsOpenSkill = nil
            toast = SHToast(.idle, message: SkillsPresentation.removed(removal), action: .init("Undo") {
                model.undoRemoval(in: vm.skillsHosts)
            })
        }
    }

    private func list(_ hosts: [SkillsHost]) -> some View {
        let rows = model.rows(in: hosts, filter: filter, query: query)
        let groups = model.piGroups(in: hosts, filter: filter, query: query)
        let updates = model.count(.updates, in: hosts)
        return SettingsPage(title: "Skills") {
            if let problem = model.recordsProblem(in: hosts) {
                SHInlineProblem(problem)
            }
            SettingsGroup(title: "Installed", links: [
                SettingsLink("Add from repo") { sheet = .repo(nil) },
                SettingsLink("Browse skills.sh") { sheet = .browse },
            ], lazy: true) {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    SettingsFilterRow(label: "Show", selection: $filter, options: [
                        (.all, "All \(model.count(.all, in: hosts))"),
                        (.on, "On \(model.count(.on, in: hosts))"),
                        (.updates, "Updates \(updates)"),
                    ], search: $query, searchPrompt: "Filter skills", note: SkillsPresentation.checkedLine(model.checkedAt(in: hosts), now: context.date),
                                      buttonTitle: updates > 0 ? "Update \(updates)" : nil) {
                        Task { await model.updateAll(in: vm.skillsHosts) }
                    }
                }
                if rows.isEmpty {
                    SettingsRow(title: emptyMessage(hosts)) { EmptyView() }
                }
                ForEach(rows) { row in
                    SkillListRow(row: row, toggle: { model.setOn(row.name, $0, in: vm.skillsHosts) }, open: { vm.skillsOpenSkill = row.id })
                        .equatable()
                }
            }
            outsideGroups(outsideItems(hosts, groups: groups))
            SettingsGroup(title: "Options", footnote: "Every thread and automation in the fleet gets the same skills.") {
                SettingsRow(title: "Show in the / menu") {
                    SettingsSwitch(label: "Skills in the / menu", isOn: $settings.skillsInSlashMenu)
                }
                SettingsRow(title: "Update automatically") {
                    SettingsSwitch(label: "Update automatically", isOn: Binding(
                        get: { model.autoUpdate(in: hosts) }, set: { model.setAutoUpdate($0, in: vm.skillsHosts) }))
                }
            }
        }
        .shAnimation(.list, value: rows.map(\.id))
    }

    /// The read-only groups: each title with its skills, and the notes and problems pi reported.
    @ViewBuilder private func outsideGroups(_ items: [OutsideItem]) -> some View {
        let groups = Self.split(items)
        ForEach(groups) { group in
            SettingsGroup(title: group.title, footnote: group.notes.first, trailing: group.folder, lazy: true) {
                ForEach(group.skills) { row in
                    PiSkillListRow(row: row, local: group.local, open: { vm.openPiSkillFile(row.skill.path) },
                                   reveal: { vm.showPiSkillFile(row.skill.path) })
                        .equatable()
                        .contextMenu {
                            if group.local {
                                Button("Open SKILL.md") { vm.openPiSkillFile(row.skill.path) }
                                Button("Show in Finder") { vm.showPiSkillFile(row.skill.path) }
                            }
                        }
                }
                ForEach(group.problems, id: \.self) { SettingsRow(title: "", subtitle: nil, problem: $0) { EmptyView() } }
            }
        }
    }

    private struct OutsideGroup: Identifiable {
        var id: String
        var title: String
        var folder: String?
        var local = true
        var skills: [PiSkillRow] = []
        var problems: [String] = []
        var notes: [String] = []
    }

    private static func split(_ items: [OutsideItem]) -> [OutsideGroup] {
        var groups: [OutsideGroup] = []
        for item in items {
            switch item {
            case .group(let title):
                groups.append(OutsideGroup(id: item.id, title: SkillsPresentation.groupTitle(title.kind), folder: title.folder))
            case .skill(let row, let local):
                if groups.isEmpty { groups.append(OutsideGroup(id: "skills", title: "From your pi")) }
                groups[groups.count - 1].skills.append(row)
                groups[groups.count - 1].local = local
            case .problem(let text):
                if groups.isEmpty { groups.append(OutsideGroup(id: "skills", title: "From your pi")) }
                groups[groups.count - 1].problems.append(text)
            case .note(let text):
                if groups.isEmpty { groups.append(OutsideGroup(id: "skills", title: "From your pi")) }
                groups[groups.count - 1].notes.append(text)
            }
        }
        return groups
    }

    private func outsideItems(_ hosts: [SkillsHost], groups: [PiSkillGroup]) -> [OutsideItem] {
        guard let reference = model.reference(in: hosts) else { return [] }
        guard let pi = model.pi(in: hosts) else {
            // This Mac always reports them (tests may not); a remote host too old to says so.
            return reference.id == ShepherdViewModel.thisMacSkills ? [] : [.note(SkillsPresentation.piNotReported(reference.name))]
        }
        let local = pi.host.id == ShepherdViewModel.thisMacSkills
        var items: [OutsideItem] = []
        for group in groups {
            items.append(.group(OutsideGroupTitle(kind: group.kind, count: group.rows.count,
                                                  folder: group.kind == .setup ? pi.skills.agentDirectory + "/skills" : nil,
                                                  opensFolder: local && group.kind == .setup)))
            for row in group.rows {
                items.append(.skill(row, local: local))
            }
        }
        if let problem = pi.skills.problem {
            items.append(.group(OutsideGroupTitle(kind: .setup, count: nil, folder: nil, opensFolder: false)))
            items.append(.problem(SkillsPresentation.piProblem(problem)))
        }
        if filter == .all { items.append(.note(SkillsPresentation.repositorySkillsNote)) }
        return items
    }

    private func emptyMessage(_ hosts: [SkillsHost]) -> String {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty { return "No skill matches “\(query)”." }
        switch filter {
        case .on: return "No skill is on."
        case .updates: return "Every skill is up to date."
        case .all:
            if case .loading = model.state(of: hosts[0]) { return "Reading skills…" }
            return "No skills yet. Browse skills.sh, or add them from a repo."
        }
    }
}

/// The sheets Settings ▸ Skills opens: Browse skills.sh, and Add from repo (with the repository
/// Browse's "Pick from all" names).
enum SkillsSheet: Identifiable, Hashable {
    case browse
    case repo(String?)

    var id: String {
        switch self {
        case .browse: "browse"
        case .repo(let repo): "repo:\(repo ?? "")"
        }
    }
}

/// One line of the list's read-only part: a group's title, one of pi's skills, why pi's skills
/// couldn't be read, or a note.
enum OutsideItem: Identifiable, Equatable {
    case group(OutsideGroupTitle)
    case skill(PiSkillRow, local: Bool)
    case problem(String)
    case note(String)

    var id: String {
        switch self {
        case .group(let title): "group:\(title.kind.rawValue):\(title.count == nil ? "problem" : "")"
        case .skill(let row, _): "skill:\(row.id)"
        case .problem: "problem"
        case .note(let text): "note:\(text)"
        }
    }
}

/// A read-only group's title: its kind, how many it holds, the folder it names, and whether Show
/// folder acts (This Mac's own setup only).
struct OutsideGroupTitle: Equatable {
    let kind: PiSkillGroup.Kind
    let count: Int?
    let folder: String?
    let opensFolder: Bool
}


/// One installed skill in the list. Compares by what it draws, so a switch redraws its own row and no other.
private struct SkillListRow: View, Equatable {
    let row: SkillRow
    let toggle: (Bool) -> Void
    let open: () -> Void

    nonisolated static func == (a: SkillListRow, b: SkillListRow) -> Bool { a.row == b.row }

    var body: some View {
        let _ = SHRenderProbe.tick("skills.row")
        SettingsDrillRow(title: row.skill.name, subtitle: row.skill.summary,
                         value: row.isUpdating ? "Updating" : row.skill.update != nil ? "Update" : nil,
                         valueTone: .note, action: open) {
            Toggle(row.skill.name, isOn: Binding(get: { row.skill.isOn }, set: toggle))
                .toggleStyle(.shSwitch).labelsHidden()
        }
    }
}

/// One of pi's own skills, read-only. Compares by what it draws.
private struct PiSkillListRow: View, Equatable {
    let row: PiSkillRow
    let local: Bool
    let open: () -> Void
    let reveal: () -> Void

    nonisolated static func == (a: Self, b: Self) -> Bool { a.row == b.row && a.local == b.local }

    var body: some View {
        let _ = SHRenderProbe.tick("skills.row")
        SettingsRow(title: row.skill.name, subtitle: row.skill.shadowedBy.map(SkillsPresentation.shadowNote) ?? row.skill.summary) {
            SettingsValue(text: "Read-only")
        }
    }
}

// MARK: A skill's detail

/// An open skill: whether it is on and how the agent may use it, an update, its SKILL.md, and Remove.
private struct SkillDetailPage: View {
    var vm: ShepherdViewModel
    var model: ClientSkills
    let hosts: [SkillsHost]
    let row: SkillRow
    @Environment(\.openURL) private var openURL

    var body: some View {
        let skill = row.skill
        let here = vm.skillFolder(skill.name) != nil
        if let problem = model.recordsProblem(in: hosts) {
            SHInlineProblem(problem)
        }
        SettingsGroup(title: "") {
            SettingsRow(title: "On") {
                SettingsSwitch(label: "On", isOn: Binding(get: { skill.isOn }, set: { model.setOn(skill.name, $0, in: vm.skillsHosts) }))
            }
            SettingsRow(title: "Use it", subtitle: skill.invocation == .automatic
                        ? "The agent picks it up when a task matches" : "Stays out of the prompt until you call it") {
                SHSegmentedPicker("Use it", selection: Binding(get: { skill.invocation },
                                                               set: { model.setInvocation(skill.name, $0, in: vm.skillsHosts) }),
                                  options: [(.automatic, "Automatically"), (.slashOnly, SkillsPresentation.slashOption(skill.name))])
            }
            SettingsRow(title: "Source") {
                SettingsValue(text: SkillsPresentation.source(skill, recordsUnavailable: model.recordsProblem(in: hosts) != nil))
            }
            if let source = skill.source {
                SettingsRow(title: "Installed") {
                    SettingsValue(text: ([String(source.commit.prefix(7))] + (source.committedAt.map { [SkillsPresentation.date($0)] } ?? [])).joined(separator: " · "))
                }
                if let update = skill.update {
                    let newer = SkillsPresentation.newer(update)
                    SettingsRow(title: "New \(newer.commit)", subtitle: newer.detail) {
                        HStack(spacing: AppLayout.settingsControlsSpacing) {
                            if let compare = SkillsText.compareURL(repo: source.repo, from: source.commit, to: update.commit) {
                                Button("What changed") { openURL(compare) }.buttonStyle(.sh(.secondary, size: .s))
                            }
                            Button("Update") { Task { await model.update(skill.name, in: vm.skillsHosts) } }
                                .buttonStyle(.sh(.secondary, size: .s))
                                .disabled(row.isUpdating)
                        }
                    }
                }
            }
        }
        SettingsGroup(title: "Files") {
            ForEach(skill.files) { entry in
                if entry.name == "SKILL.md" {
                    SettingsRow(title: "SKILL.md", subtitle: nil) {
                        HStack(spacing: AppLayout.settingsControlsSpacing) {
                            // A skill has no in-app draft: its SKILL.md is the file, edited where it lives.
                            if let folder = vm.skillFolder(skill.name), here {
                                SHOpenInButton(url: folder.appendingPathComponent("SKILL.md"), actions: .app, size: .settings)
                            }
                            Button("Open") { vm.openSkillFile(skill.name) }.buttonStyle(.sh(.secondary, size: .s)).disabled(!here)
                            Button("Show folder") { vm.showSkillFolder(skill.name) }.buttonStyle(.sh(.secondary, size: .s)).disabled(!here)
                        }
                    }
                }
            }
        }
        SettingsGroup(title: "") {
            SettingsRow(title: "Remove skill", subtitle: "Every Mac drops it") {
                Button("Remove…") { model.remove(skill.name, in: vm.skillsHosts) }
                    .buttonStyle(.sh(.danger, size: .s))
                    .help("Take it off the fleet. Undo puts it back.")
            }
        }
    }
}
