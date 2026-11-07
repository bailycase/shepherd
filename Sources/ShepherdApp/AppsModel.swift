import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions

// Settings › Apps (AppsSettings, AppsAdd boards): the apps saved for every space on this Mac
// (`~/.shepherd/apps.json`) and in each space (`<space>/.shepherd/apps.json`), the package.json
// scripts a space could add, and which apps run now. Files are read off the main thread; the
// page's groups are derived once per load, here, so views only draw them.

@MainActor
@Observable
final class AppsModel {
    /// One section of the page: This Mac's apps, or a space's.
    struct Group: Equatable, Identifiable {
        var scope: AppScope
        /// "On this Mac", or the space's name.
        var title: String
        /// The space's folder; nil for This Mac.
        var root: String?
        var apps: [AppDefinition]
        /// The file couldn't be read as apps: why. Its apps are not shown, and saving is refused
        /// so the file isn't overwritten.
        var problem: String?
        /// package.json scripts the space serves that are not apps yet.
        var suggestions: [DevServer] = []
        var id: AppScope { scope }
        var file: URL? { root.map(AppsFile.url(in:)) }
    }

    /// The home folder `~/.shepherd/apps.json` is under.
    @ObservationIgnored let home: String
    /// This Mac's spaces, read at each load.
    @ObservationIgnored var spaces: () -> [Space] = { [] }
    /// The space Settings was opened from (its selected thread's): listed even with no apps.
    @ObservationIgnored var currentSpace: () -> SpaceID? = { nil }

    private(set) var groups: [Group] = []
    private(set) var loaded = false
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var reloadAgain = false
    /// What each app Shepherd has started is doing (`AppProcesses`, the one owner of app
    /// processes). Never persisted: nothing restarts on the next launch.
    private(set) var processes: [AppKey: AppProcessSnapshot] = [:]
    /// The Add or Edit sheet.
    var editor: AppEditor?
    /// The last change that failed, said on the page.
    var problem: String?

    init(home: String) {
        var home = home
        while home.count > 1 && home.hasSuffix("/") { home.removeLast() }
        self.home = home
    }

    var macFile: URL { AppsFile.url(in: home) }

    /// Every space Add app can save in (Available in), This Mac first.
    var scopes: [(scope: AppScope, label: String)] {
        [(.mac, "This Mac (every space)")] + spaces().map { (.space($0.id), "This space (\($0.name))") }
    }

    func group(_ scope: AppScope) -> Group? { groups.first { $0.scope == scope } }

    /// The apps a thread in `space` can run: its space's, then This Mac's.
    func apps(in space: SpaceID?) -> [(key: AppKey, app: AppDefinition)] {
        let own = space.flatMap { id in group(.space(id))?.apps.map { (AppKey(scope: .space(id), name: $0.name), $0) } } ?? []
        let mac = group(.mac)?.apps.map { (AppKey(scope: .mac, name: $0.name), $0) } ?? []
        return own + mac
    }

    // MARK: Loading

    /// Reads every file again, off the main thread. A load asked for while one runs runs once
    /// after it.
    func reload() {
        if loading { reloadAgain = true; return }
        loading = true
        let home = home, macFile = macFile
        let spaces = spaces().map { ($0.id, $0.name, $0.path) }
        let current = currentSpace()
        Task {
            let groups = await Task.detached(priority: .utility) {
                Self.read(macFile: macFile, home: home, spaces: spaces, current: current)
            }.value
            if self.groups != groups { self.groups = groups }
            loaded = true
            loading = false
            if reloadAgain { reloadAgain = false; reload() }
        }
    }

    /// This Mac's group, then each space that has apps, scripts to suggest, or is `current`.
    nonisolated static func read(macFile: URL, home: String, spaces: [(SpaceID, String, String)], current: SpaceID?) -> [Group] {
        func group(_ scope: AppScope, _ title: String, root: String?, file: URL) -> Group {
            do { return Group(scope: scope, title: title, root: root, apps: try AppsFile.load(file)) }
            catch { return Group(scope: scope, title: title, root: root, apps: [], problem: "\(AppsFile.relativePath) isn’t valid apps JSON. Fix or delete it to add apps here.") }
        }
        var result = [group(.mac, "On this Mac", root: nil, file: macFile)]
        for (id, name, path) in spaces {
            let root = HooksModel.expand(path, home: home)
            var space = group(.space(id), name, root: root, file: AppsFile.url(in: root))
            if space.problem == nil {
                space.suggestions = suggestions(DevServerDiscovery.find(in: URL(fileURLWithPath: root, isDirectory: true)),
                                                apps: space.apps, root: root)
            }
            if !space.apps.isEmpty || !space.suggestions.isEmpty || space.problem != nil || current == id { result.append(space) }
        }
        return result
    }

    /// The scripts not already an app: none runs the same command in the same folder.
    nonisolated static func suggestions(_ servers: [DevServer], apps: [AppDefinition], root: String) -> [DevServer] {
        servers.filter { server in
            !apps.contains { $0.command == server.command && $0.directory(root: root, home: "") == URL(fileURLWithPath: server.directory).standardizedFileURL.path }
        }
    }

    /// A suggested script as an app: named for its script, opening its page when its port is known.
    nonisolated static func app(for server: DevServer, root: String) -> AppDefinition {
        let folder = relative(server.directory, to: root)
        return AppDefinition(name: server.script, command: server.command, folder: folder,
                             opens: server.url == nil ? .terminal : .browser, address: server.url?.absoluteString)
    }

    nonisolated static func relative(_ path: String, to root: String) -> String {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path, root = URL(fileURLWithPath: root).standardizedFileURL.path
        guard path != root else { return "" }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    // MARK: Changes

    /// Writes `scope`'s apps with `change` applied, off the main thread, then reads every file
    /// again. Nil when it took; else why, also said on the page.
    @discardableResult
    func change(_ scope: AppScope, _ change: @escaping @Sendable (inout [AppDefinition]) throws -> Void) async -> String? {
        let file: URL
        switch scope {
        case .mac: file = macFile
        case .space(let id):
            guard let space = spaces().first(where: { $0.id == id }) else { return fail("That space is gone.") }
            file = AppsFile.url(in: HooksModel.expand(space.path, home: home))
        }
        let failure = await Task.detached { () -> String? in
            do {
                var apps = try AppsFile.load(file)
                try change(&apps)
                try AppsFile.save(apps, to: file)
                return nil
            } catch let error as AppsChangeError {
                return error.message
            } catch is DecodingError {
                return "\(AppsFile.relativePath) isn’t valid apps JSON, so Shepherd left it as it is."
            } catch {
                return error.localizedDescription
            }
        }.value
        reload()
        if problem != failure { problem = failure }
        return failure
    }

    private func fail(_ message: String) -> String {
        problem = message
        return message
    }

    /// Saves the editor's app: added, or in place of the one it edits (moved when its scope changed).
    func save(_ app: AppDefinition, to scope: AppScope, replacing original: AppKey?) async -> String? {
        if let original, original.scope != scope {
            if let failure = await change(scope, { try Self.insert(app, into: &$0, replacing: nil) }) { return failure }
            return await change(original.scope) { $0.removeAll { $0.name == original.name } }
        }
        return await change(scope) { try Self.insert(app, into: &$0, replacing: original?.name) }
    }

    nonisolated static func insert(_ app: AppDefinition, into apps: inout [AppDefinition], replacing name: String?) throws {
        if apps.contains(where: { $0.name == app.name && $0.name != name }) {
            throw AppsChangeError(message: "There is already an app named \(app.name) there.")
        }
        if let name, let index = apps.firstIndex(where: { $0.name == name }) { apps[index] = app } else { apps.append(app) }
    }

    func remove(_ key: AppKey) {
        Task { await change(key.scope) { $0.removeAll { $0.name == key.name } } }
    }

    /// Add both: every suggested script of a space as an app.
    func addSuggestions(_ group: Group) {
        guard let root = group.root else { return }
        let apps = group.suggestions.map { Self.app(for: $0, root: root) }
        Task {
            await change(group.scope) { list in
                for var app in apps {
                    // Two packages' "dev": the second is named for its folder too.
                    if list.contains(where: { $0.name == app.name }) { app.name = "\(app.name) (\(app.folder.isEmpty ? "root" : app.folder))" }
                    try Self.insert(app, into: &list, replacing: nil)
                }
            }
        }
    }

    // MARK: Editing

    func add(scope: AppScope) {
        editor = AppEditor(adding: scope, model: self)
    }

    func edit(_ app: AppDefinition, scope: AppScope) {
        editor = AppEditor(editing: app, scope: scope, model: self)
    }

    /// The folders a space's app can run in: the space, each folder in it, and each app or
    /// package of a monorepo (`apps/web`), as paths from the space.
    nonisolated static func folders(in root: String) -> [String] {
        let fm = FileManager.default
        func children(_ path: String) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: path)) ?? []).filter { name in
                var dir: ObjCBool = false
                return !name.hasPrefix(".") && name != "node_modules" && fm.fileExists(atPath: path + "/" + name, isDirectory: &dir) && dir.boolValue
            }.sorted()
        }
        var result = [""]
        for name in children(root) {
            result.append(name)
            if ["apps", "packages"].contains(name) { result += children(root + "/" + name).map { "\(name)/\($0)" } }
        }
        return result
    }

    // MARK: Processes

    func process(_ key: AppKey) -> AppProcessSnapshot? { processes[key] }

    func adopt(_ processes: [AppKey: AppProcessSnapshot]) {
        if self.processes != processes { self.processes = processes }
    }
}

struct AppsChangeError: Error {
    let message: String
}

/// The Add app / Edit app sheet's fields.
@MainActor
@Observable
final class AppEditor: Identifiable {
    let id = UUID()
    /// The app being edited; nil while adding.
    let original: AppKey?
    var name: String
    var command: String
    var folder: String
    var scope: AppScope { didSet { if scope != oldValue { folders = Self.folders(for: scope, model: model) } } }
    var opens: AppDefinition.Opens
    var address: String
    var quickAction: Bool
    private(set) var folders: [String]
    var saving = false
    var problem: String?
    @ObservationIgnored private unowned let model: AppsModel

    init(adding scope: AppScope, model: AppsModel) {
        original = nil
        self.model = model
        name = ""
        command = ""
        folder = ""
        self.scope = scope
        opens = .browser
        address = "http://localhost:3000"
        quickAction = true
        folders = Self.folders(for: scope, model: model)
    }

    init(editing app: AppDefinition, scope: AppScope, model: AppsModel) {
        original = AppKey(scope: scope, name: app.name)
        self.model = model
        name = app.name
        command = app.command
        folder = app.folder
        self.scope = scope
        opens = app.opens
        address = app.address ?? ""
        quickAction = app.quickAction
        folders = Self.folders(for: scope, model: model)
        if !folders.contains(folder) { folders.append(folder) }
    }

    private static func folders(for scope: AppScope, model: AppsModel) -> [String] {
        guard case .space(let id) = scope, let space = model.spaces().first(where: { $0.id == id }) else { return [] }
        return AppsModel.folders(in: HooksModel.expand(space.path, home: model.home))
    }

    var title: String { original == nil ? "Add app" : "Edit app" }

    var scopes: [(scope: AppScope, label: String)] { model.scopes }

    /// The space's name, for its folders ("payments/web").
    var spaceName: String? {
        guard case .space(let id) = scope else { return nil }
        return model.spaces().first { $0.id == id }?.name
    }

    func folderLabel(_ folder: String) -> String {
        guard let spaceName else { return folder }
        return folder.isEmpty ? spaceName : "\(spaceName)/\(folder)"
    }

    var app: AppDefinition {
        AppDefinition(name: name.trimmingCharacters(in: .whitespacesAndNewlines), command: command.trimmingCharacters(in: .whitespacesAndNewlines),
                      folder: folder.trimmingCharacters(in: .whitespaces), opens: opens,
                      address: opens == .browser ? address.trimmingCharacters(in: .whitespaces) : nil, quickAction: quickAction)
    }

    /// Why Add app is off; nil when it can save.
    var invalid: String? {
        let app = app
        if app.name.isEmpty { return "Name the app" }
        if app.command.isEmpty { return "Enter the command it runs" }
        if app.opens == .browser, app.url == nil { return "Enter an http:// or https:// address" }
        return nil
    }

    /// What the chosen opening does, under the picker.
    var opensHelp: String {
        switch opens {
        case .browser: "Shepherd runs the command, waits for the address to answer, then opens it in a browser tab in the side pane. Its output goes to a tab in the terminal panel."
        case .terminal: "Shepherd runs the command in the background. Its output goes to a tab in the terminal panel."
        case .window: "Shepherd runs the command in the background and the app opens its own window. Its output goes to a tab in the terminal panel."
        }
    }

    func save() async -> Bool {
        guard invalid == nil, !saving else { return false }
        saving = true
        defer { saving = false }
        problem = await model.save(app, to: scope, replacing: original)
        return problem == nil
    }
}
