import AppKit
import Foundation
import ShepherdSessions
import ShepherdUI

// Settings › Hooks (docs/hooks.md; HooksSettings, HooksSources, HooksReview, HooksSpace boards):
// the hooks Shepherd and the agent's runtime read on this Mac, their trust, and the composer's
// hook glyph. The catalog reads files, so every load runs off the main thread; the page's rows are
// derived once per load or filter change, here, so views only draw them.

/// The composer's hook glyph for one thread: how many hooks run in its space, and how many wait
/// for review (the lantern dot). Nil when neither: no glyph.
struct HookIndicator: Equatable, Sendable {
    var running: Int
    var needingReview: Int
    /// The space it counts, for Settings › Hooks filtered to it.
    var spaceRoot: String?

    init?(_ summary: HookSummary, spaceRoot: String?) {
        guard summary.showsGlyph else { return nil }
        running = summary.running; needingReview = summary.needingReview; self.spaceRoot = spaceRoot
    }

    /// "3 hooks run in this space, 1 waiting for review".
    var help: String {
        var text = running == 1 ? "1 hook runs in this space" : "\(running) hooks run in this space"
        if needingReview > 0 { text += ", \(needingReview) waiting for review" }
        return text
    }
}

/// One hook as Settings' rows draw it.
struct HookRowValue: Equatable, Identifiable {
    enum Badge: Equatable {
        case new, changed
        var text: String { self == .new ? "New · needs review" : "Changed · needs review" }
    }
    var id: String
    var hash: String
    /// The matcher, or "every tool" / "always" when it has none (`matcherIsAny`).
    var matcher: String
    var matcherIsAny: Bool
    var command: String
    var source: String
    var badge: Badge?
    var on: Bool
    /// The switch can't change it: it waits for review, or it is a type Shepherd doesn't run.
    var locked: Bool
    var lockHelp: String?
}

struct HookEventGroup: Equatable, Identifiable {
    var event: String
    var label: String
    var rows: [HookRowValue]
    var id: String { event }
}

struct HookRailItem: Equatable, Identifiable {
    /// nil: All hooks.
    var event: String?
    var label: String
    var count: Int
    var id: String { event ?? "" }
}

/// A hooks file as Sources and a space's Hooks tab draw it.
struct HookFileRow: Equatable, Identifiable {
    enum Tone: Equatable { case ok, attention, off, failed }
    enum Action: Equatable { case review, trustSpace, openFile }
    var id: String
    var path: String
    var shownPath: String
    var format: String
    var count: String
    var state: String
    var tone: Tone
    var action: Action?
    var dimmed: Bool
}

struct HookScopeSection: Equatable, Identifiable {
    var id: String
    var name: String
    var note: String
    var root: String?
    var files: [HookFileRow]
}

@MainActor
@Observable
final class HooksModel {
    enum Tab: Hashable { case hooks, sources }

    @ObservationIgnored let catalog: HookCatalog
    @ObservationIgnored let writer: HookFileWriter
    /// The app's spaces on this Mac (their folders), read at each load.
    @ObservationIgnored var spacePaths: () -> [String] = { [] }
    /// Pi's approval of a space folder (Sources' Trust space): the app's existing path.
    @ObservationIgnored var approveSpace: (String) async throws -> Void = { _ in }

    private(set) var snapshot: HookCatalogSnapshot?
    private(set) var loading = false
    /// Thread cwds the composer asked about, each with its space root (nil: the home folder).
    @ObservationIgnored private var cwdRoots: [String: String?] = [:]
    /// The composer glyph per thread cwd.
    private(set) var indicators: [String: HookIndicator] = [:]
    @ObservationIgnored private var reloadAgain = false
    /// Open hook asked for a hash the catalog hadn't loaded: opened by the next load.
    @ObservationIgnored var pendingEdit: String?
    @ObservationIgnored private var pendingReview: String??

    var tab: Tab = .hooks
    /// The rail's event; nil for all.
    var filter: String? { didSet { if filter != oldValue { derive() } } }
    /// Settings › Hooks opened from a thread: only This Mac's hooks and that space's.
    var spaceFilter: String? { didSet { if spaceFilter != oldValue { derive() } } }
    /// The review sheet, open.
    var review: HookReviewState?
    var editor: HookEditorModel?
    /// The last change that failed, said in the page.
    var problem: String?

    private(set) var rail: [HookRailItem] = []
    private(set) var groups: [HookEventGroup] = []
    private(set) var sections: [HookScopeSection] = []
    /// Hooks new or changed since they were trusted (the banner).
    private(set) var needingReview = 0
    /// Files that exist (the Sources tab's count).
    private(set) var fileCount = 0
    /// Events with no hook, for the rail's footnote.
    private(set) var emptyEvents = 0

    init(catalog: HookCatalog) {
        self.catalog = catalog
        writer = HookFileWriter(trust: catalog.trustStore)
    }

    convenience init(home: String, support: URL, piTrust: URL? = nil) {
        self.init(catalog: HookCatalog(home: home, support: support, piTrust: piTrust))
    }

    var home: String { catalog.home }

    // MARK: Loading

    /// Reads the catalog again, off the main thread. A load asked for while one runs runs once
    /// after it, never more: nothing here repeats on its own.
    func reload() {
        if loading { reloadAgain = true; return }
        loading = true
        let catalog = catalog, home = catalog.home
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
        if let root = pendingReview {
            pendingReview = nil
            openReview(root: root)
        }
    }

    nonisolated static func expand(_ path: String, home: String) -> String {
        path == "~" ? home : path.hasPrefix("~/") ? home + path.dropFirst(1) : path
    }

    // MARK: Rows

    private func derive() {
        guard let snapshot else { rail = []; groups = []; sections = []; needingReview = 0; return }
        let entries = spaceFilter.map { snapshot.entries(forSpaceRoot: $0) } ?? snapshot.entries
        needingReview = entries.count { $0.review.needsReview }
        let byEvent = Dictionary(grouping: entries, by: \.event)
        let known = HookEvent.allCases.map(\.rawValue)
        let events = known.filter { byEvent[$0] != nil } + byEvent.keys.filter { !known.contains($0) }.sorted()
        rail = [HookRailItem(event: nil, label: "All hooks", count: entries.count)]
            + events.map { HookRailItem(event: $0, label: HookEvent(rawValue: $0)?.label ?? $0, count: byEvent[$0]?.count ?? 0) }
        emptyEvents = known.count - events.filter { known.contains($0) }.count
        groups = events.filter { filter == nil || filter == $0 }.map { event in
            HookEventGroup(event: event, label: HookEvent(rawValue: event)?.label ?? event,
                           rows: (byEvent[event] ?? []).map { row($0, showScope: true) })
        }
        sections = Self.sections(snapshot, home: home)
        fileCount = snapshot.sources.count { $0.state != .notFound }
    }

    func row(_ entry: HookEntry, showScope: Bool) -> HookRowValue {
        let event = entry.hookEvent
        let anyLabel = [.preToolUse, .postToolUse, .permissionRequest].contains(event) ? "every tool" : "always"
        let badge: HookRowValue.Badge? = switch entry.review {
        case .new: .new
        case .changed: .changed
        case .on, .off: nil
        }
        let lockHelp: String? = badge != nil ? "Review this hook before turning it on"
            : !entry.handler.canRun ? "Shepherd lists \(entry.handler.type) hooks but doesn't run them" : nil
        return HookRowValue(id: entry.slot, hash: entry.hash, matcher: entry.matcher.isEmpty || entry.matcher == "*" ? anyLabel : entry.matcher,
                            matcherIsAny: entry.matcher.isEmpty || entry.matcher == "*", command: Self.command(entry.handler),
                            source: showScope ? sourceLabel(entry) : Self.folderLabel(entry.file),
                            badge: badge, on: entry.runs, locked: lockHelp != nil, lockHelp: lockHelp)
    }

    /// What a handler runs: its command, else "server › tool".
    nonisolated static func command(_ handler: HookHandler) -> String {
        if let command = handler.command { return command.replacingOccurrences(of: "\n", with: " ") }
        if let server = handler.server, let tool = handler.tool { return "\(server) › \(tool)" }
        return handler.type
    }

    /// "This Mac · ~/.shepherd/hooks.json", "payments · .claude/settings.json".
    func sourceLabel(_ entry: HookEntry) -> String {
        switch entry.scope {
        case .mac: "This Mac · " + Self.tilde(entry.file, home: home)
        case .space(let root): (root as NSString).lastPathComponent + " · " + Self.relative(entry.file, to: root)
        }
    }

    /// "payments/.claude/settings.json", "~/.shepherd/hooks.json": the file, as Review names it.
    func fileLabel(_ entry: HookEntry) -> String {
        switch entry.scope {
        case .mac: Self.tilde(entry.file, home: home)
        case .space(let root): (root as NSString).lastPathComponent + "/" + Self.relative(entry.file, to: root)
        }
    }

    /// ".shepherd", ".claude": a space row's short source.
    nonisolated static func folderLabel(_ file: String) -> String {
        ((file as NSString).deletingLastPathComponent as NSString).lastPathComponent
    }

    nonisolated static func tilde(_ path: String, home: String) -> String {
        path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    nonisolated static func relative(_ path: String, to root: String) -> String {
        path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
    }

    static func sections(_ snapshot: HookCatalogSnapshot, home: String) -> [HookScopeSection] {
        var order: [HookScope] = []
        for source in snapshot.sources where !order.contains(source.scope) { order.append(source.scope) }
        return order.compactMap { scope in
            let sources = snapshot.sources.filter { $0.scope == scope && $0.state != .notFound }
            let root = scope.root
            if root != nil && sources.isEmpty { return nil }
            let trusted = !sources.contains { $0.state == .spaceNotTrusted }
            let name = root.map { ($0 as NSString).lastPathComponent } ?? "This Mac"
            let note = root.map { (trusted ? "Trusted space · " : "Not trusted · ") + tilde($0, home: home) } ?? "Run in every space"
            return HookScopeSection(id: root ?? "", name: name, note: note, root: root,
                                    files: sources.map { fileRow($0, snapshot: snapshot, home: home, name: name) })
        }
    }

    static func fileRow(_ source: HookSource, snapshot: HookCatalogSnapshot, home: String, name: String) -> HookFileRow {
        let shown = source.scope.root.map { relative(source.path, to: $0) } ?? tilde(source.path, home: home)
        var row = HookFileRow(id: source.path, path: source.path, shownPath: shown, format: source.format.name, count: "–",
                              state: "", tone: .ok, action: nil, dimmed: false)
        switch source.state {
        case .loaded(let count):
            row.count = count == 1 ? "1 hook" : "\(count) hooks"
            let entries = snapshot.entries.filter { $0.file == source.path }
            let new = entries.count { $0.review == .new }
            let changed = entries.count { if case .changed = $0.review { true } else { false } }
            if new + changed > 0 {
                let parts = [new > 0 ? "\(new) new" : nil, changed > 0 ? "\(changed) changed" : nil].compactMap { $0 }
                row.state = "Loaded · " + parts.joined(separator: ", ") + ", waiting for review"
                row.tone = .attention; row.action = .review
            } else {
                row.state = "Loaded"
            }
        case .notFound:
            row.state = "Not found"; row.tone = .off; row.dimmed = true
        case .readerOff:
            row.state = "Not read: switched off above"; row.tone = .off; row.dimmed = true
        case .spaceNotTrusted:
            row.state = "Skipped: \(name) isn’t a trusted space"; row.tone = .off; row.action = .trustSpace
        case .unreadable:
            row.state = source.state.label; row.tone = .failed; row.action = .openFile
        }
        return row
    }

    /// The hooks waiting for review, This Mac's and every space's, or one space's and This Mac's.
    func pending(root: String?) -> [HookEntry] {
        guard let snapshot else { return [] }
        let entries = root.map { snapshot.entries(forSpaceRoot: $0) } ?? snapshot.entries
        return entries.filter(\.review.needsReview)
    }

    /// Opens Review for every hook waiting (nil) or one space's and This Mac's, once the catalog is loaded.
    func openReview(root: String?) {
        guard snapshot != nil else { pendingReview = .some(root); reload(); return }
        review = HookReviewState(entries: pending(root: root), label: fileLabel)
    }

    func entry(hash: String) -> HookEntry? { snapshot?.entries.first { $0.hash == hash } }
    func entry(slot: String) -> HookEntry? { snapshot?.entries.first { $0.slot == slot } }

    /// A space's hooks, its files (the three the board lists, and any other there), and how many of
    /// This Mac's also run there.
    func space(_ root: String) -> (groups: [HookEventGroup], files: [HookFileRow], macCount: Int, waiting: Int, loaded: Bool) {
        guard let snapshot else { return ([], [], 0, 0, false) }
        let root = PiHome.canonical(root)
        let entries = snapshot.entries.filter { $0.scope.root == root }
        let byEvent = Dictionary(grouping: entries, by: \.event)
        let groups = HookEvent.allCases.map(\.rawValue).filter { byEvent[$0] != nil }.map { event in
            HookEventGroup(event: event, label: HookEvent(rawValue: event)?.label ?? event, rows: (byEvent[event] ?? []).map { row($0, showScope: false) })
        }
        let sources = snapshot.sources.filter { $0.scope.root == root }
        let main = [".shepherd/hooks.json", ".claude/settings.json", ".codex/hooks.json"]
        let name = (root as NSString).lastPathComponent
        let files = sources.filter { main.contains(Self.relative($0.path, to: root)) || $0.state != .notFound }.map { source in
            var row = Self.fileRow(source, snapshot: snapshot, home: home, name: name)
            if source.state == .notFound { row.state = "not in this space" }
            return row
        }
        let mac = snapshot.entries.count { $0.scope == .mac && $0.runs }
        return (groups, files, mac, entries.count { $0.review.needsReview }, !sources.isEmpty)
    }

    // MARK: Changes

    /// Runs one trust or file change off the main thread, then reloads.
    func change(_ body: @escaping @Sendable (HookCatalog, HookFileWriter) throws -> Void) async -> Bool {
        let catalog = catalog, writer = writer
        let failure = await Task.detached { () -> String? in
            do { try body(catalog, writer); return nil } catch { return String(describing: error) }
        }.value
        if problem != failure { problem = failure }
        reload()
        return failure == nil
    }

    func setOn(_ row: HookRowValue, _ on: Bool) {
        let hash = row.hash
        Task { _ = await change { catalog, _ in try catalog.trustStore.setOn(hash, on) } }
    }

    func setReader(_ format: HookFormat, _ on: Bool) {
        Task { _ = await change { catalog, _ in try catalog.trustStore.setReader(format, on) } }
    }

    var readers: HookTrust.Readers { snapshot?.trust.readers ?? HookTrust.Readers() }

    func trust(_ entries: [HookEntry]) async -> Bool {
        await change { catalog, _ in try catalog.trustStore.trust(entries, by: .review) }
    }

    func trustSpace(_ root: String) {
        Task {
            do { try await approveSpace(root); problem = nil } catch { problem = String(describing: error) }
            reload()
        }
    }

    func open(_ path: String) {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) { NSWorkspace.shared.open(url) }
        else { NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()]) }
    }

    func act(_ action: HookFileRow.Action, on row: HookFileRow, root: String?) {
        switch action {
        case .review: openReview(root: root)
        case .trustSpace: if let root { trustSpace(root) }
        case .openFile: open(row.path)
        }
    }

    // MARK: Editing

    /// Where Add and Edit can save: This Mac's Shepherd file, then each loaded space's.
    var saveTargets: [HookEditorModel.Target] {
        let mac = HookEditorModel.Target(path: home + "/.shepherd/hooks.json", label: "This Mac · ~/.shepherd/hooks.json", root: nil)
        let roots = (snapshot?.sources.compactMap(\.scope.root) ?? []).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return [mac] + roots.map { HookEditorModel.Target(path: $0 + "/.shepherd/hooks.json",
                                                          label: ($0 as NSString).lastPathComponent + " · .shepherd/hooks.json", root: $0) }
    }

    func add(spaceRoot: String? = nil, draft: HookDraft? = nil, target path: String? = nil) {
        let targets = saveTargets
        let target = path.flatMap { p in targets.first { $0.path == p } }
            ?? spaceRoot.flatMap { root in targets.first { $0.root == PiHome.canonical(root) } } ?? targets[0]
        editor = HookEditorModel(adding: draft, target: target, targets: targets, home: home)
    }

    func edit(_ entry: HookEntry) {
        var targets = saveTargets
        if !targets.contains(where: { $0.path == entry.file }) {
            targets.append(.init(path: entry.file, label: sourceLabel(entry), root: entry.scope.root))
        }
        editor = HookEditorModel(editing: entry, targets: targets, label: sourceLabel(entry), home: home)
    }

    func edit(hash: String) {
        if let entry = entry(hash: hash) { edit(entry) } else { problem = "That hook is no longer in its file." }
    }
}
