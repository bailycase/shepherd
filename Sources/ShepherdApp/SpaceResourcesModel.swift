import Foundation
import ShepherdProtocol
import ShepherdRemote

/// The space Resources tab (ProjectSkills, ProjectSlashCommands, ProjectSubagents, ProjectExtensions
/// boards): the space's own resource files and the host's global ones. Every edit, toggle and
/// removal is a draft until Save changes writes it to the same files pi reads: the resource files
/// themselves, and for a skill, template or extension's toggle the space `settings.json`'s
/// `skills`/`prompts`/`extensions` patterns (`ProjectResourcePatterns`), as `pi config` writes them.
@MainActor @Observable
final class SpaceResourcesModel {
    typealias Kind = ProjectResource.Kind
    typealias Send = @MainActor (RemoteProjectsRequest) async throws -> RemoteProjectsResult
    enum Scope: String { case all, space, inherited }

    struct Row: Equatable, Identifiable {
        var id: String
        var resource: ProjectResource
        var displayName: String
        var detail: String
        var enabled: Bool
        var canToggle: Bool
        /// The parent space a skill, slash command or extension is inherited from (ProjectChildSkills),
        /// and for a space one, the parent whose one of the same name it overrides.
        var inheritedFrom: String? = nil
        var overrides: String? = nil
        var local: Bool { !resource.global && inheritedFrom == nil }
    }

    /// The board's editor dialog (ProjectResourceEditor): one resource's fields.
    struct Editor: Equatable {
        var kind: Kind
        /// The space file being edited; nil for a new one.
        var path: String?
        var name = ""
        var description = ""
        var body = ""
        var arguments = ""
        var automatic = true
        var model = ""
        var thinking = ""
        var tools = ["read", "grep", "find", "ls"]
        var context = "fresh"
        var promptMode = "append"
        var inheritContext = true
        /// An extension's file chosen on this Mac, copied to the space's `.pi/extensions`.
        var file = ""
        var fileText: String?
        var error: String?
        var original = ""
        var isNew: Bool { path == nil }
        var destination: String {
            if let path { return path }
            switch kind {
            case .skill: return ".pi/skills/\(name.isEmpty ? "<name>" : name)/SKILL.md"
            case .prompt: return ".pi/prompts/\(name.isEmpty ? "<command>" : name).md"
            case .agent: return ".pi/agents/\(name.isEmpty ? "<name>" : name).md"
            case .extension: return ".pi/" + (file.isEmpty ? "extensions/<file>.ts" : file)
            }
        }
    }

    /// Add from repo (ProjectSkillAdd board).
    struct Install: Equatable {
        var repository = ""
        var revision = ""
        var candidates: [RepoSkill]?
        var selected: Set<String> = []
        var error: String?
        var busy = false
    }

    static let tools = ["read", "grep", "find", "ls", "bash", "edit", "write"]

    var kind: Kind = .skill { didSet { if kind != oldValue { query = ""; derive() } } }
    var query = "" { didSet { if query != oldValue { derive() } } }
    var scope: Scope = .all { didSet { if scope != oldValue { derive() } } }
    private(set) var rows: [Row] = []
    private(set) var spaceCount = 0
    private(set) var inheritedCount = 0
    private(set) var loaded: [ProjectResource] = []
    private(set) var loadedOnce = false
    private(set) var loading = false
    private(set) var saving = false
    /// A load, save or install that failed; `conflict` when a file changed elsewhere.
    var message: String?
    private(set) var conflict = false
    var editor: Editor?
    var removing: Row?
    var install: Install?
    /// Discard changes (or Reload latest, `reloading`) waiting for the board's confirmation.
    var confirmingDiscard = false
    var reloading = false
    /// Each file's text as last read from the host, by path; nil for a file that isn't there.
    @ObservationIgnored private(set) var saved: [String: String?] = [:]
    /// The draft: a file's new text, or nil to remove it, by path.
    private(set) var writes: [String: String?] = [:]
    /// The parent space this child inherits from, its skills, slash commands and extensions, and the
    /// ones this space turned off (`ProjectsModel.setInherited`, saved at once, not with the draft).
    private(set) var parent: (name: String, directory: String)?
    private(set) var parentResources: [ProjectResource] = []
    /// What inherits: skills from every host that shares them, slash commands and extensions only
    /// from one with `projectInheritedResourcesCapability`.
    var inheritedKinds: Set<Kind> = [.skill] { didSet { if inheritedKinds != oldValue { derive() } } }
    var excluded = SpaceInheritanceExclusions() { didSet { if excluded != oldValue { derive() } } }
    var canExcludeInherited = false { didSet { if canExcludeInherited != oldValue { derive() } } }
    @ObservationIgnored var setInherited: @MainActor (_ kind: Kind, _ name: String, _ on: Bool) async -> Void = { _, _, _ in }
    private(set) var settingsPath = ".shepherd/settings.json"
    private(set) var settingsSaved: String?
    private(set) var settingsDraft = ""
    @ObservationIgnored private var send: Send?
    @ObservationIgnored private(set) var directory = ""
    @ObservationIgnored var lookUpSkills: @MainActor (String) async throws -> RepoSkills = { _ in
        throw ProjectFileError("unsupported", "Adding skills from a repository is unavailable on this host.")
    }

    var dirty: Bool { !writes.isEmpty || settingsDraft != (settingsSaved ?? "") }

    // MARK: Loading

    /// Reads the resources and the space settings file pi uses (`settingsPath`: the first of
    /// `.shepherd/settings.json` and `.pi/settings.json` that exists). `keep` keeps the draft.
    func load(directory: String, settingsPath: String, parent: (name: String, directory: String)? = nil, keep: Bool = false, send: @escaping Send) async {
        self.send = send; self.directory = directory; self.settingsPath = settingsPath; self.parent = parent
        if !keep { writes = [:]; saved = [:]; editor = nil; removing = nil; install = nil; confirmingDiscard = false }
        loading = true; message = nil; conflict = false
        defer { loading = false }
        do {
            guard case .resources(let list) = try await send(.resources(directory: directory)),
                  case .text(let settings) = try await send(.read(directory: directory, file: settingsPath)) else {
                throw ProjectFileError("protocol", "Unexpected space resources reply.")
            }
            loaded = list
            // Subagents never inherit; a parent that can't be read shares nothing here.
            if let parent, case .resources(let inherited)? = try? await send(.resources(directory: parent.directory)) {
                parentResources = inherited.filter { !$0.global && $0.kind != .agent }
            } else { parentResources = [] }
            if !keep || settingsDraft == (settingsSaved ?? "") { settingsDraft = settings.text ?? "" }
            settingsSaved = settings.text
            loadedOnce = true
        } catch {
            if !keep { loaded = [] }
            message = String(describing: error)
        }
        derive()
    }

    func reloadKeepingDraft() async {
        guard let send else { return }
        await load(directory: directory, settingsPath: settingsPath, parent: parent, keep: true, send: send)
    }

    func reset() { writes = [:]; saved = [:]; settingsDraft = settingsSaved ?? ""; editor = nil; removing = nil; install = nil; confirmingDiscard = false; message = nil; conflict = false; derive() }

    // MARK: Rows

    /// The draft's space resources (loaded files with edits applied, removals gone, new files
    /// added), then the host's global ones.
    var items: [ProjectResource] {
        var space = loaded.filter { !$0.global }.compactMap { item -> ProjectResource? in
            guard let write = writes[item.path] else { return item }
            return write.map { ProjectResource(kind: item.kind, path: item.path, text: $0) }
        }
        for (path, text) in writes.sorted(by: { $0.key < $1.key }) where !loaded.contains(where: { !$0.global && $0.path == path }) {
            if let text, let kind = Self.kind(of: path) { space.append(ProjectResource(kind: kind, path: path, text: text)) }
        }
        return space + loaded.filter(\.global)
    }

    private var settingsObject: [String: Any] { SpaceSettingsForm.parse(settingsDraft.isEmpty ? "{}" : settingsDraft) ?? [:] }
    private var settingsBase: String { directory + "/" + (settingsPath as NSString).deletingLastPathComponent }

    func enabled(_ item: ProjectResource) -> Bool {
        guard let key = item.kind.settingsKey else { return item.enabled }
        let entries = settingsObject[key] as? [String] ?? []
        return ProjectResourcePatterns.isEnabled(item.global ? item.path : directory + "/" + item.path,
                                                 entries: entries, base: settingsBase, otherwise: item.global ? item.enabled : true)
    }

    /// A skill's folder name, which pi and `shepherd-mcp-parent.ts` know it by.
    static func skillFolder(_ path: String) -> String { ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent }

    /// The name a child turns an inherited resource off by, and overrides it by: a skill's folder,
    /// a template's command, an extension's file name (`SpaceInheritanceExclusions`).
    static func inheritanceName(_ resource: ProjectResource) -> String {
        switch resource.kind {
        case .skill: skillFolder(resource.path)
        case .prompt: ((resource.path as NSString).lastPathComponent as NSString).deletingPathExtension
        case .agent, .extension: (resource.path as NSString).lastPathComponent
        }
    }

    /// Where Override here puts a copy of an inherited resource in this space.
    static func overridePath(_ resource: ProjectResource) -> String {
        switch resource.kind {
        case .skill: ".pi/skills/\(inheritanceName(resource))/SKILL.md"
        case .prompt: ".pi/prompts/\(inheritanceName(resource)).md"
        case .agent: ".pi/agents/\(inheritanceName(resource))"
        case .extension: ".pi/extensions/\(inheritanceName(resource))"
        }
    }

    func isExcluded(_ resource: ProjectResource) -> Bool {
        let name = Self.inheritanceName(resource)
        switch resource.kind {
        case .skill: return excluded.skills.contains(name)
        case .prompt: return excluded.prompts.contains(name)
        case .extension: return excluded.extensions.contains(name)
        case .agent: return false
        }
    }

    func derive() {
        let own = items.filter { $0.kind == kind }
        // The parent's ones a space one of the same name doesn't override, after the space's own.
        let spaceNames = Set(own.filter { !$0.global }.map(Self.inheritanceName))
        let parentItems = inheritedKinds.contains(kind) ? parentResources.filter { $0.kind == kind } : []
        let parentNames = Set(parentItems.map(Self.inheritanceName))
        let inherited = parentItems.filter { !spaceNames.contains(Self.inheritanceName($0)) }
        let all = own.filter { !$0.global } + inherited + own.filter(\.global)
        let fromParent = Set(inherited.map(\.path))
        spaceCount = own.filter { !$0.global }.count
        inheritedCount = all.count - spaceCount
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = all.compactMap { item -> Row? in
            let isParent = !item.global && fromParent.contains(item.path) && !spaceNames.contains(Self.inheritanceName(item))
            guard scope == .all || (scope == .space) == (!item.global && !isParent),
                  query.isEmpty || "\(item.name) \(item.description) \(item.displayPath)".localizedCaseInsensitiveContains(query) else { return nil }
            let displayName = item.kind == .prompt ? "/" + item.name : item.name
            if isParent {
                return Row(id: "parent:" + item.path, resource: item, displayName: displayName,
                           detail: item.kind == .prompt ? "Prompt template" : item.displayPath,
                           enabled: !isExcluded(item), canToggle: canExcludeInherited, inheritedFrom: parent?.name)
            }
            return Row(id: item.id, resource: item, displayName: displayName,
                       detail: item.kind == .agent ? item.detail : item.kind == .prompt ? "Prompt template" : item.displayPath,
                       enabled: enabled(item), canToggle: !(item.global && item.kind == .agent),
                       overrides: !item.global && parentNames.contains(Self.inheritanceName(item)) ? parent?.name : nil)
        }
        if next != rows { rows = next }
    }

    static func kind(of path: String) -> Kind? {
        let parts = path.split(separator: "/")
        guard parts.count >= 3 else { return nil }
        switch parts[1] {
        case "skills": return .skill
        case "prompts": return .prompt
        case "agents": return .agent
        case "extensions": return .extension
        default: return nil
        }
    }

    // MARK: Draft edits

    private func setWrite(_ path: String, _ text: String?) {
        let original = saved[path] ?? nil
        if text == original { writes[path] = nil } else { writes[path] = .some(text) }
        derive()
    }

    /// The file's draft text, reading it from the host the first time.
    private func text(_ path: String) async throws -> String? {
        if let write = writes[path] { return write }
        if let known = saved[path] { return known }
        guard let send, case .text(let value) = try await send(.read(directory: directory, file: path)) else {
            throw ProjectFileError("protocol", "Unexpected space file reply.")
        }
        saved[path] = .some(value.text)
        return value.text
    }

    func toggle(_ row: Row, on: Bool) async {
        guard row.canToggle else { return }
        if row.inheritedFrom != nil { await setInherited(row.resource.kind, Self.inheritanceName(row.resource), on); return }
        let item = row.resource
        if let key = item.kind.settingsKey {
            var object = settingsObject
            let entries = ProjectResourcePatterns.setting(on, path: item.global ? item.path : directory + "/" + item.path, global: item.global,
                                                          inherited: item.enabled, base: settingsBase, in: object[key] as? [String] ?? [])
            object[key] = entries.isEmpty ? nil : entries
            if let saved = settingsSaved, let original = SpaceSettingsForm.parse(saved), NSDictionary(dictionary: original).isEqual(to: object) {
                settingsDraft = saved
            } else if settingsSaved == nil, object.isEmpty {
                settingsDraft = ""
            } else if let text = SpaceSettingsForm.serialize(object) {
                settingsDraft = text
            }
            derive()
        } else {
            do {
                var profile = SubagentProfileText(try await text(item.path) ?? "")
                profile.set("disabled", bool: on ? nil : true)
                setWrite(item.path, profile.text)
            } catch { message = String(describing: error) }
        }
    }

    /// Override here: the parent's skill, slash command or extension, copied into this space's `.pi`
    /// as a draft, where it wins by name. Reset to inherited removes that copy.
    func overrideInherited(_ row: Row) async {
        guard let parent, row.inheritedFrom != nil, let send else { return }
        let path = Self.overridePath(row.resource)
        do {
            guard case .text(let value) = try await send(.read(directory: parent.directory, file: row.resource.path)), let text = value.text else {
                throw ProjectFileError("missing", "\(row.resource.name) is no longer in \(parent.name).")
            }
            _ = try await self.text(path)
            setWrite(path, text)
        } catch { message = String(describing: error) }
    }

    func resetToInherited(_ row: Row) async {
        guard row.overrides != nil, row.local else { return }
        do { _ = try await text(row.resource.path); setWrite(row.resource.path, nil) } catch { message = String(describing: error) }
    }

    func askRemove(_ row: Row) async {
        guard row.local else { return }
        do { _ = try await text(row.resource.path); removing = row } catch { message = String(describing: error) }
    }

    func confirmRemove() {
        guard let row = removing else { return }
        removing = nil
        setWrite(row.resource.path, nil)
    }

    // MARK: Editor

    func create() { editor = Editor(kind: kind, path: nil) }

    func edit(_ row: Row) async {
        guard row.local, row.resource.kind != .extension else { return }
        do {
            let text = try await text(row.resource.path) ?? ""
            editor = Self.editor(row.resource.kind, path: row.resource.path, text: text)
        } catch { message = String(describing: error) }
    }

    static func editor(_ kind: Kind, path: String, text: String) -> Editor {
        let profile = SubagentProfileText(text)
        var editor = Editor(kind: kind, path: path, original: text)
        editor.name = ProjectResource(kind: kind, path: path, text: text).name
        editor.description = profile.scalar("description") ?? ""
        editor.body = profile.body.hasSuffix("\n") ? String(profile.body.dropLast()) : profile.body
        editor.arguments = profile.scalar("argument-hint") ?? ""
        editor.automatic = profile.bool("disable-model-invocation") != true
        editor.model = profile.scalar("model") ?? ""
        editor.thinking = profile.scalar("thinking") ?? ""
        editor.tools = profile.list("tools") ?? ["read", "bash", "edit", "write"]
        editor.context = profile.scalar("defaultContext") ?? profile.scalar("context") ?? "fresh"
        editor.promptMode = profile.scalar("systemPromptMode") ?? "replace"
        editor.inheritContext = profile.bool("inheritProjectContext") ?? false
        return editor
    }

    /// The editor's file text, or why it can't be saved (the board's rules).
    static func text(_ editor: Editor) -> Result<(path: String, text: String), ProjectFileError> {
        func fail(_ message: String) -> Result<(path: String, text: String), ProjectFileError> { .failure(ProjectFileError("invalid", message)) }
        if editor.kind == .extension {
            let name = (editor.file as NSString).lastPathComponent
            guard editor.file == "extensions/" + name, ["ts", "js"].contains((name as NSString).pathExtension),
                  name.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$"#, options: .regularExpression) != nil, let text = editor.fileText else {
                return fail("Choose a .ts or .js file inside .pi/extensions.")
            }
            return .success((".pi/" + editor.file, text))
        }
        guard SkillsText.isValidName(editor.name) else { return fail("Use a name of up to 64 lowercase letters, numbers and single hyphens.") }
        guard !editor.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return fail("Add instructions before saving.") }
        let description = editor.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if editor.kind == .skill, description.isEmpty || description.count > 1024 { return fail("Add a description of up to 1,024 characters.") }
        if editor.kind == .agent, description.isEmpty { return fail("Add a description so the parent knows when to use this subagent.") }
        var profile = SubagentProfileText(editor.original)
        switch editor.kind {
        case .skill:
            profile.set("name", scalar: editor.name)
            profile.set("description", scalar: description)
            profile.set("disable-model-invocation", bool: editor.automatic ? nil : true)
        case .prompt:
            profile.set("description", scalar: description.isEmpty ? nil : description)
            profile.set("argument-hint", scalar: editor.arguments.isEmpty ? nil : editor.arguments)
        case .agent:
            profile.set("name", scalar: editor.name)
            profile.set("description", scalar: description)
            profile.set("tools", list: editor.tools)
            profile.set("model", scalar: editor.model.isEmpty ? nil : editor.model)
            profile.set("thinking", scalar: editor.thinking.isEmpty ? nil : editor.thinking)
            profile.set("context", scalar: nil)
            profile.set("defaultContext", scalar: editor.context)
            profile.set("systemPromptMode", scalar: editor.promptMode)
            profile.set("inheritProjectContext", bool: editor.inheritContext)
        case .extension: break
        }
        profile.body = editor.body + "\n"
        let text = profile.text
        guard text.utf8.count <= 64 * 1024 else { return fail("Instructions must fit within 64 KiB.") }
        return .success((editor.destination, text))
    }

    func saveEditor() {
        guard var editor else { return }
        switch Self.text(editor) {
        case .failure(let error): editor.error = error.description; self.editor = editor
        case .success(let (path, text)):
            let name = editor.kind == .extension ? (path as NSString).lastPathComponent : editor.name
            if editor.isNew, items.contains(where: { $0.kind == editor.kind && ($0.name == name || $0.path == path) }) {
                editor.error = "A resource with this name is already available. Choose another name."
                self.editor = editor
                return
            }
            if editor.isNew, saved[path] == nil { saved[path] = .some(nil) }
            self.editor = nil
            setWrite(path, text)
        }
    }

    // MARK: Add from repo

    func preview() async {
        guard var state = install else { return }
        let repository = state.repository.trimmingCharacters(in: .whitespacesAndNewlines)
        state.busy = true; state.error = nil; install = state
        do {
            let found = try await lookUpSkills(repository)
            guard install?.repository.trimmingCharacters(in: .whitespacesAndNewlines) == repository else { return }
            install?.candidates = found.skills; install?.selected = []
            install?.error = found.skills.isEmpty ? "No skills found in this repository." : nil
        } catch { install?.error = String(describing: error) }
        install?.busy = false
    }

    func installSelected() async {
        guard let state = install, !state.selected.isEmpty, let send else { return }
        let names = (state.candidates ?? []).filter { state.selected.contains($0.path) }.map(\.name)
        if names.contains(where: { name in items.contains { $0.kind == .skill && $0.name == name } }) {
            install?.error = "A selected skill is already available. Rename it or choose another skill."
            return
        }
        install?.busy = true; install?.error = nil
        do {
            let revision = state.revision.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try await send(.installSkills(directory: directory, repo: state.repository.trimmingCharacters(in: .whitespacesAndNewlines),
                                              paths: state.selected.sorted(), commit: revision.isEmpty ? nil : revision))
            install = nil
            await load(directory: directory, settingsPath: settingsPath, parent: parent, keep: true, send: send)
        } catch { install?.error = String(describing: error); install?.busy = false }
    }

    // MARK: Save

    /// Writes each drafted file, then the settings file, each only over the text it was read
    /// with. A file that fails stays in the draft with the ones after it.
    func save() async {
        guard dirty, !saving, let send else { return }
        saving = true; message = nil; conflict = false
        defer { saving = false }
        do {
            for (path, text) in writes.sorted(by: { $0.key < $1.key }) {
                let expected = saved[path] ?? nil
                if let text {
                    _ = try await send(.save(directory: directory, file: path, text: text, expected: expected))
                } else if let expected {
                    _ = try await send(.delete(directory: directory, file: path, expected: expected))
                }
                saved[path] = .some(text); writes[path] = nil
            }
            if settingsDraft != (settingsSaved ?? "") {
                _ = try await send(.save(directory: directory, file: settingsPath, text: settingsDraft, expected: settingsSaved))
                settingsSaved = settingsDraft
            }
            saved = [:]
            await load(directory: directory, settingsPath: settingsPath, parent: parent, keep: true, send: send)
        } catch {
            conflict = (error as? ProjectFileError)?.code == "conflict" || "\(error)".contains("changed elsewhere")
            message = conflict ? "Space resources changed elsewhere. Reload the latest version before saving." : "Could not save. Your changes are still here. \(error)"
            derive()
        }
    }

    /// The board's Discard changes (confirmed): the draft goes; after a conflict the files load again.
    func confirmDiscard() async {
        confirmingDiscard = false
        let reload = reloading
        reloading = false
        reset()
        if reload || conflict, let send { await load(directory: directory, settingsPath: settingsPath, parent: parent, send: send) }
    }
}
