import Foundation
import Observation
import ShepherdProtocol

// Settings › Hooks on the iPhone and the iPad: the fleet's hooks through one Mac, read and changed over
// `hooks.v1`; a fleet keeps them the same on every Mac. The model holds what the pages draw (rows derived once per answer) and every rule
// they follow, so the pages only draw.

/// What Settings › Hooks reads and changes a host's hooks through: its `RemoteHostClient`, or a
/// stand-in in tests.
public protocol HooksClient: AnyObject, Sendable {
    func hooks(_ request: RemoteHooksRequest) async throws -> RemoteHooksResult
}

extension RemoteHostClient: HooksClient {}

/// A host's hooks, as the page draws them.
public struct HooksPage: Equatable, Sendable {
    public var snapshot: HookCatalogSnapshot
    public var groups: [HookEventGroup]
    public var sections: [HookScopeSection]
    /// Every hook ("8 hooks" beside the host).
    public var hookCount: Int
    /// Files that exist ("6 files" beside Sources).
    public var fileCount: Int

    public init(_ snapshot: HookCatalogSnapshot) {
        self.snapshot = snapshot
        groups = HooksPresentation.groups(snapshot.entries, home: snapshot.home)
        sections = HooksPresentation.sections(snapshot, home: snapshot.home)
        hookCount = snapshot.entries.count
        fileCount = HooksPresentation.fileCount(snapshot)
    }

    public var readers: HookSettings.Readers { snapshot.settings.readers }
    public func entry(slot: String) -> HookEntry? { snapshot.entries.first { $0.slot == slot } }
}

@MainActor
@Observable
public final class ClientHooks {
    public enum State: Equatable, Sendable {
        case offline
        /// Its Shepherd predates `hooks.v1`.
        case unsupported
        case loading
        case loaded(HooksPage)
        case failed(String)

        public var page: HooksPage? { if case .loaded(let page) = self { page } else { nil } }
    }

    /// The Mac the page reads and changes: any Mac in the fleet, since its hooks are the same on every one.
    public private(set) var host: SettingsHost?
    private var loaded: State?
    /// The last change that failed, said on the page until the next change or read.
    public private(set) var problem: String?

    public init() {}

    /// The host the page uses among the hosts the app holds: the first that serves hooks, else the first
    /// (whose state says why it can't). Called whenever the hosts change.
    public func use(_ hosts: [SettingsHost]) {
        let next = hosts.first { $0.serves(RemoteProtocol.hooksCapability) } ?? hosts.first
        if next?.id != host?.id { loaded = nil; problem = nil }
        host = next
    }

    public var state: State {
        guard let host, host.isConnected else { return .offline }
        guard host.capabilities.contains(RemoteProtocol.hooksCapability) else { return .unsupported }
        return loaded ?? .loading
    }

    public func dismissProblem() { set(problem: nil) }

    public func forget(host id: UUID) {
        guard host?.id == id else { return }
        host = nil
        loaded = nil
        problem = nil
    }

    /// Reads the host's hooks afresh; a host that can't answer keeps what it showed, with why.
    public func refresh() async {
        guard let host, let client = host.client as? HooksClient, host.capabilities.contains(RemoteProtocol.hooksCapability) else { return }
        do {
            apply(try await client.hooks(.fetch))
        } catch {
            if loaded?.page == nil { set(.failed(settingsProblem(error))) } else { set(problem: settingsProblem(error)) }
        }
    }

    /// The switch: shows at once, then goes to the host; a refusal puts the host's state back.
    public func setOn(_ row: HookRowValue, _ on: Bool) async {
        guard !row.locked, var page = loaded?.page else { return }
        for g in page.groups.indices {
            for r in page.groups[g].rows.indices where page.groups[g].rows[r].id == row.id { page.groups[g].rows[r].on = on }
        }
        set(.loaded(page))
        await change(.setOn(hash: row.hash, on: on))
    }

    public func setReader(_ format: HookFormat, _ on: Bool) async {
        if var page = loaded?.page {
            switch format {
            case .claude: page.snapshot.settings.readers.claude = on
            case .codex: page.snapshot.settings.readers.codex = on
            case .shepherd: break
            }
            set(.loaded(page))
        }
        await change(.setReader(format: format, on: on))
    }

    /// Sends a change; true when the host took it. A refusal is the page's problem, and the host's
    /// state is read again.
    @discardableResult
    public func change(_ request: RemoteHooksRequest) async -> Bool {
        do {
            _ = try await perform(request)
            set(problem: nil)
            return true
        } catch {
            set(problem: settingsProblem(error))
            await refresh()
            return false
        }
    }

    /// Sends a request, keeping the host's catalog from its answer. Throws the host's refusal.
    public func perform(_ request: RemoteHooksRequest) async throws -> RemoteHooksResult {
        guard let host, let client = host.client as? HooksClient else {
            throw RemoteHostClientError.rejected(code: "offline", message: "The Mac is offline. Try again once it's back.")
        }
        let result = try await client.hooks(request)
        apply(result)
        return result
    }

    private func apply(_ result: RemoteHooksResult) {
        guard case .hooks(let snapshot) = result else { return }
        set(.loaded(HooksPage(snapshot)))
    }

    private func set(_ state: State) { if loaded != state { loaded = state } }
    private func set(problem: String?) { if self.problem != problem { self.problem = problem } }
}

/// Settings › Hooks › Add hook and Edit hook on the iPhone and the iPad (MobileHookEdit): Form or
/// JSON, the event, where it's saved, the matcher with the tools it matches, its commands, a test
/// on the host, Delete. Codex's config.toml and events Shepherd doesn't know open read-only.
@MainActor
@Observable
public final class ClientHookEditor: Identifiable {
    public enum Mode: Equatable, Sendable { case add, edit(HookEntry) }
    public enum Pane: Hashable, Sendable { case form, json }

    public let id = UUID()
    public let mode: Mode
    public let targets: [HookSaveTarget]
    public let home: String
    public let readOnly: Bool

    public var event: HookEvent { didSet { if event != oldValue { testResult = nil } } }
    public var target: String
    public var matcher: String { didSet { if matcher != oldValue { matched = HookMatcher.agentTools(matching: matcher) } } }
    public private(set) var matched: [String]
    public var handlers: [HookFormHandler]
    public var pane: Pane = .form { didSet { if pane != oldValue { switched() } } }
    public var jsonText = ""
    public var jsonError: String?
    public private(set) var testing = false
    public private(set) var testResult: HookTestResult?
    public var problem: String?
    public private(set) var saving = false

    public init(adding snapshot: HookCatalogSnapshot) {
        mode = .add
        home = snapshot.home
        targets = HooksPresentation.saveTargets(snapshot, home: snapshot.home)
        readOnly = false
        event = .preToolUse
        target = targets[0].path
        matcher = ""
        handlers = [HookFormHandler()]
        matched = HookMatcher.agentTools
    }

    public init(editing entry: HookEntry, in snapshot: HookCatalogSnapshot) {
        mode = .edit(entry)
        home = snapshot.home
        targets = HooksPresentation.saveTargets(snapshot, home: snapshot.home, editing: entry)
        readOnly = !entry.editable || entry.hookEvent == nil
        event = entry.hookEvent ?? .preToolUse
        target = entry.file
        matcher = entry.matcher
        handlers = [HookFormHandler(original: true, entry.handler)]
        matched = HookMatcher.agentTools(matching: entry.matcher)
    }

    public var title: String { if case .edit = mode { readOnly ? "Hook" : "Edit hook" } else { "Add hook" } }
    public var entry: HookEntry? { if case .edit(let entry) = mode { entry } else { nil } }
    public var targetRoot: String? { targets.first { $0.path == target }?.root }
    /// "payments", "This Mac": the short name Saved in shows.
    public func targetName(_ target: HookSaveTarget) -> String { target.root.map { ($0 as NSString).lastPathComponent } ?? "This Mac" }
    /// "payments/.shepherd/hooks.json", "~/.shepherd/hooks.json": the file the JSON pane's caption names.
    public var targetFile: String {
        guard let target = targets.first(where: { $0.path == self.target }) else { return target }
        return target.root.map { ($0 as NSString).lastPathComponent + "/" + HooksPresentation.relative(target.path, to: $0) }
            ?? HooksPresentation.tilde(target.path, home: home)
    }
    public var matcherValid: Bool { HookMatcher.isValid(matcher) }
    /// Tool events show the Matches chips.
    public var matchesTools: Bool { [.preToolUse, .postToolUse, .permissionRequest].contains(event) }
    /// The first command handler: what Test runs.
    public var testable: HookFormHandler? { handlers.first(where: \.testable) }

    /// Set while a JSON pane that doesn't read stays open: its text and error are kept.
    @ObservationIgnored private var stayingOnJSON = false

    private func switched() {
        if pane == .json {
            guard !stayingOnJSON else { return }
            jsonText = HookForm.json(event: event, matcher: matcher, handlers: handlers)
            jsonError = nil
        } else if !readJSON() {
            stayingOnJSON = true
            pane = .json
            stayingOnJSON = false
        }
    }

    /// Reads the JSON pane back into the form; false (with why) when it isn't one hook entry.
    @discardableResult
    public func readJSON() -> Bool {
        do {
            let parsed = try HookForm.parse(jsonText, originals: handlers.map(\.original))
            event = parsed.event
            matcher = parsed.matcher
            handlers = parsed.handlers
            jsonError = nil
            return true
        } catch {
            jsonError = String(describing: error)
            return false
        }
    }

    public func addHandler() { handlers.append(HookFormHandler()) }
    public func remove(_ id: UUID) { if handlers.count > 1 { handlers.removeAll { $0.id == id } } }

    /// Writes the hook on the host; true when it did.
    public func save(with hooks: ClientHooks) async -> Bool {
        guard !readOnly, !saving else { return false }
        if pane == .json, !readJSON() { problem = jsonError; return false }
        let drafts: [HookDraft]
        do { drafts = try HookForm.drafts(event: event, matcher: matcher, handlers: handlers) } catch { problem = String(describing: error); return false }
        saving = true
        defer { saving = false }
        do {
            _ = try await hooks.perform(.save(drafts: drafts, file: target, replacing: entry.map(HookRef.init), kept: handlers.firstIndex(where: \.original)))
            problem = nil
            return true
        } catch {
            problem = settingsProblem(error)
            return false
        }
    }

    public func delete(with hooks: ClientHooks) async -> Bool {
        guard let entry, !readOnly, !saving else { return false }
        saving = true
        defer { saving = false }
        do {
            _ = try await hooks.perform(.delete(HookRef(entry)))
            return true
        } catch {
            problem = settingsProblem(error)
            return false
        }
    }

    /// Runs the first command once on the host against a sample event.
    public func test(with hooks: ClientHooks) async {
        guard let handler = testable, !testing else { return }
        testing = true
        defer { testing = false }
        let timeout = Double(handler.timeout.trimmingCharacters(in: .whitespaces))
        do {
            if case .tested(let result) = try await hooks.perform(.test(command: handler.command, event: event, matcher: matcher,
                                                                         timeout: timeout, root: targetRoot)) {
                testResult = result
                problem = nil
            }
        } catch {
            problem = settingsProblem(error)
        }
    }

    /// The test's line under its outcome: "sample bash · exit 2 · 41 ms · on Studio".
    public func testMeta(_ result: HookTestResult, host: String) -> String {
        HooksPresentation.testMeta(result, event: event, matcher: matcher) + " · on \(host)"
    }
}
