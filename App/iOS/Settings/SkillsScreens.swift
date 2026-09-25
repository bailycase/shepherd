import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

// Settings ▸ Skills on iPhone and iPad (MobileSkills; home track): the agent skills every host
// keeps in ~/.agents/skills, the same on every host, read and changed over `skills.v1`. The list
// turns a skill on or off, updates the ones with a newer commit, and searches skills.sh in place.
// A skill opens its detail (how the agent uses it, its version, which hosts have it, its files),
// a search result its preview with Install, and + adds skills from a repository. A host that is
// offline is owed each change and takes it when it's back. `ClientSkills` keeps every rule;
// these screens draw it.

/// Settings ▸ Skills (MobileSkills): what every host has installed, or skills.sh's answer to a
/// search.
struct SkillsScreen: View {
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator
    @Environment(\.settingsColumn) private var inColumn
    @State private var query = ""
    @State private var results: [DirectorySkill] = []
    @State private var searching = false
    @State private var failure: String?
    @FocusState private var searchFocused: Bool

    private var term: String { query.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        let store = SettingsStore.of(hosts)
        let model = store.skills
        let skillsHosts = store.skillsHosts
        ScrollView {
            VStack(alignment: .leading, spacing: MobileLayout.sectionSpacing) {
                VStack(alignment: .leading, spacing: MobileLayout.blockSpacing) {
                    Text("Global: every host gets the same skills. Tap one for how it’s used, its files and hosts.")
                        .nwText(.caption)
                        .foregroundStyle(Color.nw.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, NW.Space.xs)
                    NWTouchSearchField("Search skills.sh", text: $query, focus: $searchFocused)
                }
                if let problem = model.problem {
                    NWBanner(.failed, title: problem) {
                        Button("OK") { model.dismissProblem() }.buttonStyle(.nw(.secondary))
                    }
                }
                if let removal = model.removal {
                    NWBanner(.idle, title: SkillsPresentation.removed(removal), systemImage: "trash") {
                        Button("Undo") { model.undoRemoval(in: skillsHosts) }.buttonStyle(.nw(.secondary))
                    }
                }
                if term.isEmpty {
                    InstalledSkills(model: model, hosts: skillsHosts) { name in navigator.open(.settings(.skill(name))) }
                } else {
                    SkillSearchResults(term: term, results: results, searching: searching, failure: failure, model: model,
                                       hosts: skillsHosts) { skill in
                        navigator.open(.settings(.skillResult(skill)))
                    }
                }
            }
            .padding(.horizontal, MobileLayout.gutter)
            .padding(.top, inColumn ? MobileLayout.settingsColumnTop : 0)
            .padding(.bottom, MobileLayout.sectionSpacing)
            .frame(maxWidth: MobileLayout.homeMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await store.refresh() }
        .background(Color.nw.bgWindow)
        .nwAnimation(.content, value: term.isEmpty)
        .navigationTitle("Skills")
        .navigationBarTitleDisplayMode(inColumn ? .inline : .large)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { navigator.open(.settings(.skillsRepo(nil))) } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add from repo")
            }
        }
        .task { if !inColumn { await store.watch() } }
        .task(id: term) { await search() }
    }

    /// Asks skills.sh once typing pauses; a newer search cancels this one.
    private func search() async {
        let words = term
        guard !words.isEmpty else {
            results = []
            failure = nil
            searching = false
            return
        }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        searching = true
        do {
            let found = try await SkillsDirectory().search(words)
            guard !Task.isCancelled else { return }
            results = found
            failure = nil
        } catch {
            guard !Task.isCancelled else { return }
            results = []
            failure = (error as? SkillsDirectoryError)?.description ?? "Couldn't reach skills.sh."
        }
        searching = false
    }
}

/// "Installed · 8" with Update N, a card of every skill, and which hosts are away; or why the
/// hosts' skills can't show yet.
private struct InstalledSkills: View {
    let model: ClientSkills
    let hosts: [SkillsHost]
    let open: (String) -> Void

    var body: some View {
        if model.reference(in: hosts) != nil {
            let rows = model.rows(in: hosts)
            let updates = rows.filter { $0.skill.update != nil }.count
            VStack(alignment: .leading, spacing: MobileLayout.headerSpacing) {
                NWListHeader("Installed · \(rows.count)") {
                    if updates > 0 {
                        Button("Update \(updates)") { Task { await model.updateAll(in: hosts) } }
                            .buttonStyle(.nwLink(font: .nw(.caption, weight: .medium)))
                            .disabled(rows.contains(where: \.isUpdating))
                    }
                }
                if rows.isEmpty {
                    SettingsFootnote("No skills yet. Search skills.sh above, or add a repository with +.")
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            SkillListRow(row: row, first: index == 0) {
                                open(row.name)
                            } toggle: { on in
                                model.setOn(row.name, on, in: hosts)
                            }
                            .equatable()
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: NWListMetrics.cardRadius))
                    .nwCard(radius: NWListMetrics.cardRadius)
                }
                if let note = SkillsPresentation.offlineNote(hosts) {
                    SettingsFootnote(note)
                }
            }
            .nwAnimation(.list, value: rows.map(\.id))
        } else {
            unavailable
        }
    }

    /// Why nothing shows: no hosts, none online, too old, a failed read, or still reading.
    @ViewBuilder private var unavailable: some View {
        let connected = hosts.filter(\.isConnected)
        let failures = connected.compactMap { host -> String? in
            if case .failed(let reason) = model.state(of: host) { return reason }
            return nil
        }
        if hosts.isEmpty {
            SettingsFootnote("Add a host in Settings ▸ Hosts to manage its skills here.")
        } else if connected.isEmpty {
            SettingsFootnote("No host is online. Skills show here once one is back.")
        } else if connected.allSatisfy({ !$0.serves }) {
            SettingsFootnote(connected.count == 1
                ? "\(connected[0].name)'s Shepherd is too old for skills. Update it to manage them here."
                : "Your hosts' Shepherd is too old for skills. Update it to manage them here.")
        } else if !failures.isEmpty, !connected.contains(where: { model.state(of: $0) == .loading }) {
            SettingsFootnote(failures[0], tone: .failed)
        } else {
            ProgressView().progressViewStyle(NWSpinnerStyle())
                .frame(maxWidth: .infinity)
        }
    }
}

/// A skill's row (MobileSkills): its name in mono over its description ("/skill only · …" for
/// one only /skill loads), Update while a newer commit waits (Updating while it goes), and its
/// switch. The row opens the skill; the switch turns it on or off on every host.
private struct SkillListRow: View, Equatable {
    let row: SkillRow
    let first: Bool
    let open: () -> Void
    let toggle: (Bool) -> Void

    nonisolated static func == (a: SkillListRow, b: SkillListRow) -> Bool {
        a.row == b.row && a.first == b.first
    }

    var body: some View {
        let nw = Color.nw
        let skill = row.skill
        ZStack(alignment: .trailing) {
            Button(action: open) {
                HStack(spacing: NW.Space.m + NW.Space.xxs) {
                    VStack(alignment: .leading, spacing: MobileLayout.skillLineSpacing) {
                        Text(skill.name)
                            .font(.nwMono(MobileLayout.skillNameSize, .semibold))
                            .foregroundStyle(skill.isOn ? nw.textPrimary : nw.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(SkillsPresentation.mobileSummary(skill))
                            .font(.nwSans(MobileLayout.skillSummarySize))
                            .foregroundStyle(nw.textTertiary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if row.isUpdating {
                        Text("Updating")
                            .font(.nw(.caption, weight: .medium))
                            .foregroundStyle(nw.running)
                            .nwShimmer(active: true)
                    } else if skill.update != nil {
                        NWUpdatePill()
                    }
                    Color.clear
                        .frame(width: MobileLayout.skillSwitchSlot, height: 1)
                        .accessibilityHidden(true)
                }
                .padding(.vertical, NW.Space.m)
                .padding(.horizontal, NW.Space.l + NW.Space.xxs)
                .frame(maxWidth: .infinity, minHeight: MobileLayout.skillRowHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.nwRow(radius: 0))
            .accessibilityLabel(skill.update == nil ? skill.name : "\(skill.name), update available")
            .accessibilityHint(SkillsPresentation.mobileSummary(skill))
            Toggle(skill.name, isOn: Binding(get: { skill.isOn }, set: toggle))
                .toggleStyle(.nwSwitch)
                .labelsHidden()
                .padding(.trailing, NW.Space.l + NW.Space.xxs)
        }
        .overlay(alignment: .top) { if !first { NWHairline() } }
    }
}

// MARK: skills.sh

/// A search of skills.sh: how many it found, then each result with its repository, installs,
/// and Install or where it stands.
private struct SkillSearchResults: View {
    let term: String
    let results: [DirectorySkill]
    let searching: Bool
    let failure: String?
    let model: ClientSkills
    let hosts: [SkillsHost]
    let open: (DirectorySkill) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MobileLayout.headerSpacing) {
            NWListHeader(searching && results.isEmpty ? "Searching skills.sh…" : SkillsPresentation.results(results.count, for: term))
            if let failure {
                SettingsFootnote(failure, tone: .failed)
            } else if results.isEmpty {
                if !searching {
                    SettingsFootnote("No skills match. Try fewer words, or a repository's name.")
                }
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, skill in
                        SkillResultLine(skill: skill, state: SkillResultState(skill, model: model, hosts: hosts), term: term,
                                        first: index == 0) {
                            open(skill)
                        } install: {
                            Task {
                                await model.install(skill.id, source: skill.source, skill: skill.slug, invocation: nil, in: hosts)
                            }
                        }
                        .equatable()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: NWListMetrics.cardRadius))
                .nwCard(radius: NWListMetrics.cardRadius)
            }
        }
    }
}

/// A skill on skills.sh: its name (the search's match lit) and seal over its repository and
/// installs, and at its end Install, how many hosts have it so far, Installed, or Update.
private struct SkillResultLine: View, Equatable {
    let skill: DirectorySkill
    let state: SkillResultState
    let term: String
    let first: Bool
    let open: () -> Void
    let install: () -> Void

    nonisolated static func == (a: SkillResultLine, b: SkillResultLine) -> Bool {
        a.skill == b.skill && a.state == b.state && a.term == b.term && a.first == b.first
    }

    var body: some View {
        let nw = Color.nw
        ZStack(alignment: .trailing) {
            Button(action: open) {
                HStack(spacing: NW.Space.m + NW.Space.xxs) {
                    VStack(alignment: .leading, spacing: MobileLayout.skillLineSpacing) {
                        HStack(spacing: NW.Space.s) {
                            Text(name)
                                .font(.nwMono(MobileLayout.skillNameSize, .semibold))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if skill.official { NWOfficialSeal(size: MobileLayout.skillSummarySize) }
                        }
                        Text(SkillsPresentation.resultMeta(skill))
                            .font(.nwSans(MobileLayout.skillSummarySize))
                            .foregroundStyle(nw.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear
                        .frame(width: MobileLayout.skillStatusSlot, height: 1)
                        .accessibilityHidden(true)
                }
                .padding(.vertical, NW.Space.m)
                .padding(.horizontal, NW.Space.l + NW.Space.xxs)
                .frame(maxWidth: .infinity, minHeight: MobileLayout.skillRowHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.nwRow(radius: 0))
            .accessibilityLabel(skill.name)
            .accessibilityHint(SkillsPresentation.resultMeta(skill))
            status
                .frame(width: MobileLayout.skillStatusSlot, alignment: .trailing)
                .padding(.trailing, NW.Space.l + NW.Space.xxs)
        }
        .overlay(alignment: .top) { if !first { NWHairline() } }
    }

    /// The name with the search's matches in lantern.
    private var name: AttributedString {
        var text = AttributedString(skill.name)
        text.foregroundColor = Color.nw.textPrimary
        for range in DirectoryPresentation.matches(of: term, in: skill.name) {
            guard let lower = AttributedString.Index(range.lowerBound, within: text),
                  let upper = AttributedString.Index(range.upperBound, within: text) else { continue }
            text[lower..<upper].foregroundColor = Color.nw.lanternText
        }
        return text
    }

    @ViewBuilder private var status: some View {
        let nw = Color.nw
        switch state {
        case .install:
            Button("Install", action: install)
                .buttonStyle(.nw(.secondary, size: .s))
                .accessibilityLabel("Install \(skill.name)")
        case .installing(let progress):
            Text("\(progress.installed) of \(progress.steps.count) hosts")
                .font(.nw(.caption))
                .foregroundStyle(nw.textSecondary)
                .nwShimmer(active: true)
                .lineLimit(1)
        case .installed:
            Label("Installed", systemImage: "checkmark")
                .font(.nw(.caption))
                .foregroundStyle(nw.done)
                .lineLimit(1)
        case .update:
            NWUpdatePill()
        }
    }
}

/// A skill on skills.sh before it's installed: what it does, how the agent will use it, Install on
/// every host with each host's progress, its SKILL.md and files, and the rest of its repository.
struct SkillResultScreen: View {
    let skill: DirectorySkill
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator
    @Environment(\.openURL) private var openURL
    @State private var preview: DirectoryPreview?
    @State private var lines: [SkillFileLine] = []
    /// How many lines the SKILL.md has in all.
    @State private var lineCount = 0
    @State private var unavailable = false
    @State private var invocation: SkillInvocation = .automatic

    var body: some View {
        let store = SettingsStore.of(hosts)
        let model = store.skills
        let skillsHosts = store.skillsHosts
        let nw = Color.nw
        ScrollView {
            VStack(alignment: .leading, spacing: MobileLayout.sectionSpacing) {
                VStack(alignment: .leading, spacing: NW.Space.s) {
                    HStack(spacing: NW.Space.s) {
                        Text(skill.name)
                            .font(.nwMono(MobileLayout.skillTitleSize, .semibold))
                            .foregroundStyle(nw.textPrimary)
                            .textSelection(.enabled)
                        if skill.official { NWOfficialSeal(size: MobileLayout.skillSummarySize) }
                    }
                    Text(SkillsPresentation.resultMeta(skill))
                        .font(.nw(.caption))
                        .foregroundStyle(nw.textTertiary)
                    if let summary = preview?.summary {
                        Text(summary)
                            .nwText(.body)
                            .foregroundStyle(nw.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, NW.Space.xs)
                    }
                }
                .padding(.horizontal, NW.Space.xs)
                installBlock(model: model, hosts: skillsHosts)
                if let preview {
                    SettingsSection("SKILL.md") {
                        SkillFilePreview(lines: lines, total: lineCount, tokens: preview.tokens)
                    }
                    if !preview.entries.isEmpty {
                        SettingsSection("Files") {
                            SkillFileChips(entries: preview.entries)
                            SettingsFootnote(SkillsPresentation.scriptsNote(paths: preview.paths))
                        }
                    }
                } else if unavailable {
                    SettingsFootnote("skills.sh didn't send this skill's files. It can still be installed.")
                } else {
                    ProgressView().progressViewStyle(NWSpinnerStyle())
                        .frame(maxWidth: .infinity)
                }
                VStack(alignment: .leading, spacing: NW.Space.m) {
                    Button("Pick from all of \(skill.source)") { navigator.open(.settings(.skillsRepo(skill.source))) }
                        .buttonStyle(.nwLink(font: .nw(.caption, weight: .medium)))
                    Button("View on skills.sh") { openURL(SkillsDirectory.page(of: skill)) }
                        .buttonStyle(.nwLink(font: .nw(.caption, weight: .medium)))
                }
                .padding(.horizontal, NW.Space.xs)
            }
            .padding(.horizontal, MobileLayout.gutter)
            .padding(.bottom, MobileLayout.sectionSpacing)
            .frame(maxWidth: MobileLayout.homeMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .background(Color.nw.bgWindow)
        .nwAnimation(.disclosure, value: model.installs[skill.id])
        .navigationTitle(skill.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.watch() }
        .task { await load() }
    }

    /// Install with how the agent will use it and where it goes; once it's going, each host's
    /// progress; once it's there, Installed (or Update) and a way to the skill itself.
    @ViewBuilder
    private func installBlock(model: ClientSkills, hosts: [SkillsHost]) -> some View {
        let state = SkillResultState(skill, model: model, hosts: hosts)
        VStack(alignment: .leading, spacing: MobileLayout.blockSpacing) {
            switch state {
            case .install, .installing:
                NWListCard {
                    SettingsControlRow("Use it", note: invocation == .automatic
                                       ? "The agent reads it when a task calls for it."
                                       : "Only when you type /skill:\(skill.slug).") {
                        SettingsPicker("Use it", selection: invocation, options: [SkillInvocation.automatic, .slashOnly],
                                       title: SkillsPresentation.invocationTitle) { invocation = $0 }
                    }
                }
                Button {
                    let choice = invocation
                    Task { await model.install(skill.id, source: skill.source, skill: skill.slug, invocation: choice, in: hosts) }
                } label: {
                    Label("Install", systemImage: "arrow.down.to.line")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.nw(.primary, size: .l))
                .disabled(state != .install || model.targets(in: hosts).isEmpty)
                if case .install = state {
                    SettingsFootnote(SkillsPresentation.destinations(model.targets(in: hosts)))
                }
            case .installed:
                HStack(spacing: NW.Space.m) {
                    Label("Installed", systemImage: "checkmark")
                        .font(.nw(.ui, weight: .medium))
                        .foregroundStyle(Color.nw.done)
                    Spacer(minLength: NW.Space.m)
                    Button("Open") { navigator.open(.settings(.skill(skill.slug))) }
                        .buttonStyle(.nw(.secondary))
                }
                .padding(.horizontal, NW.Space.xs)
            case .update:
                Button {
                    Task { await model.update(skill.slug, in: hosts) }
                } label: {
                    Label("Update", systemImage: "arrow.down.to.line")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.nw(.primary, size: .l))
                .disabled(model.row(skill.slug, in: hosts)?.isUpdating == true)
            }
            if let install = model.installs[skill.id], install.isRunning || install.failure != nil {
                SkillInstallSteps(install: install) { model.cancelInstall(skill.id) }
                    .nwTransition(.disclosure)
            }
        }
    }

    private func load() async {
        guard preview == nil else { return }
        do {
            let files = try await SkillsDirectory().files(of: skill)
            let loaded = DirectoryPreview(skill: skill, files: files)
            lines = SkillFileLine.lines(loaded.instructions, limit: MobileLayout.skillPreviewLines)
            lineCount = InstructionsText.lines(loaded.instructions).count
            preview = loaded
        } catch {
            unavailable = true
        }
    }
}

// MARK: One skill

/// One installed skill: on or off, how the agent uses it, its version (and Update while a newer
/// commit waits), which hosts have it, its files, and Remove, which Undo on the list takes back.
struct SkillDetailScreen: View {
    let name: String
    @Environment(MobileHosts.self) private var hosts
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let store = SettingsStore.of(hosts)
        let model = store.skills
        let skillsHosts = store.skillsHosts
        ScrollView {
            VStack(alignment: .leading, spacing: MobileLayout.sectionSpacing) {
                if let row = model.row(name, in: skillsHosts) {
                    content(row, model: model, hosts: skillsHosts)
                } else if model.reference(in: skillsHosts) == nil {
                    ProgressView().progressViewStyle(NWSpinnerStyle())
                        .frame(maxWidth: .infinity)
                } else {
                    SettingsFootnote("No host has \(name) now.")
                }
            }
            .padding(.horizontal, MobileLayout.gutter)
            .padding(.bottom, MobileLayout.sectionSpacing)
            .frame(maxWidth: MobileLayout.homeMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await store.refresh() }
        .background(Color.nw.bgWindow)
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.watch() }
    }

    @ViewBuilder
    private func content(_ row: SkillRow, model: ClientSkills, hosts: [SkillsHost]) -> some View {
        let nw = Color.nw
        let skill = row.skill
        VStack(alignment: .leading, spacing: NW.Space.s) {
            Text(skill.name)
                .font(.nwMono(MobileLayout.skillTitleSize, .semibold))
                .foregroundStyle(nw.textPrimary)
                .textSelection(.enabled)
            if !skill.summary.isEmpty {
                Text(skill.summary)
                    .nwText(.body)
                    .foregroundStyle(nw.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, NW.Space.xs)
        if let problem = model.problem {
            NWBanner(.failed, title: problem) {
                Button("OK") { model.dismissProblem() }.buttonStyle(.nw(.secondary))
            }
        }
        NWListCard {
            SettingsSwitchRow("On", note: skill.isOn ? "Agents can use it." : "No agent sees it until it's back on.",
                              isOn: skill.isOn) { on in
                model.setOn(skill.name, on, in: hosts)
            }
        }
        SettingsSection("Use it") {
            VStack(alignment: .leading, spacing: NW.Space.l) {
                NWRadioOption("Automatically", note: SkillsPresentation.automaticNote(skill, directory: model.directory(in: hosts)),
                              selected: skill.invocation == .automatic) {
                    model.setInvocation(skill.name, .automatic, in: hosts)
                }
                NWRadioOption(SkillsPresentation.slashOption(skill.name), note: "Stays out of the agent’s prompt until you call it.",
                              selected: skill.invocation == .slashOnly) {
                    model.setInvocation(skill.name, .slashOnly, in: hosts)
                }
            }
            .padding(NW.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .nwCard(radius: NWListMetrics.cardRadius)
        }
        SettingsSection("Version") {
            SkillVersionCard(row: row) {
                Task { await model.update(skill.name, in: hosts) }
            }
        }
        SettingsSection("Hosts") {
            NWListCard {
                ForEach(model.copies(of: skill.name, in: hosts)) { copy in
                    SkillHostLine(copy: copy)
                }
            }
        }
        if !skill.files.isEmpty {
            SettingsSection("Files") {
                SkillFileChips(entries: skill.files)
                SettingsFootnote(SkillsPresentation.scriptsNote(entries: skill.files))
            }
        }
        Button {
            model.remove(skill.name, in: hosts)
            dismiss()
        } label: {
            Label(hosts.count > 1 ? "Remove from every host" : "Remove", systemImage: "trash")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.nw(.danger, size: .l))
        .accessibilityHint("Undo on the Skills list puts it back.")
    }
}

/// Where a skill comes from: its repository and folder, the commit installed, and the newer one
/// with Update and What changed; or Local, for a folder copied in by hand.
private struct SkillVersionCard: View {
    let row: SkillRow
    let update: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        let nw = Color.nw
        let skill = row.skill
        VStack(alignment: .leading, spacing: NW.Space.s) {
            if let source = skill.source {
                Text(source.path.isEmpty ? source.repo : "\(source.repo) › \(source.path)")
                    .font(.nw(.mono))
                    .foregroundStyle(nw.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                let installed = SkillsPresentation.installed(source)
                Text("Installed \(installed.commit)" + (installed.date.map { " · \($0)" } ?? ""))
                    .font(.nw(.caption))
                    .foregroundStyle(nw.textTertiary)
                if let newer = skill.update {
                    let words = SkillsPresentation.newer(newer)
                    Text("New \(words.commit) · \(words.detail)")
                        .font(.nw(.caption))
                        .foregroundStyle(nw.lanternText)
                    HStack(spacing: NW.Space.m) {
                        Button(action: update) {
                            Label(row.isUpdating ? "Updating…" : "Update", systemImage: "arrow.down.to.line")
                        }
                        .buttonStyle(.nw(.primary))
                        .disabled(row.isUpdating)
                        if let compare = SkillsText.compareURL(repo: source.repo, from: source.commit, to: newer.commit) {
                            Button("What changed") { openURL(compare) }
                                .buttonStyle(.nw(.ghost))
                        }
                    }
                    .padding(.top, NW.Space.xs)
                }
            } else {
                Label("Local", systemImage: "folder")
                    .font(.nw(.ui))
                    .foregroundStyle(nw.textSecondary)
                Text("Copied into the skills folder by hand. It never updates.")
                    .font(.nw(.caption))
                    .foregroundStyle(nw.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(NW.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nwCard(radius: NWListMetrics.cardRadius)
    }
}

/// A host's line in a skill's Hosts: its name and where it is with the skill ("installed",
/// "offline · updates later").
private struct SkillHostLine: View {
    let copy: SkillCopy

    var body: some View {
        let nw = Color.nw
        HStack(spacing: NW.Space.l) {
            Image(systemName: "desktopcomputer")
                .font(.nw(.caption, weight: .medium))
                .foregroundStyle(nw.textSecondary)
                .frame(width: NWListMetrics.leadingWidth)
                .accessibilityHidden(true)
            Text(copy.name)
                .font(.nwMono(NWTextStyle.ui.size))
                .foregroundStyle(nw.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(SkillsPresentation.copy(copy.state))
                .font(.nw(.caption))
                .foregroundStyle(tone)
                .lineLimit(1)
        }
        .padding(.horizontal, NW.Space.l)
        .frame(maxWidth: .infinity, minHeight: MobileLayout.instructionsHostRowHeight, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var tone: Color {
        switch copy.state {
        case .installed: Color.nw.done
        case .updating, .checking: Color.nw.running
        case .missing, .owed, .offline, .unsupported: Color.nw.textTertiary
        }
    }
}

// MARK: Add from repo

/// Add skills from a repository: a GitHub owner/repo or URL, looked up on a host (which fetches
/// it); its skills to pick from (the ones already installed stay ticked and dimmed), how the agent
/// will use them, and Install N skills on every host, with each host's progress.
struct AddSkillsScreen: View {
    let initialRepo: String?
    @Environment(MobileHosts.self) private var hosts
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var found: RepoSkills?
    @State private var lookingUp = false
    @State private var problem: String?
    @State private var picked: Set<String> = []
    @State private var invocation: SkillInvocation = .automatic
    @State private var installKey: String?

    var body: some View {
        let store = SettingsStore.of(hosts)
        let model = store.skills
        let skillsHosts = store.skillsHosts
        ScrollView {
            VStack(alignment: .leading, spacing: MobileLayout.sectionSpacing) {
                VStack(alignment: .leading, spacing: MobileLayout.blockSpacing) {
                    Text("A GitHub owner/repo or URL. Shepherd copies the skills you pick into ~/.agents/skills on every host.")
                        .nwText(.caption)
                        .foregroundStyle(Color.nw.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, NW.Space.xs)
                    HStack(spacing: NW.Space.m) {
                        TextField("owner/repo or a GitHub URL", text: $input)
                            .font(.nw(.code))
                            .foregroundStyle(Color.nw.textPrimary)
                            .tint(Color.nw.lantern)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .submitLabel(.search)
                            .onSubmit { Task { await lookUp(model: model, hosts: skillsHosts) } }
                            .padding(.horizontal, NW.Space.l)
                            .frame(minHeight: MobileLayout.skillRepoFieldHeight)
                            .background(Color.nw.bgRaised, in: RoundedRectangle(cornerRadius: NW.Radius.l))
                            .nwBorder(Color.nw.lineStrong, radius: NW.Radius.l)
                            .accessibilityLabel("Repository")
                        Button("Look up") { Task { await lookUp(model: model, hosts: skillsHosts) } }
                            .buttonStyle(.nw(.secondary, size: .l))
                            .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || lookingUp)
                    }
                    if let problem {
                        SettingsFootnote(problem, tone: .failed)
                    }
                }
                if lookingUp {
                    ProgressView().progressViewStyle(NWSpinnerStyle())
                        .frame(maxWidth: .infinity)
                } else if let found {
                    picker(found, model: model, hosts: skillsHosts)
                    footer(found, model: model, hosts: skillsHosts)
                }
            }
            .padding(.horizontal, MobileLayout.gutter)
            .padding(.bottom, MobileLayout.sectionSpacing)
            .frame(maxWidth: MobileLayout.homeMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.nw.bgWindow)
        .nwAnimation(.disclosure, value: installKey.flatMap { model.installs[$0] })
        .navigationTitle("Add from repo")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.watch() }
        .task {
            guard let initialRepo, input.isEmpty else { return }
            input = initialRepo
            await lookUp(model: model, hosts: skillsHosts)
        }
    }

    /// "3 of 13 new skills" with Select all new, then each skill to tick.
    @ViewBuilder
    private func picker(_ found: RepoSkills, model: ClientSkills, hosts: [SkillsHost]) -> some View {
        let newPaths = found.skills.filter { model.row($0.name, in: hosts) == nil }.map(\.path)
        VStack(alignment: .leading, spacing: MobileLayout.headerSpacing) {
            NWListHeader(SkillsPresentation.selection(picked.count, new: newPaths.count)) {
                Button("Select all new") { picked = Set(newPaths) }
                    .buttonStyle(.nwLink(font: .nw(.caption, weight: .medium)))
                    .disabled(newPaths.isEmpty || picked.count == newPaths.count)
            }
            LazyVStack(spacing: 0) {
                ForEach(Array(found.skills.enumerated()), id: \.element.id) { index, skill in
                    let installed = model.row(skill.name, in: hosts)
                    SkillPickLine(skill: skill, picked: installed != nil || picked.contains(skill.path),
                                  installed: installed.map { $0.skill.update == nil ? "Installed" : "Installed · update" },
                                  first: index == 0) {
                        if picked.contains(skill.path) { picked.remove(skill.path) } else { picked.insert(skill.path) }
                    }
                    .equatable()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: NWListMetrics.cardRadius))
            .nwCard(radius: NWListMetrics.cardRadius)
            SettingsFootnote(SkillsPresentation.repoLine(found))
        }
    }

    /// How the agent will use them, where they go (or each host's progress), and Install.
    @ViewBuilder
    private func footer(_ found: RepoSkills, model: ClientSkills, hosts: [SkillsHost]) -> some View {
        let install = installKey.flatMap { model.installs[$0] }
        VStack(alignment: .leading, spacing: MobileLayout.blockSpacing) {
            NWListCard {
                SettingsControlRow("Use them") {
                    SettingsPicker("Use them", selection: invocation, options: [SkillInvocation.automatic, .slashOnly],
                                   title: SkillsPresentation.invocationTitle) { invocation = $0 }
                }
            }
            if let install {
                SkillInstallSteps(install: install) {
                    if let installKey { model.cancelInstall(installKey) }
                }
                    .nwTransition(.disclosure)
            } else {
                SettingsFootnote(SkillsPresentation.destinations(model.targets(in: hosts)))
            }
            Button {
                installPicked(found, model: model, hosts: hosts)
            } label: {
                Text(SkillsPresentation.installTitle(max(picked.count, 1)))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.nw(.primary, size: .l))
            .disabled(picked.isEmpty || install?.isRunning == true)
        }
    }

    private func lookUp(model: ClientSkills, hosts: [SkillsHost]) async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        lookingUp = true
        problem = nil
        found = nil
        picked = []
        installKey = nil
        do {
            let result = try await model.lookUp(text, in: hosts)
            let fresh = result.skills.filter { model.row($0.name, in: hosts) == nil }
            let reference = SkillsText.reference(text)
            if let pointed = fresh.first(where: { $0.path == reference?.path || $0.name == reference?.skill }) {
                picked = [pointed.path]
            } else if fresh.count == 1, let only = fresh.first {
                picked = [only.path]
            }
            found = result
        } catch {
            problem = SkillsScreenText.problem(error)
        }
        lookingUp = false
    }

    /// Installs what's ticked on every host; the screen closes once every host that could take
    /// them has them.
    private func installPicked(_ found: RepoSkills, model: ClientSkills, hosts: [SkillsHost]) {
        guard !picked.isEmpty else { return }
        let key = "repo:\(found.repo)"
        let paths = picked.sorted()
        let use = invocation
        installKey = key
        Task {
            await model.install(key, repo: found.repo, paths: paths, commit: found.commit, invocation: use, in: hosts)
            if let install = model.installs[key], install.failure == nil, !install.cancelled { dismiss() }
        }
    }
}

/// One skill in a repository: its tick, name and description; one already installed stays ticked
/// and dimmed, saying so.
private struct SkillPickLine: View, Equatable {
    let skill: RepoSkill
    let picked: Bool
    let installed: String?
    let first: Bool
    let toggle: () -> Void

    nonisolated static func == (a: SkillPickLine, b: SkillPickLine) -> Bool {
        a.skill == b.skill && a.picked == b.picked && a.installed == b.installed && a.first == b.first
    }

    var body: some View {
        let nw = Color.nw
        let dimmed = installed != nil
        Button(action: toggle) {
            HStack(alignment: .top, spacing: NW.Space.l) {
                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                    .font(.nw(.ui))
                    .foregroundStyle(picked && !dimmed ? nw.running : nw.textTertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: MobileLayout.skillLineSpacing) {
                    HStack(spacing: NW.Space.m) {
                        Text(skill.name)
                            .font(.nwMono(MobileLayout.skillNameSize, .semibold))
                            .foregroundStyle(dimmed ? nw.textTertiary : nw.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let installed {
                            Text(installed)
                                .font(.nw(.caption))
                                .foregroundStyle(installed == "Installed" ? nw.textTertiary : nw.lanternText)
                                .lineLimit(1)
                        }
                    }
                    if !skill.summary.isEmpty {
                        Text(skill.summary)
                            .font(.nwSans(MobileLayout.skillSummarySize))
                            .foregroundStyle(nw.textTertiary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, NW.Space.m)
            .padding(.horizontal, NW.Space.l + NW.Space.xxs)
            .frame(maxWidth: .infinity, minHeight: MobileLayout.skillRowHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.nwRow(radius: 0))
        .disabled(dimmed)
        .overlay(alignment: .top) { if !first { NWHairline() } }
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

// MARK: Shared parts

/// An install on its way to each host: its line ("Installing · 1 of 3 hosts"), Cancel while it
/// runs, and each host's step.
private struct SkillInstallSteps: View {
    let install: SkillInstall
    let cancel: () -> Void

    var body: some View {
        let nw = Color.nw
        VStack(alignment: .leading, spacing: MobileLayout.headerSpacing) {
            HStack(spacing: NW.Space.m) {
                Text(SkillsPresentation.installLine(install))
                    .font(.nw(.caption, weight: .semibold))
                    .foregroundStyle(install.failure != nil && install.installed == 0 ? nw.failed : nw.textSecondary)
                    .nwShimmer(active: install.isRunning)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: NW.Space.m)
                if install.isRunning {
                    Button("Cancel", action: cancel)
                        .buttonStyle(.nwLink(font: .nw(.caption, weight: .medium)))
                }
            }
            .padding(.horizontal, NW.Space.xs)
            NWListCard {
                ForEach(install.steps) { step in
                    HStack(spacing: NW.Space.l) {
                        Image(systemName: "desktopcomputer")
                            .font(.nw(.caption, weight: .medium))
                            .foregroundStyle(nw.textSecondary)
                            .frame(width: NWListMetrics.leadingWidth)
                            .accessibilityHidden(true)
                        Text(step.name)
                            .font(.nwMono(NWTextStyle.ui.size))
                            .foregroundStyle(nw.textPrimary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(SkillsPresentation.step(step.state))
                            .font(.nw(.caption))
                            .foregroundStyle(Self.tone(step.state))
                            .multilineTextAlignment(.trailing)
                            .lineLimit(2)
                    }
                    .padding(.horizontal, NW.Space.l)
                    .frame(maxWidth: .infinity, minHeight: MobileLayout.instructionsHostRowHeight, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private static func tone(_ state: SkillInstall.Step.State) -> Color {
        switch state {
        case .installed: Color.nw.done
        case .copying: Color.nw.running
        case .waiting, .owed: Color.nw.textTertiary
        case .failed: Color.nw.failed
        }
    }
}

/// A skill's top-level files as chips: SKILL.md, its documents, and its folders with their counts.
private struct SkillFileChips: View {
    let entries: [SkillFileEntry]

    var body: some View {
        NWWrapStack(spacing: NW.Space.s, lineSpacing: NW.Space.s) {
            ForEach(entries) { entry in
                NWSkillFileChip(SkillsPresentation.chip(entry), count: entry.isDirectory ? entry.fileCount : nil,
                                kind: entry.isDirectory ? (entry.name == "scripts" ? .code : .folder) : .file)
            }
        }
    }
}

/// A SKILL.md, read-only: its header (the file and what it costs when used), then its first lines
/// numbered and lightly highlighted as the instructions editor does, and how many more there are.
private struct SkillFilePreview: View {
    let lines: [SkillFileLine]
    let total: Int
    let tokens: Int

    var body: some View {
        let nw = Color.nw
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: NW.Space.m) {
                Image(systemName: "doc.text")
                    .font(.nw(.caption))
                    .foregroundStyle(nw.textTertiary)
                    .accessibilityHidden(true)
                Text("SKILL.md")
                    .font(.nw(.mono))
                    .foregroundStyle(nw.textSecondary)
                Spacer(minLength: NW.Space.m)
                if tokens > 0 {
                    Text("\(SkillsText.tokenNote(tokens)) when used")
                        .font(.nw(.caption))
                        .foregroundStyle(nw.textTertiary)
                }
            }
            .padding(.horizontal, NW.Space.l)
            .frame(height: MobileLayout.skillPreviewHeaderHeight)
            .background(nw.bgSunken)
            .overlay(alignment: .bottom) { NWHairline() }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text("\(line.number)")
                            .font(.nwMono(MobileLayout.instructionsNumberSize))
                            .foregroundStyle(nw.textTertiary)
                            .frame(width: MobileLayout.skillPreviewGutter - NW.Space.m, alignment: .trailing)
                            .padding(.trailing, NW.Space.m)
                        Text(line.text)
                            .font(.nwMono(MobileLayout.skillPreviewTextSize))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: MobileLayout.skillPreviewLineHeight, alignment: .leading)
                }
                if total > lines.count {
                    Text("\(total - lines.count) more \(total - lines.count == 1 ? "line" : "lines")")
                        .font(.nw(.caption))
                        .foregroundStyle(nw.textTertiary)
                        .padding(.top, NW.Space.s)
                        .padding(.leading, MobileLayout.skillPreviewGutter)
                }
            }
            .padding(.vertical, NW.Space.m)
            .padding(.trailing, NW.Space.l)
            .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(nw.bgWindow)
        .clipShape(RoundedRectangle(cornerRadius: NWListMetrics.cardRadius))
        .nwBorder(nw.lineSubtle, radius: NWListMetrics.cardRadius)
    }
}

/// One line of a previewed SKILL.md, highlighted once when the file arrives.
struct SkillFileLine: Identifiable, Equatable {
    let number: Int
    let text: AttributedString

    var id: Int { number }

    /// The file's first `limit` lines, with the instructions editor's highlighting.
    @MainActor
    static func lines(_ text: String, limit: Int) -> [SkillFileLine] {
        let nw = Color.nw
        return InstructionsText.lines(text).prefix(limit).enumerated().map { index, line in
            var styled = AttributedString(line)
            styled.foregroundColor = nw.textSecondary
            let units = line.utf16
            for span in InstructionsText.highlight(line: line) {
                guard let start = units.index(units.startIndex, offsetBy: span.range.lowerBound, limitedBy: units.endIndex),
                      let end = units.index(units.startIndex, offsetBy: span.range.upperBound, limitedBy: units.endIndex),
                      let lower = AttributedString.Index(start, within: styled),
                      let upper = AttributedString.Index(end, within: styled), lower < upper else { continue }
                switch span.role {
                case .headingMarker: styled[lower..<upper].foregroundColor = nw.textTertiary
                case .heading: styled[lower..<upper].foregroundColor = nw.textPrimary
                case .bullet: styled[lower..<upper].foregroundColor = nw.lanternText
                case .code: styled[lower..<upper].foregroundColor = nw.synString
                }
            }
            return SkillFileLine(number: index + 1, text: styled)
        }
    }
}

private enum SkillsScreenText {
    /// A failure in words: the host's own reason, else what went wrong.
    static func problem(_ error: Error) -> String {
        if case RemoteHostClientError.rejected(_, let message) = error { return message }
        return "The host didn't answer. Try again once it's connected."
    }
}
