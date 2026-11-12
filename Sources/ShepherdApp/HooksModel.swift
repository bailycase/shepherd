import AppKit
import Foundation
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdUI

// Settings › Hooks (HooksSettings, HooksSources, HooksSpace boards):
// the hooks Shepherd and the agent's runtime read on one host, their off switches, and the composer's
// hook glyph. This Mac's hooks: it reads its catalog off the main thread, and a fleet keeps Shepherd's own
// hooks the same on every Mac (`FleetHooksSource`). The page's rows are derived once per load or filter
// change, here, so views only draw them.

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

    /// This Mac's catalog and writer.
    @ObservationIgnored let catalog: HookCatalog
    @ObservationIgnored private let writer: HookFileWriter
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
    }

    convenience init(home: String, support: URL) {
        self.init(catalog: HookCatalog(home: home, support: support))
    }

    /// The host's home folder: paths show from it.
    var home: String { catalog.home }

    // MARK: Loading

    /// Reads the catalog again, off the main thread. A load asked for while one runs runs once
    /// after it, never more: nothing here repeats on its own.
    func reload() {
        if loading { reloadAgain = true; return }
        loading = true
        let catalog = catalog
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

    /// The composer's thread in `cwd`: loads once for a cwd the model hasn't seen.
    func ensure(cwd: String) {
        guard cwdRoots[cwd] == nil else { return }
        cwdRoots[cwd] = .some(nil)
        reload()
    }

    func indicator(forCwd cwd: String?) -> HookIndicator? { cwd.flatMap { indicators[$0] } }

    /// Applies a load (tests and previews hand one in directly).
    func apply(_ snapshot: HookCatalogSnapshot, roots: [String: String?] = [:]) {
        for (cwd, root) in roots { cwdRoots[cwd] = root }
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

    /// A space's folder as the catalog names it.
    private func root(_ path: String) -> String { PiHome.canonical(path) }

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
        fileCount = HooksPresentation.fileCount(snapshot)
    }

    func row(_ entry: HookEntry, showScope: Bool) -> HookRowValue { HooksPresentation.row(entry, home: home, showScope: showScope) }

    /// "This Mac · ~/.shepherd/hooks.json", "payments · .claude/settings.json".
    func sourceLabel(_ entry: HookEntry) -> String { HooksPresentation.sourceLabel(entry, home: home) }

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

    /// Runs one change off the main thread, then shows the hooks as they are now. Nil when it took; else
    /// why, also said in the page.
    func change(_ body: @escaping @Sendable (HookCatalog, HookFileWriter) throws -> Void) async -> Failure? {
        let catalog = catalog, writer = writer
        let failure = await Task.detached { () -> Failure? in
            do { try body(catalog, writer); return nil }
            catch let error as HookFileWriter.Failure { return Failure(message: error.description, changed: error == .changed) }
            catch { return Failure(message: String(describing: error)) }
        }.value
        reload()
        if problem != failure?.message { problem = failure?.message }
        return failure
    }

    func setOn(_ row: HookRowValue, _ on: Bool) {
        let hash = row.hash
        Task { _ = await change { catalog, _ in try catalog.settingsStore.setOn(hash, on) } }
    }

    func setReader(_ format: HookFormat, _ on: Bool) {
        Task { _ = await change { catalog, _ in try catalog.settingsStore.setReader(format, on) } }
    }

    func save(_ drafts: [HookDraft], to file: String, replacing entry: HookEntry?, kept: Int?) async -> Failure? {
        await change { _, writer in try writer.save(drafts, to: file, replacing: entry, kept: kept) }
    }

    func delete(_ entry: HookEntry) async -> Failure? {
        await change { _, writer in try writer.delete(entry) }
    }

    /// Runs `command` once against a sample event, off the main thread.
    func test(command: String, event: HookEvent, matcher: String, timeout: Double?, root: String?) async throws -> HookTestResult {
        let root = root ?? catalog.home
        return await Task.detached(priority: .userInitiated) {
            HookTester.run(command: command, event: event, matcher: matcher, timeout: timeout, root: root)
        }.value
    }

    var readers: HookSettings.Readers { snapshot?.settings.readers ?? HookSettings.Readers() }

    func open(_ path: String) {
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
            .map { HookSaveTarget(path: $0.path, label: $0.label, root: $0.root) }
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
