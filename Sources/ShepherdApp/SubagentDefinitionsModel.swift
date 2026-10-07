import AppKit
import Foundation
import Observation
import ShepherdSessions

@MainActor @Observable
final class SubagentDefinitionsModel {
    typealias Definition = SubagentDefinitionsStore.Definition
    enum Confirmation: Hashable { case restore, delete, discard }

    private(set) var definitions: [Definition] = []
    private(set) var visible: [Definition] = []
    var filter = "" { didSet { if filter != oldValue { refilter() } } }
    private(set) var loaded = false
    private(set) var busy = false
    private(set) var problem: String?
    private(set) var editing = false
    private(set) var original: SubagentDefinitionsStore.File?
    var filename = ""
    var draft = ""
    /// Models Shepherd's pi can run, for the form's Model popup. Read when a profile opens.
    private(set) var modelChoices: [String] = []
    var confirmation: Confirmation?
    @ObservationIgnored private var starter = ""
    @ObservationIgnored var models: @Sendable () -> [String] = { [] }
    @ObservationIgnored private var restoreExpected: [String: String] = [:]
    @ObservationIgnored private var afterDiscard: (() -> Void)?
    @ObservationIgnored let store: SubagentDefinitionsStore
    @ObservationIgnored var reveal: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    @ObservationIgnored var openEditor: (URL) throws -> Void = { url in
        guard NSWorkspace.shared.open(url) else { throw CocoaError(.fileReadUnknown) }
    }

    init(store: SubagentDefinitionsStore) { self.store = store }
    convenience init(pi: PiSetup) {
        self.init(store: SubagentDefinitionsStore(pi: pi, parserSource: ChildrenExtension.configSource))
        let catalog = pi.catalog
        models = { Array(Set(catalog.entriesOrConfigured().map(\.id))).sorted() }
    }
    var dirty: Bool { editing && (original == nil || draft != original?.text) }
    var canSave: Bool { editing && dirty && !busy && SubagentDefinitionsStore.acceptsFilename(filename) }
    var directory: URL { store.directory }
    /// The form's view of `draft`: it reads and rewrites the keys it draws and leaves the rest.
    var form: SubagentProfileText {
        get { SubagentProfileText(draft) }
        set { draft = newValue.text }
    }
    /// Why the open file does not load (an unsupported field, say), which the form cannot draw.
    var loadProblem: String? {
        original.flatMap { file in definitions.first { $0.file == file.file }?.diagnostic }
    }

    func refresh() async {
        guard !busy, !editing else { return }
        busy = true; problem = nil
        defer { busy = false }
        do {
            let store = store
            definitions = try await Task.detached(priority: .userInitiated) { try store.snapshot() }.value
            loaded = true; refilter()
        } catch { definitions = []; visible = []; loaded = true; problem = String(describing: error) }
    }

    private func refilter() {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        let order = ["scout.md", "reviewer.md", "planner.md", "worker.md"]
        let sorted = definitions.sorted {
            let a = order.firstIndex(of: $0.file) ?? order.count, b = order.firstIndex(of: $1.file) ?? order.count
            if a != b { return a < b }
            if ($0.diagnostic == nil) != ($1.diagnostic == nil) { return $0.diagnostic == nil }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        visible = query.isEmpty ? sorted : sorted.filter { [$0.name, $0.file, $0.description ?? "", $0.diagnostic ?? ""].contains { $0.localizedCaseInsensitiveContains(query) } }
    }

    func create() {
        guard !busy else { return }
        original = nil; filename = "new-subagent.md"; problem = nil; editing = true
        starter = "---\nname: new-subagent\ndescription: Describe the assigned task.\ntools: [read, grep, find, ls]\n---\n\nWrite the instructions this subagent should follow.\n"
        draft = starter
        loadModels()
    }

    /// Puts the form back to what is on disk (or to the starter of a new file).
    func revert() {
        guard editing, !busy else { return }
        draft = original?.text ?? starter
        problem = nil
    }

    private func loadModels() {
        let models = models
        Task { modelChoices = await Task.detached(priority: .userInitiated) { models() }.value }
    }

    func open(_ definition: Definition) async {
        guard !busy else { return }
        busy = true; problem = nil
        defer { busy = false }
        do {
            let store = store
            original = try await Task.detached(priority: .userInitiated) { try store.open(definition.file) }.value
            filename = definition.file; draft = original!.text; editing = true
            loadModels()
        } catch { problem = String(describing: error) }
    }

    func save() async {
        guard canSave else { return }
        busy = true; problem = nil
        defer { busy = false }
        let file = filename, text = draft, expected = original?.fingerprint, store = store
        do {
            original = try await Task.detached(priority: .userInitiated) { try store.save(file, text: text, expected: expected) }.value
            definitions = try await Task.detached(priority: .userInitiated) { try store.snapshot() }.value
            loaded = true; refilter()
        } catch { problem = String(describing: error) }
    }

    func back() { leave { self.close(); Task { await self.refresh() } } }
    func leave(_ action: @escaping () -> Void) {
        guard !busy || !editing else { return }
        if dirty { afterDiscard = action; confirmation = .discard }
        else { action() }
    }
    func cancelConfirmation() { confirmation = nil; afterDiscard = nil }
    private func close() { editing = false; original = nil; draft = ""; filename = ""; problem = nil }
    func askRestore() {
        guard !busy, loaded else { return }
        restoreExpected = Dictionary(uniqueKeysWithValues: definitions.filter(\.isDefault).compactMap { d in d.fingerprint.map { (d.file, $0) } })
        confirmation = .restore
    }
    func askDelete() { if !busy, original != nil { confirmation = .delete } }
    func confirm() async {
        guard let action = confirmation, !busy else { return }
        let leave = afterDiscard
        afterDiscard = nil; confirmation = nil
        if action == .discard {
            close()
            leave?()
            return
        }
        busy = true; problem = nil
        defer { busy = false }
        let store = store, expected = restoreExpected, file = original
        do {
            if action == .restore {
                try await Task.detached(priority: .userInitiated) { try store.restore(expected: expected) }.value
            } else if let file {
                try await Task.detached(priority: .userInitiated) { try store.delete(file.file, expected: file.fingerprint) }.value
                close()
            }
            definitions = try await Task.detached(priority: .userInitiated) { try store.snapshot() }.value
            loaded = true; refilter()
        } catch {
            let message = String(describing: error)
            if action == .restore {
                if let refreshed = try? await Task.detached(priority: .userInitiated, operation: { try store.snapshot() }).value {
                    definitions = refreshed; refilter()
                }
                problem = "Restore did not finish. Some defaults may have been restored. " + message
            } else { problem = message }
        }
    }

    func revealFolder() { if !busy { reveal(directory) } }
    func openInEditor() async {
        guard let original, !busy else { return }
        busy = true; problem = nil
        defer { busy = false }
        do {
            let store = store
            let url = try await Task.detached(priority: .userInitiated) { try store.editorURL(original.file) }.value
            try openEditor(url)
        } catch { problem = String(describing: error) }
    }
}
