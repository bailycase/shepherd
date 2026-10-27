import SwiftUI
import AppKit
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

// Settings ▸ Skills' sheets (SettingsSkillsBrowse, SettingsSkillsSearch, SettingsSkillsRepo):
// Browse skills.sh (its ranked lists and topics, or a search) and Add from repo (a repository's
// skills, or a folder's on this Mac, to pick from). Each lists on the left and previews the
// selected skill on the right: its SKILL.md, its files, and how to install it on every host.

// MARK: Browse skills.sh

/// Browse skills.sh: Trending, All time, Hot and Official, topics, or a
/// search as you type; the selected skill's preview, Install with how it will be used, and each
/// host's progress while it installs.
struct SkillsDirectorySheet: View {
    var vm: ShepherdViewModel
    var model: ClientSkills
    /// Opens Add from repo on a repository (the preview's "Pick from all").
    let openRepo: (String) -> Void
    let close: () -> Void

    @State private var query = ""
    @State private var ranking: DirectoryRanking = .trending
    @State private var topic: String?
    @State private var sort: Sort = .installs
    @State private var results: [DirectorySkill] = []
    @State private var loading = false
    @State private var failure: SkillsDirectoryError?
    @State private var selected: String?
    @State private var preview: SkillPreview?
    @State private var invocation: SkillInvocation = .automatic
    @Environment(\.openURL) private var openURL

    enum Sort: String, CaseIterable { case installs, name }

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    private let directory = SkillsDirectory()
    private var listKey: String { "\(query)|\(ranking.rawValue)|\(topic ?? "")" }

    var body: some View {
        let hosts = vm.skillsHosts
        SkillsSheetFrame(title: "Browse skills.sh",
                         subtitle: "The open directory of agent skills. Anything you install goes to all your hosts.", close: close) {
            Button { openURL(SkillsDirectory.home) } label: { Label("Open skills.sh", systemImage: "arrow.up.right.square") }
                .buttonStyle(.sh(.ghost, size: .s))
        } content: {
            VStack(spacing: 0) {
                SkillsSearchBar(text: $query)
                    .padding(.horizontal, AppLayout.skillsSheetSides)
                filters
                    .padding(.horizontal, AppLayout.skillsSheetSides)
                    .padding(.top, SH.Space.l)
                    .padding(.bottom, SH.Space.l)
                HStack(spacing: 0) {
                    list(hosts)
                        .frame(width: AppLayout.skillsSheetListWidth)
                    SHHairline(.vertical)
                    detail(hosts)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .overlay(alignment: .top) { SHHairline() }
            }
        }
        .task(id: listKey) { await load() }
        .task(id: selected) { await loadPreview() }
    }

    // MARK: Filters

    @ViewBuilder private var filters: some View {
        let sh = Color.sh
        if searching {
            HStack(spacing: SH.Space.m + SH.Space.xxs) {
                let term = Text("“\(query.trimmingCharacters(in: .whitespaces))”").foregroundStyle(sh.textPrimary)
                Text("\(results.count) \(results.count == 1 ? "skill" : "skills") for \(term)")
                    .font(.shSans(AppLayout.skillsSummarySize))
                    .foregroundStyle(sh.textSecondary)
                Spacer(minLength: SH.Space.m)
                Menu {
                    Picker("Sort", selection: $sort) {
                        Text("Installs").tag(Sort.installs)
                        Text("Name").tag(Sort.name)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Text("Sort: \(sort == .installs ? "Installs" : "Name")")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .frame(height: AppLayout.skillsTopicHeight)
        } else {
            HStack(spacing: SH.Space.m + SH.Space.xxs) {
                SHSegmentedPicker("List", selection: Binding(get: { ranking }, set: { ranking = $0; topic = nil }),
                                  options: DirectoryRanking.allCases.map { ($0, $0.title) })
                SHHairline(.vertical).frame(height: AppLayout.skillsTopicHeight - SH.Space.m)
                ScrollView(.horizontal) {
                    HStack(spacing: SH.Space.s) {
                        topicChip("All", selected: topic == nil) { topic = nil }
                        ForEach(SkillsDirectory.topics, id: \.title) { item in
                            topicChip(item.title, selected: topic == item.title) { topic = item.title }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private func topicChip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        let sh = Color.sh
        return Button(action: action) {
            Text(title)
                .font(.shSans(AppLayout.skillsNoteSize, selected ? .semibold : .regular))
                .foregroundStyle(selected ? sh.textPrimary : sh.textSecondary)
                .padding(.horizontal, SH.Space.m + SH.Space.xxs)
                .frame(height: AppLayout.skillsTopicHeight)
                .background(selected ? sh.bgSelected : Color.clear, in: Capsule())
                .overlay { if !selected { Capsule().strokeBorder(sh.lineSubtle) } }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: The list

    private func list(_ hosts: [SkillsHost]) -> some View {
        let sh = Color.sh
        let shown = sorted(results)
        return VStack(spacing: 0) {
            if !searching && failure == nil {
                HStack {
                    Text(topic.map { "\($0) · \(ranking.title)" } ?? ranking.heading).shSettingsLabel(table: true)
                    Spacer()
                    Text("Installs").shSettingsLabel(table: true)
                }
                .padding(.leading, SH.Space.m + SH.Space.xxs)
                .padding(.trailing, SH.Space.xl)
                .frame(height: AppLayout.skillsHeaderHeight)
                .overlay(alignment: .bottom) { SHHairline() }
            }
            if let failure {
                SkillsDirectoryProblem(failure: failure)
            } else if shown.isEmpty {
                Text(loading ? "Loading skills.sh…" : searching ? "No skills match." : "Nothing here yet.")
                    .font(.shSans(AppLayout.skillsSummarySize))
                    .foregroundStyle(sh.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { index, skill in
                            SkillResultRow(rank: searching || topic != nil ? nil : index + 1, skill: skill,
                                           state: SkillResultState(skill, model: model, hosts: hosts),
                                           selected: selected == skill.id, first: index == 0,
                                           highlight: searching ? query : "") {
                                selected = skill.id
                            } install: {
                                selected = skill.id
                                install(skill)
                            }
                            .equatable()
                        }
                    }
                }
                .scrollIndicators(.automatic)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func sorted(_ skills: [DirectorySkill]) -> [DirectorySkill] {
        guard searching, sort == .name else { return skills }
        return skills.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: The preview

    @ViewBuilder private func detail(_ hosts: [SkillsHost]) -> some View {
        if let skill = results.first(where: { $0.id == selected }) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: SH.Space.xl) {
                    SkillPreviewTitle(name: skill.name, source: skill.source, official: skill.official,
                                      meta: "\(DirectoryPresentation.installs(skill.installs)) installs")
                    actions(skill, hosts: hosts)
                    if let install = model.installs[skill.id], install.isRunning || install.failure != nil {
                        SkillInstallCard(install: install) { model.cancelInstall(skill.id) }
                            .shTransition(.disclosure)
                    }
                    if let preview, preview.skill == skill {
                        if let summary = preview.summary {
                            Text(summary)
                                .shText(size: AppLayout.skillsPreviewTextSize, lineHeight: AppLayout.skillsRailLineHeight)
                                .foregroundStyle(Color.sh.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        SkillPreviewCard(lines: preview.lines, tokens: preview.tokens,
                                         height: searching ? AppLayout.skillsPreviewSearchHeight : AppLayout.skillsPreviewBrowseHeight)
                        SkillFilesBlock(entries: preview.entries, note: SkillsPresentation.scriptsNote(paths: preview.paths))
                        moreFrom(skill, hosts: hosts)
                    } else {
                        ProgressView().progressViewStyle(.shSpinner).frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, SH.Space.xl + SH.Space.xxs)
                .padding(.horizontal, AppLayout.skillsSheetSides)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .shAnimation(.disclosure, value: model.installs[skill.id])
        } else {
            Text(failure == nil ? "Pick a skill to see what it does." : "")
                .font(.shSans(AppLayout.skillsSummarySize))
                .foregroundStyle(Color.sh.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func actions(_ skill: DirectorySkill, hosts: [SkillsHost]) -> some View {
        let state = SkillResultState(skill, model: model, hosts: hosts)
        return HStack(spacing: SH.Space.m) {
            switch state {
            case .installed:
                Label("Installed", systemImage: "checkmark")
                    .font(.shSans(AppLayout.skillsSummarySize, .medium))
                    .foregroundStyle(Color.sh.done)
            case .update:
                Button { Task { await model.update(skill.slug, in: vm.skillsHosts) } } label: {
                    Label("Update", systemImage: "arrow.down.to.line")
                }
                .buttonStyle(.sh(.primary))
            case .install, .installing:
                Button { install(skill) } label: { Label("Install", systemImage: "arrow.down.to.line") }
                    .buttonStyle(.sh(.primary))
                    .disabled(state != .install)
                SkillUsePicker(invocation: $invocation)
            }
            Button { openURL(SkillsDirectory.page(of: skill)) } label: {
                Label("View on skills.sh", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.sh(.ghost, size: .s))
        }
    }

    /// The rest of the skill's repository that this list shows, and every skill in it.
    @ViewBuilder private func moreFrom(_ skill: DirectorySkill, hosts: [SkillsHost]) -> some View {
        let others = results.filter { $0.source == skill.source && $0.id != skill.id }
        VStack(alignment: .leading, spacing: SH.Space.m) {
            Text("More in \(skill.source)").shSettingsLabel(table: true)
            SHFlowLayout(spacing: SH.Space.s) {
                ForEach(others) { other in
                    Button { selected = other.id } label: {
                        HStack(spacing: SH.Space.xs) {
                            Text(other.name)
                            if model.row(other.slug, in: hosts) != nil {
                                Text("✓").foregroundStyle(Color.sh.done)
                            }
                        }
                        .font(.shSans(AppLayout.skillsNoteSize))
                        .foregroundStyle(Color.sh.textSecondary)
                        .padding(.horizontal, SH.Space.m + SH.Space.xxs)
                        .frame(height: AppLayout.skillsTopicHeight)
                        .overlay { Capsule().strokeBorder(Color.sh.lineSubtle) }
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Button("Pick from the whole repo…") { openRepo(skill.source) }
                    .buttonStyle(.shLink(font: .shSans(AppLayout.skillsNoteSize)))
                    .frame(height: AppLayout.skillsTopicHeight)
            }
        }
    }

    // MARK: Loading and installing

    private func load() async {
        if searching {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
        }
        loading = true
        failure = nil
        defer { loading = false }
        do {
            let found: [DirectorySkill]
            if searching {
                found = try await directory.search(query)
            } else if let topic, let item = SkillsDirectory.topics.first(where: { $0.title == topic }) {
                found = try await directory.search(item.query)
            } else {
                found = try await directory.ranked(ranking)
            }
            guard !Task.isCancelled else { return }
            results = found
        } catch let error as SkillsDirectoryError {
            guard !Task.isCancelled else { return }
            results = []
            failure = error
        } catch {
            guard !Task.isCancelled else { return }
            results = []
            failure = .unavailable("Couldn't reach Shepherd's skills directory.")
        }
        if !results.contains(where: { $0.id == selected }) { selected = results.first?.id }
    }

    private func loadPreview() async {
        guard let skill = results.first(where: { $0.id == selected }) else {
            preview = nil
            return
        }
        guard preview?.skill != skill else { return }
        preview = nil
        let files = (try? await directory.files(of: skill)) ?? []
        guard !Task.isCancelled, selected == skill.id else { return }
        preview = SkillPreview(skill: skill, files: files)
    }

    private func install(_ skill: DirectorySkill) {
        let invocation = invocation
        Task { await model.install(skill.id, source: skill.source, skill: skill.slug, invocation: invocation, in: vm.skillsHosts) }
    }
}

/// A skill in the directory: its place in a ranked list, name (the search's match lit), seal,
/// repository, installs, and whether it's installed, installing (hosts counted, nothing spins),
/// or has an update.
private struct SkillResultRow: View, Equatable {
    let rank: Int?
    let skill: DirectorySkill
    let state: SkillResultState
    let selected: Bool
    let first: Bool
    let highlight: String
    let select: () -> Void
    let install: () -> Void
    @State private var hovering = false

    nonisolated static func == (a: SkillResultRow, b: SkillResultRow) -> Bool {
        a.rank == b.rank && a.skill == b.skill && a.state == b.state && a.selected == b.selected && a.first == b.first
            && a.highlight == b.highlight
    }

    var body: some View {
        let _ = SHRenderProbe.tick("skills.result")
        let sh = Color.sh
        HStack(alignment: .center, spacing: SH.Space.m + SH.Space.xxs) {
            if let rank {
                Text("\(rank)")
                    .font(.shMono(AppLayout.skillsMetaSize))
                    .foregroundStyle(sh.textTertiary)
                    .frame(width: AppLayout.skillsResultRankWidth, alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: SH.Space.xxs + 1) {
                HStack(spacing: SH.Space.s) {
                    Text(name)
                        .font(.shMono(AppLayout.skillsNameSize, .semibold))
                        .lineLimit(1)
                    if skill.official { SHOfficialSeal(size: AppLayout.skillsNameSize) }
                }
                Text(skill.source)
                    .font(.shMono(AppLayout.skillsMetaSize))
                    .foregroundStyle(sh.textTertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: SH.Space.xs) {
                Text(DirectoryPresentation.installs(skill.installs))
                    .font(.shMono(AppLayout.skillsDetailTextSize))
                    .foregroundStyle(sh.textPrimary)
                status
            }
            .frame(width: AppLayout.skillsResultInstallsWidth, alignment: .trailing)
        }
        .padding(.vertical, SH.Space.m)
        .padding(.leading, SH.Space.m + SH.Space.xxs)
        .padding(.trailing, SH.Space.xl)
        .frame(minHeight: AppLayout.skillsResultMinHeight)
        .background(selected ? sh.bgSelected : hovering ? sh.bgHover : Color.clear)
        .overlay(alignment: .top) { if !first { SHHairline() } }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Install", install)
    }

    /// The name with the search's matches in lantern.
    private var name: AttributedString {
        var text = AttributedString(skill.name)
        text.foregroundColor = Color.sh.textPrimary
        for range in DirectoryPresentation.matches(of: highlight, in: skill.name) {
            guard let lower = AttributedString.Index(range.lowerBound, within: text),
                  let upper = AttributedString.Index(range.upperBound, within: text) else { continue }
            text[lower..<upper].foregroundColor = Color.sh.lanternText
        }
        return text
    }

    @ViewBuilder private var status: some View {
        let sh = Color.sh
        switch state {
        case .install:
            Button("Install", action: install).buttonStyle(.sh(.secondary, size: .s))
        case .installing(let progress):
            HStack(spacing: SH.Space.s) {
                Text("\(progress.installed) of \(progress.steps.count) hosts")
                    .font(.shSans(AppLayout.skillsMetaSize))
                    .foregroundStyle(sh.textSecondary)
                SkillInstallMeter(steps: progress.steps.map(\.state))
            }
        case .installed:
            Label("Installed", systemImage: "checkmark")
                .font(.shSans(AppLayout.skillsNoteSize))
                .foregroundStyle(sh.done)
        case .update:
            SHUpdatePill()
        }
    }
}

/// An install's hosts as a thin bar: green where it's installed, blue where it's on its way, a
/// rule where it waits.
private struct SkillInstallMeter: View {
    let steps: [SkillInstall.Step.State]

    var body: some View {
        let sh = Color.sh
        HStack(spacing: SHSkillMetrics.budgetGap) {
            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                RoundedRectangle(cornerRadius: SHSkillMetrics.budgetGap)
                    .fill(step == .installed ? sh.done : step == .copying ? sh.running : sh.lineStrong)
            }
        }
        .frame(width: AppLayout.skillsProgressWidth, height: AppLayout.skillsProgressHeight)
        .accessibilityHidden(true)
    }
}

/// Why the directory couldn't be reached.
struct SkillsDirectoryProblem: View {
    let failure: SkillsDirectoryError

    var body: some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: SH.Space.l) {
            Text(failure.description)
                .shText(size: AppLayout.skillsSummarySize, lineHeight: AppLayout.skillsNoteLineHeight)
                .foregroundStyle(sh.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppLayout.skillsSheetSides)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: Add from repo

/// Add skills from a repo: a GitHub owner/repo or URL (looked up on a host, which fetches it), or
/// a folder on this Mac; its skills to pick from (the ones already installed stay ticked and
/// dimmed), the selected one's preview, how to use them, and Install N skills on every host. A
/// repository with one new skill installs it at once.
struct AddSkillsSheet: View {
    var vm: ShepherdViewModel
    var model: ClientSkills
    let initialRepo: String?
    let close: () -> Void

    @State private var input = ""
    @State private var found: RepoSkills?
    @State private var folder: URL?
    @State private var lookingUp = false
    @State private var problem: String?
    @State private var picked: Set<String> = []
    @State private var selected: String?
    @State private var previews: [String: [SkillPreviewLine]] = [:]
    @State private var invocation: SkillInvocation = .automatic
    @State private var installKey: String?

    var body: some View {
        let hosts = vm.skillsHosts
        SkillsSheetFrame(title: "Add skills from a repo",
                         subtitle: "A GitHub owner/repo or URL, or a folder on this Mac. Shepherd copies the skills you pick into "
                             + "its own pi's skills on every host.", close: close) {
            EmptyView()
        } content: {
            VStack(spacing: 0) {
                HStack(spacing: SH.Space.m + SH.Space.xxs) {
                    field
                    Button("Look up") { Task { await lookUp() } }
                        .buttonStyle(.sh(.secondary, size: .l))
                        .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || lookingUp)
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, AppLayout.skillsSheetSides)
                .padding(.bottom, SH.Space.l)
                if let problem {
                    SHInlineProblem(problem)
                        .padding(.horizontal, AppLayout.skillsSheetSides)
                        .padding(.bottom, SH.Space.l)
                }
                HStack(spacing: 0) {
                    picker(hosts).frame(width: AppLayout.skillsSheetListWidth)
                    SHHairline(.vertical)
                    detail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .overlay(alignment: .top) { SHHairline() }
                footer(hosts)
            }
        }
        .task {
            guard let initialRepo, input.isEmpty else { return }
            input = initialRepo
            await lookUp()
        }
    }

    private var field: some View {
        let sh = Color.sh
        return HStack(spacing: SH.Space.m + SH.Space.xxs) {
            Image(systemName: folder == nil ? SHGlyph.gitBranch.symbolName : "folder")
                .font(.shSans(AppLayout.skillsSummarySize))
                .foregroundStyle(sh.textTertiary)
                .accessibilityHidden(true)
            TextField("owner/repo, a GitHub URL, or a folder", text: $input)
                .textFieldStyle(.plain)
                .font(.shMono(AppLayout.skillsRepoFieldTextSize))
                .foregroundStyle(sh.textPrimary)
                .onSubmit { Task { await lookUp() } }
            if lookingUp {
                ProgressView().progressViewStyle(.shSpinner)
            } else if let found {
                let commit = Text(SkillsText.shortCommit(found.commit)).font(.shMono(AppLayout.skillsNoteSize))
                Text("\(found.skills.count) \(found.skills.count == 1 ? "skill" : "skills") · \(found.branch) @ \(commit)")
                    .font(.shSans(AppLayout.skillsNoteSize))
                    .foregroundStyle(sh.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, SH.Space.l)
        .frame(height: AppLayout.skillsRepoFieldHeight)
        .background(sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Radius.m))
        .shBorder(sh.lineStrong, radius: SH.Radius.m)
    }

    // MARK: The picker

    @ViewBuilder private func picker(_ hosts: [SkillsHost]) -> some View {
        let sh = Color.sh
        if let found {
            let newPaths = found.skills.filter { model.row($0.name, in: hosts) == nil }.map(\.path)
            VStack(spacing: 0) {
                HStack(spacing: SH.Space.l) {
                    Toggle(sources: newPaths.map { binding(for: $0) }, isOn: \.self) { EmptyView() }
                        .toggleStyle(.shCheckbox)
                        .labelsHidden()
                        .disabled(newPaths.isEmpty)
                    Text(SkillsPresentation.selection(picked.count, new: newPaths.count))
                        .font(.shSans(AppLayout.skillsNoteSize, .semibold))
                        .foregroundStyle(sh.textPrimary)
                    Spacer()
                    Button("Select all new") { picked = Set(newPaths) }
                        .buttonStyle(.shLink(color: sh.running, font: .shSans(AppLayout.skillsNoteSize)))
                        .disabled(newPaths.isEmpty || picked.count == newPaths.count)
                }
                .padding(.horizontal, SH.Space.l + SH.Space.xxs)
                .frame(height: AppLayout.skillsPreviewHeaderHeight)
                .background(sh.bgSunken)
                .overlay(alignment: .bottom) { SHHairline() }
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(found.skills.enumerated()), id: \.element.id) { index, skill in
                            let installed = model.row(skill.name, in: hosts)
                            SkillPickRow(skill: skill, picked: installed != nil || picked.contains(skill.path),
                                         installed: installed.map { $0.skill.update == nil ? "Installed" : "Installed · update" },
                                         selected: selected == skill.path, first: index == 0) {
                                selected = skill.path
                            } toggle: {
                                guard installed == nil else { return }
                                if picked.contains(skill.path) { picked.remove(skill.path) } else { picked.insert(skill.path) }
                            }
                            .equatable()
                        }
                    }
                }
            }
        } else {
            Text(lookingUp ? "Looking it up…" : "Look up a repository to see its skills.")
                .font(.shSans(AppLayout.skillsSummarySize))
                .foregroundStyle(sh.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func binding(for path: String) -> Binding<Bool> {
        Binding(get: { picked.contains(path) }, set: { on in
            if on { picked.insert(path) } else { picked.remove(path) }
        })
    }

    // MARK: The preview

    @ViewBuilder private var detail: some View {
        if let found, let skill = found.skills.first(where: { $0.path == selected }) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: SH.Space.xl) {
                    SkillPreviewTitle(name: skill.name, source: skill.path.isEmpty ? found.repo : "\(found.repo) › \(skill.path)",
                                      official: false, meta: nil)
                    if !skill.summary.isEmpty {
                        Text(skill.summary)
                            .shText(size: AppLayout.skillsPreviewTextSize, lineHeight: AppLayout.skillsRailLineHeight)
                            .foregroundStyle(Color.sh.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    SkillPreviewCard(lines: previews[skill.path] ?? [], tokens: SkillsText.tokens(skill.instructions),
                                     height: AppLayout.skillsPreviewRepoHeight)
                    SkillFilesBlock(entries: skill.files, note: SkillsPresentation.scriptsNote(entries: skill.files))
                }
                .padding(.vertical, SH.Space.xl + SH.Space.xxs)
                .padding(.horizontal, AppLayout.skillsSheetSides)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Color.clear
        }
    }

    // MARK: The footer

    private func footer(_ hosts: [SkillsHost]) -> some View {
        let sh = Color.sh
        let install = installKey.flatMap { model.installs[$0] }
        return HStack(spacing: SH.Space.l) {
            Text("Use them")
                .font(.shSans(AppLayout.skillsSummarySize))
                .foregroundStyle(sh.textSecondary)
            SHSegmentedPicker("Use them", selection: $invocation,
                              options: [(.automatic, "Automatically"), (.slashOnly, "Only with /skill")])
            if let install {
                Text(SkillsPresentation.installLine(install))
                    .font(.shSans(AppLayout.skillsNoteSize, .medium))
                    .shShimmer(active: install.isRunning)
                    .foregroundStyle(install.failure != nil && install.installed == 0 ? sh.failed : sh.textSecondary)
                    .lineLimit(1)
            } else {
                Label(SkillsPresentation.destinations(model.targets(in: hosts)), systemImage: "desktopcomputer")
                    .font(.shSans(AppLayout.skillsNoteSize))
                    .foregroundStyle(sh.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: SH.Space.m)
            Button("Cancel", action: close)
                .buttonStyle(.sh(.ghost))
                .keyboardShortcut(.cancelAction)
            Button(SkillsPresentation.installTitle(max(picked.count, 1))) { installPicked() }
                .buttonStyle(.sh(.primary))
                .disabled(picked.isEmpty || install?.isRunning == true)
        }
        .padding(.leading, AppLayout.skillsSheetSides)
        .padding(.trailing, SH.Space.xl + SH.Space.xxs)
        .frame(height: AppLayout.skillsFooterHeight)
        .background(sh.bgSunken)
        .overlay(alignment: .top) { SHHairline() }
    }

    // MARK: Looking up and installing

    private func lookUp() async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        lookingUp = true
        problem = nil
        found = nil
        picked = []
        selected = nil
        installKey = nil
        defer { lookingUp = false }
        let result: RepoSkills
        do {
            if text.hasPrefix("/") || text.hasPrefix("~") {
                let url = URL(fileURLWithPath: (text as NSString).expandingTildeInPath, isDirectory: true)
                result = try await Task.detached { try LocalSkillFolder.scan(url) }.value
                folder = url
            } else {
                result = try await model.lookUp(text, in: vm.skillsHosts)
                folder = nil
            }
        } catch {
            problem = SkillsSheetText.problem(error)
            return
        }
        found = result
        previews = Dictionary(uniqueKeysWithValues: result.skills.map { ($0.path, SkillPreviewLine.lines($0.instructions)) })
        let reference = SkillsText.reference(text)
        let hosts = vm.skillsHosts
        let fresh = result.skills.filter { model.row($0.name, in: hosts) == nil }
        let pointed = result.skills.first { $0.path == reference?.path || $0.name == reference?.skill }
        selected = (pointed ?? fresh.first ?? result.skills.first)?.path
        if let pointed, model.row(pointed.name, in: hosts) == nil { picked = [pointed.path] }
        // One new skill: nothing to pick from.
        if result.skills.count == 1, let only = fresh.first {
            picked = [only.path]
            installPicked()
        }
    }

    private func installPicked() {
        guard let found, !picked.isEmpty else { return }
        let paths = picked.sorted()
        let invocation = invocation
        let key = "repo:\(found.repo)"
        installKey = key
        if let folder {
            Task {
                for path in paths {
                    guard let skill = found.skills.first(where: { $0.path == path }) else { continue }
                    let files: [SkillFile]
                    do {
                        files = try await Task.detached { try LocalSkillFolder.files(in: folder, path: path) }.value
                    } catch {
                        problem = SkillsSheetText.problem(error)
                        return
                    }
                    await model.installFiles(key, name: skill.name, files: files, invocation: invocation, in: vm.skillsHosts)
                }
                finish(key)
            }
        } else {
            Task {
                await model.install(key, repo: found.repo, paths: paths, commit: found.commit, invocation: invocation,
                                    in: vm.skillsHosts)
                finish(key)
            }
        }
    }

    /// Closes the sheet once every host that could take the skills has them.
    private func finish(_ key: String) {
        guard let install = model.installs[key], install.failure == nil, !install.cancelled else { return }
        close()
    }
}

/// One skill in a repository: its tick, name and description; a skill already here stays ticked
/// and dimmed with "Installed".
private struct SkillPickRow: View, Equatable {
    let skill: RepoSkill
    let picked: Bool
    let installed: String?
    let selected: Bool
    let first: Bool
    let select: () -> Void
    let toggle: () -> Void

    nonisolated static func == (a: SkillPickRow, b: SkillPickRow) -> Bool {
        a.skill == b.skill && a.picked == b.picked && a.installed == b.installed && a.selected == b.selected && a.first == b.first
    }

    var body: some View {
        let sh = Color.sh
        let dimmed = installed != nil
        HStack(spacing: SH.Space.l) {
            Toggle(skill.name, isOn: Binding(get: { picked }, set: { _ in toggle() }))
                .toggleStyle(.shCheckbox)
                .labelsHidden()
                .disabled(dimmed)
            Text(skill.name)
                .font(.shMono(AppLayout.skillsSummarySize, .semibold))
                .foregroundStyle(dimmed ? sh.textTertiary : sh.textPrimary)
                .lineLimit(1)
                .frame(width: AppLayout.skillsPickerNameWidth, alignment: .leading)
            Text(skill.summary)
                .font(.shSans(AppLayout.skillsNoteSize))
                .foregroundStyle(dimmed ? sh.textTertiary : sh.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let installed {
                Text(installed)
                    .font(.shSans(AppLayout.skillsMetaSize))
                    .foregroundStyle(installed == "Installed" ? sh.textTertiary : sh.lanternText)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, SH.Space.l + SH.Space.xxs)
        .frame(minHeight: AppLayout.skillsPickerRowHeight)
        .background(selected ? sh.bgSelected : Color.clear)
        .overlay(alignment: .top) { if !first { SHHairline() } }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: Shared parts

/// A skills sheet: its title and line under it, a trailing action and the close button, then
/// its content.
private struct SkillsSheetFrame<Trailing: View, Content: View>: View {
    let title: String
    let subtitle: String
    let close: () -> Void
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        let sh = Color.sh
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: SH.Space.l) {
                VStack(alignment: .leading, spacing: SH.Space.xxs + 1) {
                    Text(title)
                        .font(.shSans(AppLayout.skillsSheetTitleSize, .semibold))
                        .foregroundStyle(sh.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text(subtitle)
                        .font(.shSans(AppLayout.skillsSummarySize))
                        .foregroundStyle(sh.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: SH.Space.l)
                HStack(spacing: SH.Space.s) {
                    trailing
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.shSans(AppLayout.skillsMetaSize, .semibold))
                            .foregroundStyle(sh.textSecondary)
                            .frame(width: AppLayout.skillsSheetCloseSize, height: AppLayout.skillsSheetCloseSize)
                            .overlay { Circle().strokeBorder(sh.lineStrong) }
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Close")
                }
            }
            .padding(.top, SH.Space.xl + SH.Space.xxs)
            .padding(.bottom, SH.Space.l + SH.Space.xxs)
            .padding(.leading, AppLayout.skillsSheetSides)
            .padding(.trailing, SH.Space.xl + SH.Space.xxs)
            content
        }
        .frame(minWidth: AppLayout.skillsSheetMinWidth, idealWidth: AppLayout.skillsSheetWidth,
               minHeight: AppLayout.skillsSheetMinHeight, idealHeight: AppLayout.skillsSheetHeight)
        .background(sh.bgWindow)
    }
}

/// The directory's search field: 38pt, a glass, 14pt text, and a clear button once there's text.
private struct SkillsSearchBar: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        let sh = Color.sh
        HStack(spacing: SH.Space.m + SH.Space.xxs) {
            Image(systemName: "magnifyingglass")
                .font(.shSans(AppLayout.skillsSearchTextSize))
                .foregroundStyle(sh.textTertiary)
                .accessibilityHidden(true)
            TextField("Search skills, repos and owners", text: $text)
                .textFieldStyle(.plain)
                .font(.shSans(AppLayout.skillsSearchTextSize))
                .foregroundStyle(sh.textPrimary)
                .tint(sh.lantern)
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.shSans(AppLayout.skillsSearchTextSize))
                        .foregroundStyle(sh.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
            }
        }
        .padding(.leading, SH.Space.l)
        .padding(.trailing, SH.Space.m)
        .frame(height: AppLayout.skillsSearchHeight)
        .background(sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Radius.m))
        .shBorder(focused ? sh.lantern : sh.lineStrong, radius: SH.Radius.m)
        .onAppear { focused = true }
    }
}

/// How the skill will be used, beside Install: "Use: Automatically ⌄".
private struct SkillUsePicker: View {
    @Binding var invocation: SkillInvocation

    var body: some View {
        Menu {
            Picker("Use", selection: $invocation) {
                Text("Automatically").tag(SkillInvocation.automatic)
                Text("Only with /skill").tag(SkillInvocation.slashOnly)
            }
            .pickerStyle(.inline)
        } label: {
            let use = Text("Use:").foregroundStyle(Color.sh.textTertiary)
            Text("\(use) \(invocation == .automatic ? "Automatically" : "Only with /skill")")
        }
        .menuStyle(.button)
        .buttonStyle(.sh(.secondary))
        .fixedSize()
    }
}

/// A previewed skill's name, where it's from, its seal, and a line about it.
private struct SkillPreviewTitle: View {
    let name: String
    let source: String
    let official: Bool
    let meta: String?

    var body: some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: SH.Space.s) {
            Text(name)
                .font(.shMono(AppLayout.skillsPreviewNameSize, .semibold))
                .foregroundStyle(sh.textPrimary)
                .textSelection(.enabled)
            HStack(spacing: SH.Space.m) {
                Text(source)
                    .font(.shMono(AppLayout.skillsNoteSize))
                    .foregroundStyle(sh.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if official {
                    Label("Official", systemImage: "checkmark.seal")
                        .font(.shSans(AppLayout.skillsMetaSize - 0.5))
                        .foregroundStyle(sh.running)
                }
                if let meta {
                    Text("· \(meta)")
                        .font(.shSans(AppLayout.skillsNoteSize))
                        .foregroundStyle(sh.textTertiary)
                        .lineLimit(1)
                }
            }
        }
    }
}

/// An install on its way: the line that shimmers while it runs, Cancel, and each host's step.
private struct SkillInstallCard: View {
    let install: SkillInstall
    let cancel: () -> Void

    var body: some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: SH.Space.s) {
            HStack(spacing: SH.Space.m) {
                Text(SkillsPresentation.installLine(install))
                    .font(.shSans(AppLayout.skillsOptionTitleSize, .medium))
                    .shShimmer(active: install.isRunning)
                    .foregroundStyle(install.failure != nil && install.installed == 0 ? sh.failed : sh.textPrimary)
                Spacer(minLength: SH.Space.m)
                if install.isRunning {
                    Button("Cancel", action: cancel).buttonStyle(.sh(.ghost, size: .s))
                }
            }
            ForEach(install.steps) { step in
                SHHostStateRow(step.name, detail: SkillsPresentation.step(step.state), mark: Self.mark(step.state))
            }
        }
        .padding(.vertical, SH.Space.l)
        .padding(.horizontal, SH.Space.l + SH.Space.xxs)
        .background(sh.bgSunken, in: RoundedRectangle(cornerRadius: AppLayout.skillsCardRadius))
        .shBorder(sh.lineSubtle, radius: AppLayout.skillsCardRadius)
    }

    static func mark(_ state: SkillInstall.Step.State) -> SHHostStateRow.Mark {
        switch state {
        case .installed: .done
        case .copying: .working
        case .owed: .offline
        case .waiting, .failed: .none
        }
    }
}

/// A skill's files and what its scripts are.
private struct SkillFilesBlock: View {
    let entries: [SkillFileEntry]
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.m) {
            Text("Files").shSettingsLabel(table: true)
            SHFlowLayout(spacing: SH.Space.s) {
                ForEach(entries) { entry in
                    SHSkillFileChip(SkillsPresentation.chip(entry), count: entry.isDirectory ? entry.fileCount : nil,
                                    kind: entry.isDirectory ? (entry.name == "scripts" ? .code : .folder) : .file)
                }
            }
            Text(note)
                .shText(size: AppLayout.skillsNoteSize, lineHeight: AppLayout.skillsNoteLineHeight)
                .foregroundStyle(Color.sh.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A SKILL.md, read-only: its header (the file and what it costs when used), then its lines
/// numbered and lightly highlighted as the instructions editor does, fading out at the bottom.
private struct SkillPreviewCard: View {
    let lines: [SkillPreviewLine]
    let tokens: Int
    let height: CGFloat

    var body: some View {
        let sh = Color.sh
        VStack(spacing: 0) {
            HStack(spacing: SH.Space.m) {
                Image(systemName: SHGlyph.document.symbolName)
                    .font(.shSans(AppLayout.skillsMetaSize))
                    .foregroundStyle(sh.textTertiary)
                    .accessibilityHidden(true)
                Text("SKILL.md")
                    .font(.shMono(AppLayout.skillsDetailTextSize))
                    .foregroundStyle(sh.textSecondary)
                Spacer(minLength: SH.Space.m)
                if tokens > 0 {
                    Text("\(SkillsText.tokenNote(tokens)) when used")
                        .font(.shSans(AppLayout.skillsMetaSize))
                        .foregroundStyle(sh.textTertiary)
                }
            }
            .padding(.horizontal, SH.Space.l)
            .frame(height: AppLayout.skillsPreviewHeaderHeight)
            .background(sh.bgSunken)
            .overlay(alignment: .bottom) { SHHairline() }
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            Text("\(line.number)")
                                .font(.shMono(AppLayout.skillsPreviewNumberSize))
                                .foregroundStyle(sh.textTertiary)
                                .frame(width: AppLayout.skillsPreviewGutter - SH.Space.m, alignment: .trailing)
                                .padding(.trailing, SH.Space.m)
                            Text(line.text)
                                .font(.shMono(AppLayout.skillsDetailTextSize))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, minHeight: AppLayout.skillsPreviewLineHeight, alignment: .leading)
                    }
                }
                .padding(.vertical, SH.Space.m)
                .textSelection(.enabled)
            }
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [sh.bgWindow.opacity(0), sh.bgWindow], startPoint: .top, endPoint: .bottom)
                    .frame(height: AppLayout.skillsPreviewFade)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: height)
        .background(sh.bgWindow)
        .clipShape(RoundedRectangle(cornerRadius: AppLayout.skillsCardRadius))
        .shBorder(sh.lineSubtle, radius: AppLayout.skillsCardRadius)
    }
}

/// One line of a previewed SKILL.md, highlighted once when the file arrives.
struct SkillPreviewLine: Identifiable, Equatable {
    let number: Int
    let text: AttributedString

    var id: Int { number }

    /// The file's lines, at most `limit` of them, with the instructions editor's highlighting.
    @MainActor
    static func lines(_ text: String, limit: Int = 400) -> [SkillPreviewLine] {
        let sh = Color.sh
        return InstructionsText.lines(text).prefix(limit).enumerated().map { index, line in
            var styled = AttributedString(line)
            styled.foregroundColor = sh.textSecondary
            for span in InstructionsText.highlight(line: line) {
                let utf16 = line.utf16
                let start = utf16.index(utf16.startIndex, offsetBy: span.range.lowerBound, limitedBy: utf16.endIndex) ?? utf16.endIndex
                let end = utf16.index(utf16.startIndex, offsetBy: span.range.upperBound, limitedBy: utf16.endIndex) ?? utf16.endIndex
                guard let lower = AttributedString.Index(start, within: styled),
                      let upper = AttributedString.Index(end, within: styled), lower < upper else { continue }
                switch span.role {
                case .headingMarker: styled[lower..<upper].foregroundColor = sh.textTertiary
                case .heading:
                    styled[lower..<upper].foregroundColor = sh.textPrimary
                    styled[lower..<upper].font = .shMono(AppLayout.skillsDetailTextSize, .semibold)
                case .bullet: styled[lower..<upper].foregroundColor = sh.lanternText
                case .code: styled[lower..<upper].foregroundColor = sh.synString
                }
            }
            return SkillPreviewLine(number: index + 1, text: styled)
        }
    }
}

/// A skill from skills.sh, ready to preview (`DirectoryPreview`), with its SKILL.md's lines
/// highlighted once.
struct SkillPreview: Equatable {
    let skill: DirectorySkill
    let summary: String?
    let lines: [SkillPreviewLine]
    let tokens: Int
    let paths: [String]
    let entries: [SkillFileEntry]

    @MainActor
    init(skill: DirectorySkill, files: [DirectoryFile]) {
        let preview = DirectoryPreview(skill: skill, files: files)
        self.skill = skill
        summary = preview.summary
        lines = SkillPreviewLine.lines(preview.instructions)
        tokens = preview.tokens
        paths = preview.paths
        entries = preview.entries
    }
}

enum SkillsSheetText {
    /// A failure in words: a host's own reason, else what went wrong.
    static func problem(_ error: Error) -> String {
        if case RemoteHostClientError.rejected(_, let message) = error { return message }
        if let error = error as? LocalSkillFolder.Failure { return error.description }
        return error.localizedDescription
    }
}

// MARK: A folder on this Mac

/// Skills in a folder on this Mac (Add from repo): every folder under it that holds a SKILL.md,
/// read here and copied to each host as its files.
enum LocalSkillFolder {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// The folder's skills, as a looked-up repository's are.
    static func scan(_ root: URL) throws -> RepoSkills {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Failure(description: "\(root.path) isn't a folder on this Mac.")
        }
        var skills: [RepoSkill] = []
        let walk = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                          options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let url = walk?.nextObject() as? URL {
            if url.lastPathComponent == "node_modules" { walk?.skipDescendants(); continue }
            guard url.lastPathComponent == "SKILL.md" else { continue }
            let folder = url.deletingLastPathComponent()
            let path = relative(folder, to: root)
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let frontmatter = SkillsText.frontmatter(text)
            let files = self.files(under: folder).map { relative($0, to: folder) }
            skills.append(RepoSkill(path: path, name: SkillsText.folderName(for: frontmatter, path: path, repo: root.lastPathComponent),
                                    summary: frontmatter.description ?? "", instructions: String(text.prefix(16 * 1024)),
                                    files: SkillsText.entries(paths: files)))
            if skills.count >= 200 { break }
        }
        guard !skills.isEmpty else { throw Failure(description: "No folder in \(root.lastPathComponent) holds a SKILL.md.") }
        return RepoSkills(repo: (root.path as NSString).abbreviatingWithTildeInPath, branch: "folder", commit: "",
                          skills: skills.sorted { $0.name < $1.name })
    }

    /// One skill's files, to copy to a host (at most `SkillFile.maxTotalBytes` in all).
    static func files(in root: URL, path: String) throws -> [SkillFile] {
        let folder = path.isEmpty ? root : root.appendingPathComponent(path, isDirectory: true)
        var result: [SkillFile] = []
        var total = 0
        for url in files(under: folder) {
            let data = try Data(contentsOf: url)
            total += data.count
            guard total <= SkillFile.maxTotalBytes else {
                throw Failure(description: "\(folder.lastPathComponent) is too big to copy to other hosts. Put it in a git repository instead.")
            }
            let executable = FileManager.default.isExecutableFile(atPath: url.path)
            result.append(SkillFile(path: relative(url, to: folder), contents: data, executable: executable))
        }
        return result
    }

    private static func files(under folder: URL) -> [URL] {
        var urls: [URL] = []
        let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                  options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let url = walk?.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { urls.append(url) }
        }
        return urls.sorted { $0.path < $1.path }
    }

    private static func relative(_ url: URL, to root: URL) -> String {
        let base = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(base) else { return url.lastPathComponent }
        return String(path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
