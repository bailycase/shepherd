import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// Settings ▸ Skills (SettingsSkills, SkillsStates): the agent skills every thread and
/// automation on every host can use, kept in each host's ~/.agents/skills. A wide page: the
/// installed skills (a filter, All / On / Updates, when This Mac last checked, Update N; a row
/// opens in place, one at a time), then read-only the skills pi loads from the user's own pi setup
/// and from pi packages (the user's decision of 2026-09-26), beside a 280pt rail (how the agent
/// uses skills, what they cost in every prompt, the options, and each host). Browse skills.sh and
/// Add from repo open sheets.
struct SkillsSettings: View {
    var vm: ShepherdViewModel
    var model: ClientSkills
    @State private var filter: ClientSkills.Filter = .all
    @State private var query = ""
    @State private var expanded: String?
    @State private var sheet: SkillsSheet?
    @State private var toast: NWToast?

    var body: some View {
        let hosts = vm.skillsHosts
        let rows = model.rows(in: hosts, filter: filter, query: query)
        let groups = model.piGroups(in: hosts, filter: filter, query: query)
        VStack(alignment: .leading, spacing: AppLayout.skillsBlockSpacing) {
            header
            HStack(alignment: .top, spacing: AppLayout.skillsColumnSpacing) {
                VStack(alignment: .leading, spacing: NW.Space.l) {
                    toolbar(hosts)
                    if let problem = model.problem {
                        HStack(spacing: NW.Space.m) {
                            NWInlineProblem(problem)
                            Button("Dismiss") { model.dismissProblem() }.buttonStyle(.nwLink)
                        }
                        .nwTransition(.disclosure)
                    }
                    ScrollView(.vertical) {
                        SkillsList(vm: vm, model: model, hosts: hosts, rows: rows,
                                   showsInstalled: !rows.isEmpty || groups.isEmpty || (filter == .all && query.isEmpty),
                                   outside: outsideItems(hosts, groups: groups), expanded: $expanded,
                                   empty: emptyMessage(hosts))
                    }
                    .scrollIndicators(.hidden)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ScrollView(.vertical) {
                    SkillsRail(vm: vm, model: model, hosts: hosts)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)
                .frame(width: AppLayout.skillsRailWidth)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .nwAnimation(.disclosure, value: expanded)
        .nwAnimation(.list, value: rows.map(\.id))
        .nwAnimation(.list, value: groups.map { $0.rows.map(\.id) })
        .nwAnimation(.disclosure, value: model.problem)
        .task { await model.refresh(vm.skillsHosts) }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .browse:
                SkillsDirectorySheet(vm: vm, model: model, openRepo: { self.sheet = .repo($0) }) { self.sheet = nil }
            case .repo(let repo):
                AddSkillsSheet(vm: vm, model: model, initialRepo: repo) { self.sheet = nil }
            }
        }
        .nwToast(item: $toast)
        .onChange(of: model.removal) { _, removal in
            guard let removal else { return }
            toast = NWToast(.idle, message: SkillsPresentation.removed(removal), action: .init("Undo") {
                model.undoRemoval(in: vm.skillsHosts)
            })
        }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: NW.Space.xl) {
            SettingsHeader(title: "Skills",
                           explanation: "Instructions and scripts the agent picks up when a task calls for them. Installed skills are "
                               + "global: every thread and automation on every host gets the same set. Skills from your pi setup "
                               + "and pi packages are listed read-only.")
                .frame(maxWidth: AppLayout.skillsExplanationWidth, alignment: .leading)
            Spacer(minLength: NW.Space.l)
            HStack(spacing: NW.Space.m) {
                Button { sheet = .repo(nil) } label: { Label("Add from repo…", systemImage: "plus") }
                    .buttonStyle(.nw(.secondary))
                Button { sheet = .browse } label: { Label("Browse skills.sh", systemImage: "magnifyingglass") }
                    .buttonStyle(.nw(.primary))
            }
            .fixedSize()
        }
    }

    private func toolbar(_ hosts: [SkillsHost]) -> some View {
        let updates = model.count(.updates, in: hosts)
        return HStack(spacing: NW.Space.m + NW.Space.xxs) {
            NWSearchField("Filter skills", text: $query)
                .frame(width: AppLayout.skillsFilterWidth)
            NWSegmentedPicker("Show", selection: $filter, options: [
                (.all, "All \(model.count(.all, in: hosts))"),
                (.on, "On \(model.count(.on, in: hosts))"),
                (.updates, "Updates \(updates)"),
            ])
            Spacer(minLength: NW.Space.m)
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text(SkillsPresentation.checkedLine(model.checkedAt(in: hosts), now: context.date))
                    .font(.nwSans(AppLayout.skillsNoteSize))
                    .foregroundStyle(Color.nw.textTertiary)
                    .lineLimit(1)
            }
            if updates > 0 {
                Button { Task { await model.updateAll(in: vm.skillsHosts) } } label: {
                    Label("Update \(updates)", systemImage: "arrow.down.to.line")
                }
                .buttonStyle(.nw(.secondary, size: .s))
                .nwTransition(.disclosure)
            }
        }
        .nwAnimation(.disclosure, value: updates > 0)
    }

    /// The read-only part of the list: each group's title and rows, why pi's skills couldn't be
    /// read, and where a repository's own skills are.
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

// MARK: The list

/// The installed skills: a header, then a row per skill; the open one shows its detail below it.
/// The lazy stack is the scroll view's own content, header included, so opening the page builds
/// only the rows in view.
private struct SkillsList: View {
    var vm: ShepherdViewModel
    var model: ClientSkills
    let hosts: [SkillsHost]
    let rows: [SkillRow]
    /// Whether the Installed group shows: always unfiltered, else only while it keeps a row or
    /// nothing else does.
    let showsInstalled: Bool
    let outside: [OutsideItem]
    @Binding var expanded: String?
    let empty: String

    var body: some View {
        let nw = Color.nw
        LazyVStack(spacing: 0) {
            SkillsListHeader()
            if showsInstalled {
                SkillsGroupTitle(title: "Installed", count: rows.count, trailing: model.directory(in: hosts), readOnly: false,
                                 rule: false, help: "Shepherd installs, updates and removes these, on every host.", open: nil)
                    .equatable()
                if rows.isEmpty {
                    Text(empty)
                        .font(.nwSans(AppLayout.skillsSummarySize))
                        .foregroundStyle(nw.textTertiary)
                        .frame(maxWidth: .infinity, minHeight: AppLayout.skillsRowMinHeight)
                        .overlay(alignment: .top) { NWHairline() }
                        .nwTransition(.disclosure)
                }
                ForEach(rows) { row in
                    let open = expanded == row.id
                    VStack(spacing: 0) {
                        SkillsListRow(row: row, open: open, actions: actions(for: row))
                            .equatable()
                        if open {
                            SkillDetail(vm: vm, model: model, hosts: hosts, row: row)
                                .nwTransition(.disclosure)
                        }
                    }
                }
            }
            ForEach(outside) { item in
                VStack(spacing: 0) {
                    switch item {
                    case .group(let title):
                        SkillsGroupTitle(title: SkillsPresentation.groupTitle(title.kind), count: title.count, trailing: title.folder,
                                         readOnly: true, rule: showsInstalled || item.id != outside.first?.id,
                                         help: SkillsPresentation.groupNote(title.kind),
                                         open: title.opensFolder ? { vm.showPiSkillsFolder() } : nil)
                            .equatable()
                    case .skill(let row, let local):
                        PiSkillsListRow(row: row, actions: local ? piActions(for: row) : nil)
                            .equatable()
                    case .problem(let text):
                        NWInlineProblem(text)
                            .frame(maxWidth: .infinity, minHeight: AppLayout.skillsRowMinHeight, alignment: .leading)
                            .padding(.horizontal, NW.Space.xl)
                            .overlay(alignment: .top) { NWHairline() }
                    case .note(let text):
                        Text(text)
                            .nwText(size: AppLayout.skillsNoteSize, lineHeight: AppLayout.skillsNoteLineHeight)
                            .foregroundStyle(nw.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, NW.Space.l)
                            .padding(.horizontal, NW.Space.xl)
                            .background(nw.bgSunken)
                            .overlay(alignment: .top) { NWHairline() }
                    }
                }
            }
        }
        .background(nw.bgWindow)
        .clipShape(RoundedRectangle(cornerRadius: AppLayout.skillsCardRadius))
        .nwBorder(nw.lineSubtle, radius: AppLayout.skillsCardRadius)
    }

    private func actions(for row: SkillRow) -> SkillsListRow.Actions {
        SkillsListRow.Actions(
            toggle: { on in model.setOn(row.name, on, in: vm.skillsHosts) },
            open: { expanded = expanded == row.id ? nil : row.id },
            update: { Task { await model.update(row.name, in: vm.skillsHosts) } })
    }

    private func piActions(for row: PiSkillRow) -> PiSkillsListRow.Actions {
        PiSkillsListRow.Actions(open: { vm.openPiSkillFile(row.skill.path) }, reveal: { vm.showPiSkillFile(row.skill.path) })
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

/// A group's title row: "Installed 8", "From your pi setup 3" with a lock (read-only), and the
/// folder or Show folder trailing.
private struct SkillsGroupTitle: View, Equatable {
    let title: String
    let count: Int?
    let trailing: String?
    let readOnly: Bool
    /// A hairline above: every title but one straight under the column labels.
    let rule: Bool
    let help: String
    let open: (() -> Void)?

    nonisolated static func == (a: SkillsGroupTitle, b: SkillsGroupTitle) -> Bool {
        a.title == b.title && a.count == b.count && a.trailing == b.trailing && a.readOnly == b.readOnly && a.rule == b.rule
            && (a.open == nil) == (b.open == nil)
    }

    var body: some View {
        let nw = Color.nw
        HStack(spacing: NW.Space.s) {
            if readOnly {
                Image(systemName: "lock")
                    .font(.nwSans(AppLayout.skillsLabelSize, .semibold))
                    .foregroundStyle(nw.textTertiary)
                    .frame(width: AppLayout.skillsSwitchColumn)
                    .padding(.trailing, AppLayout.skillsColumnGap - NW.Space.s)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.nwSans(AppLayout.skillsNoteSize, .semibold))
                .foregroundStyle(nw.textSecondary)
                .lineLimit(1)
            if let count {
                Text("\(count)")
                    .font(.nwMono(AppLayout.skillsMetaSize))
                    .foregroundStyle(nw.textTertiary)
            }
            Spacer(minLength: NW.Space.m)
            if let trailing {
                Text(trailing)
                    .font(.nwMono(AppLayout.skillsMetaSize - 0.5))
                    .foregroundStyle(nw.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let open {
                Button("Show folder", action: open)
                    .buttonStyle(.nw(.ghost, size: .s))
                    .help("Show pi’s skills folder in Finder")
            }
        }
        .padding(.horizontal, NW.Space.xl)
        .frame(minHeight: AppLayout.skillsGroupHeight)
        .overlay(alignment: .top) { if rule { NWHairline() } }
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One of the skills pi loads from outside Shepherd's folder: read-only, with no switch (a lock
/// in its column), its name and description, where it comes from, and how it's used. One a
/// skill of the same name shadows says "not used". On This Mac, its menu opens its SKILL.md or
/// shows it in Finder.
private struct PiSkillsListRow: View, Equatable {
    struct Actions {
        let open: () -> Void
        let reveal: () -> Void
    }

    let row: PiSkillRow
    let actions: Actions?

    nonisolated static func == (a: PiSkillsListRow, b: PiSkillsListRow) -> Bool {
        a.row == b.row && (a.actions == nil) == (b.actions == nil)
    }

    var body: some View {
        let _ = NWRenderProbe.tick("skills.row")
        let nw = Color.nw
        let skill = row.skill
        HStack(spacing: AppLayout.skillsColumnGap) {
            Color.clear.frame(width: AppLayout.skillsSwitchColumn)
            VStack(alignment: .leading, spacing: NW.Space.xxs + 1) {
                HStack(spacing: NW.Space.s) {
                    Text(skill.name)
                        .font(.nwMono(AppLayout.skillsNameSize, .semibold))
                        .foregroundStyle(skill.isUsed ? nw.textPrimary : nw.textSecondary)
                        .lineLimit(1)
                    if !skill.isUsed { NWTag("not used") }
                }
                Text(skill.shadowedBy.map(SkillsPresentation.shadowNote) ?? skill.summary)
                    .font(.nwSans(AppLayout.skillsSummarySize))
                    .foregroundStyle(skill.isUsed ? nw.textSecondary : nw.textTertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(SkillsPresentation.source(skill))
                .font(.nwMono(AppLayout.skillsMetaSize))
                .foregroundStyle(nw.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(skill.path)
                .frame(width: AppLayout.skillsSourceColumn, alignment: .leading)
            SkillUseTag(invocation: skill.invocation)
                .frame(width: AppLayout.skillsUseColumn, alignment: .leading)
            Color.clear.frame(width: AppLayout.skillsUpdatedColumn + AppLayout.skillsColumnGap + AppLayout.skillsChevronColumn)
        }
        .padding(.vertical, NW.Space.m)
        .padding(.horizontal, NW.Space.xl)
        .frame(minHeight: AppLayout.skillsRowMinHeight)
        .overlay(alignment: .top) { NWHairline() }
        .contentShape(Rectangle())
        .help(skill.shadowedBy.map { _ in skill.summary } ?? "")
        .contextMenu {
            if let actions {
                Button("Open SKILL.md", action: actions.open)
                Button("Show in Finder", action: actions.reveal)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The Use column: "Auto" in a bordered tag, or "/skill only" in mono on `bgSelected`.
private struct SkillUseTag: View {
    let invocation: SkillInvocation

    var body: some View {
        let nw = Color.nw
        let text = Text(SkillsPresentation.use(invocation)).lineLimit(1)
        if invocation == .automatic {
            text.font(.nwSans(AppLayout.skillsMetaSize))
                .foregroundStyle(nw.textSecondary)
                .padding(.horizontal, NW.Space.s + 1)
                .frame(height: AppLayout.skillsTagHeight)
                .nwBorder(nw.lineStrong, radius: NW.Radius.xs)
                .fixedSize()
        } else {
            text.font(.nwMono(AppLayout.skillsMetaSize - 0.5))
                .foregroundStyle(nw.textSecondary)
                .padding(.horizontal, NW.Space.s + 1)
                .frame(height: AppLayout.skillsTagHeight)
                .background(nw.bgSelected, in: RoundedRectangle(cornerRadius: NW.Radius.xs))
                .fixedSize()
        }
    }
}

/// The list's column labels.
private struct SkillsListHeader: View {
    var body: some View {
        let nw = Color.nw
        HStack(spacing: AppLayout.skillsColumnGap) {
            Color.clear.frame(width: AppLayout.skillsSwitchColumn)
            label("Skill").frame(maxWidth: .infinity, alignment: .leading)
            label("Source").frame(width: AppLayout.skillsSourceColumn, alignment: .leading)
            label("Use").frame(width: AppLayout.skillsUseColumn, alignment: .leading)
            label("Updated").frame(width: AppLayout.skillsUpdatedColumn, alignment: .leading)
            Color.clear.frame(width: AppLayout.skillsChevronColumn)
        }
        .padding(.horizontal, NW.Space.xl)
        .frame(height: AppLayout.skillsHeaderHeight)
        .background(nw.bgSunken)
        .overlay(alignment: .bottom) { NWHairline() }
        .accessibilityHidden(true)
    }

    private func label(_ text: String) -> some View {
        Text(text).nwSettingsLabel(table: true).lineLimit(1)
    }
}

/// One installed skill: its switch, name and description, source, how it's used, and when it
/// last changed, an Update pill, or Updating while one is on its way. Clicking it opens its
/// detail. Compares equal unless what it draws changed.
private struct SkillsListRow: View, Equatable {
    struct Actions {
        let toggle: (Bool) -> Void
        let open: () -> Void
        let update: () -> Void
    }

    let row: SkillRow
    let open: Bool
    let actions: Actions
    @State private var hovering = false

    nonisolated static func == (a: SkillsListRow, b: SkillsListRow) -> Bool {
        a.row == b.row && a.open == b.open
    }

    var body: some View {
        let _ = NWRenderProbe.tick("skills.row")
        let nw = Color.nw
        let skill = row.skill
        HStack(spacing: AppLayout.skillsColumnGap) {
            Toggle(skill.name, isOn: Binding(get: { skill.isOn }, set: actions.toggle))
                .toggleStyle(.nwSwitch)
                .labelsHidden()
                .frame(width: AppLayout.skillsSwitchColumn)
            VStack(alignment: .leading, spacing: NW.Space.xxs + 1) {
                HStack(spacing: NW.Space.s) {
                    Text(skill.name)
                        .font(.nwMono(AppLayout.skillsNameSize, .semibold))
                        .foregroundStyle(skill.isOn && row.shadowedBy == nil ? nw.textPrimary : nw.textSecondary)
                        .lineLimit(1)
                    if let winner = row.shadowedBy {
                        NWTag("not used").help(SkillsPresentation.shadowNote(winner))
                    }
                }
                Text(skill.summary)
                    .font(.nwSans(AppLayout.skillsSummarySize))
                    .foregroundStyle(nw.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            source(skill).frame(width: AppLayout.skillsSourceColumn, alignment: .leading)
            SkillUseTag(invocation: skill.invocation).frame(width: AppLayout.skillsUseColumn, alignment: .leading)
            updated.frame(width: AppLayout.skillsUpdatedColumn, alignment: .leading)
            Image(systemName: open ? "chevron.down" : "chevron.right")
                .font(.nwSans(AppLayout.skillsMetaSize, .semibold))
                .foregroundStyle(nw.textTertiary)
                .frame(width: AppLayout.skillsChevronColumn)
                .accessibilityHidden(true)
        }
        .padding(.vertical, NW.Space.m)
        .padding(.horizontal, NW.Space.xl)
        .frame(minHeight: AppLayout.skillsRowMinHeight)
        .background(open || hovering ? nw.bgHover : Color.clear)
        .overlay(alignment: .top) { NWHairline() }
        .contentShape(Rectangle())
        .onTapGesture(perform: actions.open)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: open ? "Close" : "Open", actions.open)
    }

    @ViewBuilder private func source(_ skill: InstalledSkill) -> some View {
        let nw = Color.nw
        if let source = skill.source {
            Text(source.repo)
                .font(.nwMono(AppLayout.skillsMetaSize))
                .foregroundStyle(nw.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        } else {
            Label("Local", systemImage: "folder")
                .font(.nwSans(AppLayout.skillsNoteSize))
                .foregroundStyle(nw.textTertiary)
                .labelStyle(.titleAndIcon)
                .help("Copied into ~/.agents/skills by hand. It never updates.")
        }
    }

    @ViewBuilder private var updated: some View {
        if row.isUpdating {
            Text("Updating")
                .font(.nwSans(AppLayout.skillsMetaSize, .medium))
                .nwShimmer(active: true)
                .lineLimit(1)
        } else if row.skill.update != nil {
            Button(action: actions.update) { NWUpdatePill() }
                .buttonStyle(.plain)
                .help("Install the newer commit on every host")
        } else {
            Text(SkillsPresentation.date(row.skill.updatedAt))
                .font(.nwMono(AppLayout.skillsMetaSize))
                .foregroundStyle(Color.nw.textTertiary)
                .lineLimit(1)
        }
    }
}

// MARK: A skill's detail

/// An open row: how the agent may use the skill, its version, where each host is with it, and
/// its files, with Open SKILL.md, Show folder and Remove.
private struct SkillDetail: View {
    var vm: ShepherdViewModel
    var model: ClientSkills
    let hosts: [SkillsHost]
    let row: SkillRow
    @Environment(\.openURL) private var openURL

    var body: some View {
        let nw = Color.nw
        let skill = row.skill
        VStack(alignment: .leading, spacing: AppLayout.skillsDetailSpacing) {
            HStack(alignment: .top, spacing: AppLayout.skillsDetailColumnSpacing) {
                block("Use it") {
                    VStack(alignment: .leading, spacing: NW.Space.m + NW.Space.xxs) {
                        NWRadioOption("Automatically", note: SkillsPresentation.automaticNote(skill, directory: model.directory(in: hosts)),
                                      selected: skill.invocation == .automatic) {
                            model.setInvocation(skill.name, .automatic, in: vm.skillsHosts)
                        }
                        NWRadioOption(SkillsPresentation.slashOption(skill.name), note: "Stays out of the agent’s prompt until you call it.",
                                      selected: skill.invocation == .slashOnly) {
                            model.setInvocation(skill.name, .slashOnly, in: vm.skillsHosts)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                block("Version") { version(skill) }
                    .frame(maxWidth: .infinity, alignment: .leading)
                block("Hosts") {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(model.copies(of: skill.name, in: hosts)) { copy in
                            NWHostStateRow(copy.name, detail: SkillsPresentation.copy(copy.state), mark: Self.mark(copy.state))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: NW.Space.s) {
                ForEach(skill.files) { entry in
                    NWSkillFileChip(SkillsPresentation.chip(entry), count: entry.isDirectory ? entry.fileCount : nil,
                                    kind: entry.isDirectory ? (entry.name == "scripts" ? .code : .folder) : .file)
                }
                Spacer(minLength: NW.Space.m)
                let here = vm.skillFolder(skill.name) != nil
                Button("Open SKILL.md") { vm.openSkillFile(skill.name) }
                    .buttonStyle(.nw(.secondary, size: .s))
                    .disabled(!here)
                Button("Show folder") { vm.showSkillFolder(skill.name) }
                    .buttonStyle(.nw(.ghost, size: .s))
                    .disabled(!here)
                Button("Remove") { model.remove(skill.name, in: vm.skillsHosts) }
                    .buttonStyle(.nw(.danger, size: .s))
                    .help("Take it off every host. Undo puts it back.")
            }
            .padding(.top, AppLayout.skillsDetailSpacing)
            .overlay(alignment: .top) { NWHairline() }
        }
        .padding(.vertical, AppLayout.skillsDetailSpacing)
        .padding(.leading, AppLayout.skillsDetailLeading)
        .padding(.trailing, NW.Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(nw.bgSunken)
        .overlay(alignment: .top) { NWHairline() }
    }

    @ViewBuilder private func version(_ skill: InstalledSkill) -> some View {
        let nw = Color.nw
        VStack(alignment: .leading, spacing: NW.Space.s) {
            if let source = skill.source {
                let repo = Text(source.repo).foregroundStyle(nw.textSecondary)
                let path = Text(source.path.isEmpty ? "" : " › \(source.path)").foregroundStyle(nw.textTertiary)
                Text("\(repo)\(path)")
                    .font(.nwMono(AppLayout.skillsDetailTextSize))
                    .lineLimit(1)
                    .truncationMode(.middle)
                VStack(alignment: .leading, spacing: NW.Space.xxs + 1) {
                    let installed = SkillsPresentation.installed(source)
                    let installedCommit = Text(installed.commit).font(.nwMono(AppLayout.skillsDetailTextSize)).foregroundStyle(nw.textSecondary)
                    let when = installed.date.map { " · " + $0 } ?? ""
                    Text("Installed \(installedCommit)\(when)")
                        .foregroundStyle(nw.textTertiary)
                    if let update = skill.update {
                        let newer = SkillsPresentation.newer(update)
                        let newCommit = Text(newer.commit).font(.nwMono(AppLayout.skillsDetailTextSize))
                        Text("New \(newCommit) · \(newer.detail)")
                            .foregroundStyle(nw.lanternText)
                    }
                }
                .font(.nwSans(AppLayout.skillsDetailTextSize))
                if let update = skill.update {
                    HStack(spacing: NW.Space.s) {
                        Button { Task { await model.update(skill.name, in: vm.skillsHosts) } } label: {
                            Label("Update", systemImage: "arrow.down.to.line")
                        }
                        .buttonStyle(.nw(.primary, size: .s))
                        .disabled(row.isUpdating)
                        if let compare = SkillsText.compareURL(repo: source.repo, from: source.commit, to: update.commit) {
                            Button("What changed") { openURL(compare) }
                                .buttonStyle(.nw(.ghost, size: .s))
                                .help("Opens the comparison on GitHub")
                        }
                    }
                }
            } else {
                Label("Local", systemImage: "folder")
                    .font(.nwSans(AppLayout.skillsDetailTextSize))
                    .foregroundStyle(nw.textSecondary)
                Text("Copied into the skills folder by hand. It never updates.")
                    .nwText(size: AppLayout.skillsNoteSize, lineHeight: AppLayout.skillsNoteLineHeight)
                    .foregroundStyle(nw.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func block<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: NW.Space.m) {
            Text(title).nwSettingsLabel(table: true)
            content()
        }
    }

    static func mark(_ state: SkillCopy.State) -> NWHostStateRow.Mark {
        switch state {
        case .installed: .done
        case .updating: .working
        case .owed, .offline: .offline
        case .missing, .unsupported, .checking: .none
        }
    }
}

// MARK: The rail

/// How the agent uses skills, what the automatic ones cost in every prompt, the options, and
/// each host.
private struct SkillsRail: View {
    var vm: ShepherdViewModel
    var model: ClientSkills
    let hosts: [SkillsHost]
    @Bindable private var settings = AppSettings.shared

    init(vm: ShepherdViewModel, model: ClientSkills, hosts: [SkillsHost]) {
        self.vm = vm
        self.model = model
        self.hosts = hosts
    }

    var body: some View {
        let nw = Color.nw
        let loaded = model.loadedSkills(in: hosts)
        VStack(alignment: .leading, spacing: AppLayout.skillsRailSpacing) {
            VStack(alignment: .leading, spacing: NW.Space.m) {
                NWSectionHeader("How the agent uses them", style: .settings).padding(.horizontal, NW.Space.xxs)
                let command = Text("/skill:name").font(.nwMono(AppLayout.skillsRailTextSize - 0.5)).foregroundStyle(nw.textPrimary)
                // One literal, so `command` is interpolated as styled text.
                Text("The agent sees the name and description of every automatic skill. When a task matches one, it reads that skill’s files and follows them. Type \(command) to use one on purpose.")
                    .nwText(size: AppLayout.skillsRailTextSize, lineHeight: AppLayout.skillsRailLineHeight)
                    .foregroundStyle(nw.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, NW.Space.xxs)
                VStack(alignment: .leading, spacing: NW.Space.m) {
                    HStack {
                        Text("In every prompt")
                            .font(.nwSans(AppLayout.skillsOptionTitleSize, .medium))
                            .foregroundStyle(nw.textPrimary)
                        Spacer(minLength: NW.Space.m)
                        Text(SkillsText.tokenNote(model.promptTokens(in: hosts)))
                            .font(.nwMono(AppLayout.skillsNoteSize))
                            .foregroundStyle(nw.textSecondary)
                    }
                    NWBudgetBar(loaded.map { $0.invocation == .automatic })
                    Text(SkillsPresentation.automaticCount(loaded.filter { $0.invocation == .automatic }.count))
                        .nwText(size: AppLayout.skillsNoteSize, lineHeight: AppLayout.skillsNoteLineHeight)
                        .foregroundStyle(nw.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, NW.Space.l)
                .padding(.horizontal, NW.Space.l + NW.Space.xxs)
                .background(nw.bgWindow, in: RoundedRectangle(cornerRadius: AppLayout.skillsCardRadius))
                .nwBorder(nw.lineSubtle, radius: AppLayout.skillsCardRadius)
                .help("The context meter counts this as part of the system prompt.")
            }
            VStack(alignment: .leading, spacing: 0) {
                NWSectionHeader("Options", style: .settings).padding(.horizontal, NW.Space.xxs).padding(.bottom, NW.Space.m)
                option("Skills in the / menu", note: "List every skill as /skill:name in the composer’s slash menu.",
                       isOn: $settings.skillsInSlashMenu)
                option("Same skills on every host", note: "Installs, updates and removals go to all hosts. Offline hosts catch up.",
                       isOn: Binding(get: { model.sameEverywhere }, set: { model.sameEverywhere = $0 }))
                option("Update automatically", note: "Off: new versions wait here with an Update badge.",
                       isOn: Binding(get: { model.autoUpdate(in: hosts) }, set: { model.setAutoUpdate($0, in: vm.skillsHosts) }))
            }
            VStack(alignment: .leading, spacing: NW.Space.s) {
                NWSectionHeader("Hosts", style: .settings) {
                    Text(model.directory(in: hosts))
                        .font(.nwMono(AppLayout.skillsMetaSize - 0.5))
                        .foregroundStyle(nw.textTertiary)
                        .lineLimit(1)
                }
                .padding(.horizontal, NW.Space.xxs)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(hosts) { host in
                        let state = model.state(of: host)
                        NWHostStateRow(host.name, detail: SkillsPresentation.host(state, owed: model.owes(host.id)),
                                       mark: Self.mark(state))
                    }
                }
                .padding(.horizontal, NW.Space.xxs)
                Text("Skills you copy into that folder by hand show up as Local.")
                    .nwText(size: AppLayout.skillsNoteSize, lineHeight: AppLayout.skillsNoteLineHeight)
                    .foregroundStyle(nw.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, NW.Space.xxs)
                    .padding(.top, NW.Space.s)
            }
        }
    }

    private func option(_ title: String, note: String, isOn: Binding<Bool>) -> some View {
        let nw = Color.nw
        return HStack(alignment: .top, spacing: NW.Space.l + NW.Space.xxs) {
            VStack(alignment: .leading, spacing: NW.Space.xxs) {
                Text(title)
                    .font(.nwSans(AppLayout.skillsOptionTitleSize, .medium))
                    .foregroundStyle(nw.textPrimary)
                Text(note)
                    .nwText(size: AppLayout.skillsNoteSize, lineHeight: AppLayout.skillsNoteLineHeight)
                    .foregroundStyle(nw.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Toggle(title, isOn: isOn).toggleStyle(.nwSwitch).labelsHidden()
        }
        .padding(.vertical, NW.Space.m + NW.Space.xxs)
        .overlay(alignment: .top) { NWHairline() }
    }

    static func mark(_ state: HostSkills) -> NWHostStateRow.Mark {
        switch state {
        case .loaded: .done
        case .loading: .working
        case .offline: .offline
        case .unsupported, .failed: .none
        }
    }
}
