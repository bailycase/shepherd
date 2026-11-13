import Foundation
import Observation
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions

/// Settings ▸ Instructions on the Mac: Shepherd's root instructions for pi, kept by this Mac's
/// host (`InstructionsStore`). They are the fleet's: a save here is carried to every other Mac by
/// the host's sync (`fleet.sync.v1`), and a save another Mac made arrives the same way, so this
/// page edits one copy and knows nothing about the other Macs.
@MainActor
@Observable
final class InstructionsModel {
    // MARK: Loaded

    /// This Mac's files, nil until they are read.
    private(set) var local: InstructionsSnapshot?
    /// The instructions that came over from the user's pi into Shepherd's pi home (`AGENTS.md`,
    /// `APPEND_SYSTEM.md`), which every agent already reads from there: offered to adopt as
    /// Shepherd's own while Shepherd's file is empty (the extension omits an identical copy, so
    /// adopting never doubles it).
    private(set) var imported: [InstructionFile: ImportedInstructions] = [:]
    /// Shepherd's pi home, read for `imported`; nil reads none (hosts, previews).
    @ObservationIgnored var piHome: URL?

    struct ImportedInstructions: Equatable {
        /// The file's name as pi calls it ("AGENTS.md", "CLAUDE.md").
        var name: String
        var path: String
        var text: String
    }

    // MARK: Page

    var file: InstructionFile = .agents
    /// The editor's text for a file while it differs from what is saved.
    private(set) var drafts: [InstructionFile: String] = [:]
    private(set) var busy = false
    /// What went wrong with the last save or restore, in words.
    private(set) var problem: String?

    @ObservationIgnored private var editRevisions: [InstructionFile: Int] = [:]
    @ObservationIgnored private let request: (RemoteInstructionsRequest) async throws -> InstructionsSnapshot

    /// `store`: a test's own files for This Mac while no host is connected; the app's are its host's.
    init(store: InstructionsStore? = nil, remoteHosts: RemoteHostStore,
         request: ((RemoteInstructionsRequest) async throws -> InstructionsSnapshot)? = nil) {
        self.request = request ?? { request in
            if let host = try await remoteHosts.thisMacHost() { return try await host.instructions(request) }
            guard let store else { throw BackgroundHostClient.HostStarting() }
            return try await Task.detached(priority: .userInitiated) {
                switch request {
                case .fetch: return store.snapshot()
                case .save(let file, let content, let origin, let sync):
                    return try store.save(file, content: content, origin: origin.isEmpty ? nil : origin, sync: sync)
                case .restore(let revisionID, let origin):
                    return try store.restore(revisionID: revisionID, origin: origin.isEmpty ? nil : origin)
                }
            }.value
        }
    }

    // MARK: Reading

    /// Reads This Mac's files (the page opening).
    func refresh() async {
        await reloadLocal()
    }

    /// This Mac's files changed outside the editor (a remote client's save, a suggestion added or
    /// taken back, a save another Mac in the fleet made): the page shows them at once, and a draft
    /// keeps a line added at the end.
    func localChanged(_ snapshot: InstructionsSnapshot) {
        let old = local
        local = snapshot
        guard let old else { return }
        for file in InstructionFile.allCases where old[file] != snapshot[file] {
            guard let draft = drafts[file] else { continue }
            let rebased = InstructionsText.rebased(draft, from: old[file], to: snapshot[file])
            drafts[file] = rebased == snapshot[file] ? nil : rebased
        }
    }

    /// This Mac's files changed where they are kept (the background host's, as its client).
    func localFilesChanged() async {
        if let snapshot = try? await request(.fetch) { localChanged(snapshot) }
    }

    /// The saved text of a file, nil while it is unknown.
    func saved(_ file: InstructionFile) -> String? { local?[file] }

    /// What the editor shows: the draft, else the saved text.
    func text(_ file: InstructionFile) -> String {
        drafts[file] ?? saved(file) ?? ""
    }

    func setText(_ text: String, file: InstructionFile) {
        editRevisions[file, default: 0] += 1
        let draft: String? = !busy && text == saved(file) ? nil : text
        if drafts[file] != draft { drafts[file] = draft }
    }

    func isEdited(_ file: InstructionFile) -> Bool { drafts[file] != nil }

    /// Where This Mac keeps a file, for the editor's header; nil while it is unknown.
    func path(of file: InstructionFile) -> String? { local?.path(of: file) }

    // MARK: Side column

    /// The open file's saves, newest first.
    func history() -> [InstructionHistoryEntry] {
        local?.history.filter { $0.file == file } ?? []
    }

    // MARK: Saving

    var canSave: Bool { !busy && isEdited(file) }

    /// Saves the open file; the host's sync carries it to every other Mac.
    func save() async {
        let file = file
        guard let text = drafts[file], !busy else { return }
        let revision = editRevisions[file, default: 0]
        await run {
            self.local = try await self.request(.save(file: file, content: text, origin: "", sync: false))
            if self.editRevisions[file, default: 0] == revision { self.drafts[file] = nil }
        }
    }

    /// Drops the open file's unsaved changes.
    func revert() {
        editRevisions[file, default: 0] += 1
        drafts[file] = busy ? saved(file) : nil
    }

    /// Puts a saved version back, as a new save.
    func restore(_ entry: InstructionHistoryEntry) async {
        let revision = editRevisions[entry.file, default: 0]
        await run {
            self.local = try await self.request(.restore(revisionID: entry.id, origin: ""))
            if self.editRevisions[entry.file, default: 0] == revision { self.drafts[entry.file] = nil }
        }
    }

    func dismissProblem() {
        problem = nil
    }

    // MARK: Private

    private func run(_ body: @escaping () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        problem = nil
        defer { busy = false }
        do {
            try await body()
        } catch {
            problem = Self.describe(error)
        }
    }

    private func reloadLocal() async {
        local = try? await request(.fetch)
        if let piHome {
            imported = await Task.detached(priority: .userInitiated) { Self.imported(in: piHome) }.value
        }
    }

    /// What pi reads from its own agent folder, when the copy there is a file with something in it.
    nonisolated static func imported(in piHome: URL) -> [InstructionFile: ImportedInstructions] {
        var found: [InstructionFile: ImportedInstructions] = [:]
        let files: [(InstructionFile, URL?)] = [(.agents, YourPiFiles.contextFile(in: piHome)), (.appendSystem, piHome.appendingPathComponent("APPEND_SYSTEM.md"))]
        for (file, url) in files {
            guard let url, let text = try? String(contentsOf: url, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            found[file] = ImportedInstructions(name: url.lastPathComponent, path: url.path, text: text)
        }
        return found
    }

    /// The imported copy of `file` to offer while Shepherd's own is empty on This Mac.
    func adoptable(_ file: InstructionFile) -> ImportedInstructions? {
        guard let saved = saved(file), saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isEdited(file) else { return nil }
        return imported[file]
    }

    /// Adopt: the imported copy becomes the editor's draft, to save as Shepherd's own.
    func adoptImported(_ file: InstructionFile) {
        guard let copy = imported[file] else { return }
        setText(copy.text, file: file)
    }

    private static func describe(_ error: Error) -> String {
        if let failure = error as? RemoteHostClientError {
            switch failure {
            case .rejected(_, let message): return message
            default: return "The host didn't answer. Try again once it's connected."
            }
        }
        if let failure = error as? InstructionsStore.StoreError { return failure.description }
        return error.localizedDescription
    }
}
