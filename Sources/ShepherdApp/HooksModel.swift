import AppKit
import Foundation
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdUI

// Settings › Hooks (docs/hooks.md; HooksSettings, HooksSources, HooksSpace boards):
// the hooks Shepherd and the agent's runtime read on one host, their off switches, and the composer's
// hook glyph. One model per host: this Mac's reads its catalog off the main thread; a remote host's
// reads and changes it over `hooks.v1`. The page's rows are derived once per load or filter change,
// here, so views only draw them.

/// The composer's hook glyph for one thread: how many hooks run in its space. Nil when none: no glyph.
struct HookIndicator: Equatable, Sendable {
    var running: Int
    /// The space it counts, for Settings › Hooks filtered to it.
    var spaceRoot: String?

    init?(_ summary: HookSummary, spaceRoot: String?) {
        guard summary.showsGlyph else { return nil }
        running = summary.running; self.spaceRoot = spaceRoot
    }

    /// "3 hooks run in this space".
    var help: String { running == 1 ? "1 hook runs in this space" : "\(running) hooks run in this space" }
}

struct HookRailItem: Equatable, Identifiable {
    /// nil: All hooks.
    var event: String?
    var label: String
    var count: Int
    var id: String { event ?? "" }
}

@MainActor
@Observable
final class HooksModel {
    enum Tab: Hashable { case hooks, sources }

    /// This Mac's catalog and writer; nil for a remote host's model.
    @ObservationIgnored let catalog: HookCatalog?
    @ObservationIgnored private let writer: HookFileWriter?
    /// The remote host this model shows (nil: this Mac), and how to find it now: its client
    /// changes as it reconnects.
    @ObservationIgnored let hostID: UUID?
    @ObservationIgnored private let findHost: @MainActor () -> SettingsHost?
    /// The app's spaces on this Mac (their folders), read at each load.
    @ObservationIgnored var spacePaths: () -> [String] = { [] }

    private(set) var snapshot: HookCatalogSnapshot?
    private(set) var loading = false
    /// Thread cwds the composer asked about, each with its space root (nil: the home folder).
    @ObservationIgnored private var cwdRoots: [String: String?] = [:]
    /// The composer glyph per thread cwd.
    private(set) var indicators: [String: HookIndicator] = [:]
    @ObservationIgnored private var reloadAgain = false
    /// Open hook asked for a hash the catalog hadn't loaded: opened by the next load.
    @ObservationIgnored var pendingEdit: String?
    /// Reload after a conflict: the slot the next load opens again.
    @ObservationIgnored private var pendingSlot: String?

    var tab: Tab = .hooks
    /// The rail's event; nil for all.
    var filter: String? { didSet { if filter != oldValue { derive() } } }
    /// Settings › Hooks opened from a thread: only This Mac's hooks and that space's.
    var spaceFilter: String? { didSet { if spaceFilter != oldValue { derive() } } }
    var editor: HookEditorModel?
    /// The last change that failed, said in the page.
    var problem: String?

    private(set) var rail: [HookRailItem] = []
    private(set) var groups: [HookEventGroup] = []
    private(set) var sections: [HookScopeSection] = []
    /// Files that exist (the Sources tab's count).
    private(set) var fileCount = 0
    /// Events with no hook, for the rail's footnote.
    private(set) var emptyEvents = 0

    init(catalog: HookCatalog) {
        self.catalog = catalog
        writer = HookFileWriter(settings: catalog.settingsStore)
        hostID = nil
        findHost = { nil }
    }

    convenience init(home: String, support: URL) {
        self.init(catalog: HookCatalog(home: home, support: support))
    }

    /// A remote host's hooks, over `hooks.v1`.
    init(host id: UUID, find: @escaping @MainActor () -> SettingsHost?) {
        catalog = nil
        writer = nil
        hostID = id
        findHost = find
    }

    var isRemote: Bool { hostID != nil }
    /// The host's home folder: paths show from it.
    var home: String { catalog?.home ?? snapshot?.home ?? "" }
    /// "Studio", or "this Mac": where a test runs.
    var hostName: String { isRemote ? findHost()?.name ?? "the host" : "this Mac" }

    /// Why a remote host's hooks can't show: it is offline, or its Shepherd predates `hooks.v1`.
    var unavailable: String? {
        guard isRemote else { return nil }
        guard let host = findHost(), host.isConnected else { return "\(hostName) is offline. Its hooks show here once it's back." }
        guard host.capabilities.contains(RemoteProtocol.hooksCapability) else {
            return "\(host.name)'s Shepherd is too old to share its hooks: update it to change them here."
        }
        return nil
    }

    /// The host's client while it is connected and serves hooks.
    private var client: (any HooksClient)? {
        findHost().flatMap { $0.serves(RemoteProtocol.hooksCapability) ? $0.client as? any HooksClient : nil }
    }

    // MARK: Loading

    /// Reads the catalog again, off the main thread. A load asked for while one runs runs once
    /// after it, never more: nothing here repeats on its own.
    func reload() {
        if loading { reloadAgain = true; return }
        guard let catalog else { return reloadRemote() }
        loading = true
        let home = catalog.home
        let spaces = spacePaths().map { Self.expand($0, home: home) }
        let cwds = Array(cwdRoots.keys)
        Task {
            let (snapshot, roots) = await Task.detached(priority: .utility) { () -> (HookCatalogSnapshot, [String: String?]) in
                var roots: [String: String?] = [:]
                for cwd in cwds { roots[cwd] = catalog.spaceRoot(forCwd: cwd) }
                let spaceRoots = spaces.compactMap { catalog.spaceRoot(forCwd: $0) } + roots.values.compactMap { $0 }
                return (catalog.load(spaceRoots: spaceRoots), roots)
            }.value
            apply(snapshot, roots: roots)
            loading = false
            if reloadAgain { reloadAgain = false; reload() }
        }
    }

    /// A remote host's catalog, read once over `hooks.v1`; a host that can't answer says why.
    private func reloadRemote() {
        guard let client else { return }
        loading = true
        Task {
            do {
                if case .hooks(let snapshot) = try await client.hooks(.fetch) { apply(snapshot) }
            } catch {
                let why = settingsProblem(error)
                if problem != why { problem = why }
            }
            loading = false
            if reloadAgain { reloadAgain = false; reload() }
        }
    }

    /// The composer's thread in `cwd`: loads once for a cwd the model hasn't seen. A remote
    /// host's spaces are in the catalog it already sent, so only its first thread reads it.
    func ensure(cwd: String) {
        guard cwdRoots[cwd] == nil else { return }
        cwdRoots[cwd] = .some(nil)
        if isRemote, let snapshot { apply(snapshot) } else { reload() }
    }

    func indicator(forCwd cwd: String?) -> HookIndicator? { cwd.flatMap { indicators[$0] } }

    /// Applies a load (tests and previews hand one in directly).
    func apply(_ snapshot: HookCatalogSnapshot, roots: [String: String?] = [:]) {
        for (cwd, root) in roots { cwdRoots[cwd] = root }
        if isRemote { for cwd in Array(cwdRoots.keys) { cwdRoots[cwd] = Self.remoteRoot(forCwd: cwd, in: snapshot) } }
        if self.snapshot != snapshot { self.snapshot = snapshot }
        var next: [String: HookIndicator] = [:]
        for (cwd, root) in cwdRoots { next[cwd] = HookIndicator(snapshot.summary(forSpaceRoot: root), spaceRoot: root) }
        if next != indicators { indicators = next }
        derive()
        if let hash = pendingEdit {
            pendingEdit = nil
            edit(hash: hash)
        }
        if let slot = pendingSlot {
            pendingSlot = nil
            if let entry = entry(slot: slot) { edit(entry) } else { problem = "That hook is no longer in its file." }
        }
    }

    nonisolated static func expand(_ path: String, home: String) -> String {
        path == "~" ? home : path.hasPrefix("~/") ? home + path.dropFirst(1) : path
    }

    /// A remote thread's space: the deepest of the host's spaces at or above its cwd, else none
    /// (only the host-wide hooks).
    // ponytail: a worktree outside its space's folder counts only the host-wide hooks; a cwd field on `.fetch` if that matters.
    nonisolated static func remoteRoot(forCwd cwd: String, in snapshot: HookCatalogSnapshot) -> String? {
        let cwd = expand(cwd, home: snapshot.home)
        return snapshot.sources.compactMap(\.scope.root)
            .filter { cwd == $0 || cwd.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
            .max { $0.count < $1.count }
    }

    /// A space's folder as the catalog names it: real on this Mac, as given on a host.
    private func root(_ path: String) -> String { isRemote ? Self.expand(path, home: home) : PiHome.canonical(path) }

    // MARK: Rows

    private func derive() {
        guard let snapshot else { rail = []; groups = []; sections = []; return }
        let entries = spaceFilter.map { snapshot.entries(forSpaceRoot: $0) } ?? snapshot.entries
        let byEvent = Dictionary(grouping: entries, by: \.event)
        let known = HookEvent.allCases.map(\.rawValue)
        let events = known.filter { byEvent[$0] != nil } + byEvent.keys.filter { !known.contains($0) }.sorted()
        rail = [HookRailItem(event: nil, label: "All hooks", count: entries.count)]
            + events.map { HookRailItem(event: $0, label: HookEvent(rawValue: $0)?.label ?? $0, count: byEvent[$0]?.count ?? 0) }
        emptyEvents = known.count - events.filter { known.contains($0) }.count
        groups = HooksPresentation.groups(entries, home: home).filter { filter == nil || filter == $0.event }
        sections = HooksPresentation.sections(snapshot, home: home)
        // A host's own files are named for it, and open on it, not here.
        if isRemote {
            for g in groups.indices { for r in groups[g].rows.indices { groups[g].rows[r].source = named(groups[g].rows[r].source) } }
            for s in sections.indices {
                sections[s].name = named(sections[s].name)
                for f in sections[s].files.indices { sections[s].files[f].action = nil }
            }
        }
        fileCount = HooksPresentation.fileCount(snapshot)
    }

    func row(_ entry: HookEntry, showScope: Bool) -> HookRowValue { HooksPresentation.row(entry, home: home, showScope: showScope) }

    /// "This Mac · ~/.shepherd/hooks.json" ("studio · …" on a remote host), "payments · .claude/settings.json".
    func sourceLabel(_ entry: HookEntry) -> String { named(HooksPresentation.sourceLabel(entry, home: home)) }

    /// The shared labels say "This Mac" for the host's own scope; a remote host's say its name.
    private func named(_ label: String) -> String {
        isRemote && label.hasPrefix("This Mac") ? hostName + label.dropFirst("This Mac".count) : label
    }

    nonisolated static func relative(_ path: String, to root: String) -> String { HooksPresentation.relative(path, to: root) }

    func entry(hash: String) -> HookEntry? { snapshot?.entries.first { $0.hash == hash } }
    func entry(slot: String) -> HookEntry? { snapshot?.entries.first { $0.slot == slot } }

    /// A space's hooks, its files (the three the board lists, and any other there), and how many of
    /// This Mac's also run there.
    func space(_ root: String) -> (groups: [HookEventGroup], files: [HookFileRow], macCount: Int, loaded: Bool) {
        guard let snapshot else { return ([], [], 0, false) }
        let root = self.root(root)
        let entries = snapshot.entries.filter { $0.scope.root == root }
        let groups = HooksPresentation.groups(entries, home: home, showScope: false).filter { HookEvent(rawValue: $0.event) != nil }
        let sources = snapshot.sources.filter { $0.scope.root == root }
        let main = [".shepherd/hooks.json", ".claude/settings.json", ".codex/hooks.json"]
        let files = sources.filter { main.contains(Self.relative($0.path, to: root)) || $0.state != .notFound }.map { source in
            var row = HooksPresentation.fileRow(source, home: home)
            if source.state == .notFound { row.state = "not in this space" }
            if isRemote { row.action = nil }
            return row
        }
        let mac = snapshot.entries.count { $0.scope == .mac && $0.runs }
        return (groups, files, mac, !sources.isEmpty)
    }

    // MARK: Changes

    /// Why a change didn't take; `changed` when the hook changed in its file since it was read.
    struct Failure: Error, Equatable {
        var message: String
        var changed = false
    }

    /// Runs one change, on this Mac off the main thread or on the host, then shows the hooks as
    /// they are now. Nil when it took; else why, also said in the page.
    func change(local body: @escaping @Sendable (HookCatalog, HookFileWriter) throws -> Void,
                remote request: RemoteHooksRequest) async -> Failure? {
        let failure: Failure?
        if let catalog, let writer {
            failure = await Task.detached { () -> Failure? in
                do { try body(catalog, writer); return nil }
                catch let error as HookFileWriter.Failure { return Failure(message: error.description, changed: error == .changed) }
                catch { return Failure(message: String(describing: error)) }
            }.value
            reload()
        } else {
            do {
                guard let client else { throw RemoteHostClientError.rejected(code: "offline", message: unavailable ?? "") }
                if case .hooks(let snapshot) = try await client.hooks(request) { apply(snapshot) }
                failure = nil
            } catch {
                if case RemoteHostClientError.rejected(code: "hook_changed", message: _) = error { failure = Failure(message: settingsProblem(error), changed: true) }
                else { failure = Failure(message: settingsProblem(error)) }
                reload()
            }
        }
        if problem != failure?.message { problem = failure?.message }
        return failure
    }

    func setOn(_ row: HookRowValue, _ on: Bool) {
        let hash = row.hash
        Task { _ = await change(local: { catalog, _ in try catalog.settingsStore.setOn(hash, on) }, remote: .setOn(hash: hash, on: on)) }
    }

    func setReader(_ format: HookFormat, _ on: Bool) {
        Task { _ = await change(local: { catalog, _ in try catalog.settingsStore.setReader(format, on) }, remote: .setReader(format: format, on: on)) }
    }

    func save(_ drafts: [HookDraft], to file: String, replacing entry: HookEntry?, kept: Int?) async -> Failure? {
        await change(local: { _, writer in try writer.save(drafts, to: file, replacing: entry, kept: kept) },
                     remote: .save(drafts: drafts, file: file, replacing: entry.map(HookRef.init), kept: kept))
    }

    func delete(_ entry: HookEntry) async -> Failure? {
        await change(local: { _, writer in try writer.delete(entry) }, remote: .delete(HookRef(entry)))
    }

    /// Runs `command` once against a sample event: here off the main thread, or on the host.
    func test(command: String, event: HookEvent, matcher: String, timeout: Double?, root: String?) async throws -> HookTestResult {
        if let catalog {
            let root = root ?? catalog.home
            return await Task.detached(priority: .userInitiated) {
                HookTester.run(command: command, event: event, matcher: matcher, timeout: timeout, root: root)
            }.value
        }
        guard let client else { throw RemoteHostClientError.rejected(code: "offline", message: unavailable ?? "") }
        guard case .tested(let result) = try await client.hooks(.test(command: command, event: event, matcher: matcher, timeout: timeout, root: root)) else {
            throw RemoteHostClientError.rejected(code: "unexpected", message: "\(hostName) didn't send the test's result.")
        }
        return result
    }

    var readers: HookSettings.Readers { snapshot?.settings.readers ?? HookSettings.Readers() }

    func open(_ path: String) {
        guard !isRemote else { return }
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) { NSWorkspace.shared.open(url) }
        else { NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()]) }
    }

    func act(_ action: HookFileRow.Action, on row: HookFileRow, root: String?) {
        switch action {
        case .openFile: open(row.path)
        }
    }

    // MARK: Editing

    /// Where Add and Edit can save: This Mac's Shepherd file, then each loaded space's.
    var saveTargets: [HookSaveTarget] {
        HooksPresentation.saveTargets(snapshot ?? HookCatalogSnapshot(sources: [], entries: [], settings: HookSettings()), home: home)
            .map { HookSaveTarget(path: $0.path, label: named($0.label), root: $0.root) }
    }

    /// `saved` runs once the editor saves (a proposal's Edit… answers the proposal with it).
    func add(spaceRoot: String? = nil, draft: HookDraft? = nil, target path: String? = nil, saved: (@MainActor () -> Void)? = nil) {
        let targets = saveTargets
        let target = path.flatMap { p in targets.first { $0.path == p } }
            ?? spaceRoot.flatMap { root in targets.first { $0.root == self.root(root) } } ?? targets[0]
        editor = HookEditorModel(adding: draft, target: target, targets: targets, home: home)
        editor?.saved = saved
    }

    func edit(_ entry: HookEntry) {
        var targets = saveTargets
        if !targets.contains(where: { $0.path == entry.file }) {
            targets.append(HookSaveTarget(path: entry.file, label: sourceLabel(entry), root: entry.scope.root))
        }
        editor = HookEditorModel(editing: entry, targets: targets, label: sourceLabel(entry), home: home)
    }

    func edit(hash: String) {
        if let entry = entry(hash: hash) { edit(entry) } else { problem = "That hook is no longer in its file." }
    }

    /// The editor's Reload after a conflict: reads the hooks again and opens the hook as its file
    /// has it now (gone: the page says so).
    func reloadEditing(_ entry: HookEntry) {
        editor = nil
        pendingSlot = entry.slot
        reload()
    }
}
