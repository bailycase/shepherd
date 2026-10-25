import Foundation
import Observation
import ShepherdCore
import ShepherdProtocol

// Settings and navigation for the new Projects feature (ProjectLead boards), over the owning
// host's `logicalProjects` API. This model creates no thread, session or process; it edits the
// persisted record. Every edit carries the revision it was shown. A refusal re-reads the project
// and keeps the user's draft, so nothing is overwritten on a stale view.

/// Where a project lives: this Mac, or a connected host that owns it. A viewer never interprets
/// the owner's Space IDs; they travel with the host.
public enum LogicalProjectHome: Codable, Hashable, Sendable {
    case local
    case host(UUID)
}

/// A project with the host that owns it.
public struct LogicalProjectRef: Codable, Hashable, Identifiable, Sendable {
    public let home: LogicalProjectHome
    public let id: ProjectID
    public init(home: LogicalProjectHome, id: ProjectID) { self.home = home; self.id = id }
}

/// What a host said no to, or could not do, in words a person reads.
public struct LogicalProjectFailure: Equatable, Sendable {
    public var message: String
    /// The project changed under the user; the view re-read it and kept the draft.
    public var stale = false
    public init(message: String, stale: Bool = false) { self.message = message; self.stale = stale }
}

@MainActor @Observable
public final class LogicalProjectsModel {
    /// One request to one owner. Local calls the server; a remote one goes through the host's
    /// client and its capability gate (`update_required` from an older host).
    public typealias Send = @MainActor (LogicalProjectHome, LogicalProjectsRequest) async throws -> LogicalProjectsResult

    /// What each owner last pushed in its state snapshot (the server's word, never a client's).
    public typealias Pushed = @MainActor (LogicalProjectHome) -> [Project]

    /// The owner's runtime (`ProjectRuntimeRequest`): resolve, message, assign, decide a Space. Local calls this
    /// Mac's own; a remote one is sent to its OWNER (`ProjectRuntimeTransport.action`), never run on this Mac.
    public typealias Runtime = @MainActor (LogicalProjectRef, UInt64, ProjectRuntimeRequest) async throws -> Project

    @ObservationIgnored private let send: Send
    @ObservationIgnored private let pushed: Pushed
    @ObservationIgnored private let runtime: Runtime?
    /// A task's question answered in the Project (the worker's own native dialog, fenced by session, generation and
    /// the Project revision). The same dialog cannot also be answered in the worker's ordinary thread.
    public typealias Answer = @MainActor (LogicalProjectRef, UInt64, ProjectTaskID, NativeThreadRequest) async throws -> NativeThreadResult
    @ObservationIgnored public var answerQuestion: Answer?
    /// The hosts the OWNER knows (`ProjectRuntimeTransport.hosts`): the names a Project's host policy is chosen from. A viewer's own
    /// host list is never used for a remote owner, whose bindings it does not know.
    public typealias Hosts = @MainActor (LogicalProjectHome) async throws -> [ProjectHostOption]
    @ObservationIgnored public var ownerHosts: Hosts?
    /// The newest answer to this device's own request, for the moment before the owner's push lands.
    /// A pushed record with the same or a higher revision always wins over it.
    private var answers: [LogicalProjectRef: Project] = [:]
    /// Deleted here, until the push drops the record.
    private var deleted: Set<LogicalProjectRef> = []
    public var failure: LogicalProjectFailure?
    /// A mutation in flight for a project; one at a time so a revision is never reused.
    public private(set) var busy: Set<LogicalProjectRef> = []
    @ObservationIgnored private var generations: [LogicalProjectHome: UInt64] = [:]

    public init(send: @escaping Send, pushed: @escaping Pushed, runtime: Runtime? = nil) {
        self.send = send
        self.pushed = pushed
        self.runtime = runtime
    }

    /// Drops cached replies and unsent retry identities when an owner is forgotten.
    public func forget(_ home: LogicalProjectHome) {
        generations[home, default: 0] &+= 1
        busy = busy.filter { $0.home != home }
        answers = answers.filter { $0.key.home != home }
        deleted = deleted.filter { $0.home != home }
        operations = operations.filter { $0.key.home != home }
    }

    // MARK: Reading

    /// Every project an owner holds, in its own order.
    public func list(_ home: LogicalProjectHome) -> [Project] {
        let list = pushed(home).filter { !deleted.contains(LogicalProjectRef(home: home, id: $0.id)) }
        return list.map { newest($0, home) }
    }

    public func project(_ ref: LogicalProjectRef) -> Project? {
        guard !deleted.contains(ref) else { return nil }
        guard let pushedOne = pushed(ref.home).first(where: { $0.id == ref.id }) else { return answers[ref] }
        return newest(pushedOne, ref.home)
    }

    private func newest(_ project: Project, _ home: LogicalProjectHome) -> Project {
        let ref = LogicalProjectRef(home: home, id: project.id)
        if let answer = answers[ref], answer.ownerID == project.ownerID, answer.revision > project.revision { return answer }
        return project
    }

    /// Re-reads one owner's list, so the next action carries the owner's revision.
    public func refresh(_ home: LogicalProjectHome) async {
        let generation = generations[home, default: 0]
        do {
            guard case .projects(let list) = try await send(home, .list) else { return }
            guard generations[home, default: 0] == generation else { return }
            for project in list { remember(project, in: home) }
        } catch {
            if generations[home, default: 0] == generation { failure = LogicalProjectFailure(message: Self.message(error)) }
        }
    }

    // MARK: Create

    /// One create, retried with the same ID until it commits or the sheet closes.
    @discardableResult
    public func create(home: LogicalProjectHome, id: ProjectID, name: String, goal: String, spaces: [SpaceID]) async -> Project? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let generation = generations[home, default: 0]
        do {
            let result = try await send(home, .create(projectID: id, name: name, goal: goal, linkedSpaceIDs: spaces))
            guard generations[home, default: 0] == generation, case .project(let project) = result else { return nil }
            remember(project, in: home)
            return project
        } catch {
            guard generations[home, default: 0] == generation else { return nil }
            failure = LogicalProjectFailure(message: Self.message(error))
            return nil
        }
    }

    // MARK: Edits (each carries the revision it was shown)

    public func edit(_ ref: LogicalProjectRef, name: String, goal: String) async -> Bool {
        await mutate(ref) { .edit(projectID: ref.id, expectedRevision: $0.revision, name: name, goal: goal) }
    }

    public func saveSettings(_ ref: LogicalProjectRef, _ change: (inout LogicalProjectSettings) -> Void) async -> Bool {
        await mutate(ref) { project in
            var settings = project.settings
            change(&settings)
            return .settings(projectID: ref.id, expectedRevision: project.revision, settings: settings)
        }
    }

    public func resolve(_ ref: LogicalProjectRef, task: ProjectTaskID) async -> Bool { await run(ref, .resolve(taskID: task)) }

    /// A runtime request against the revision shown. A refusal re-reads the owner and keeps the person's words.
    @discardableResult
    public func run(_ ref: LogicalProjectRef, _ request: ProjectRuntimeRequest) async -> Bool {
        guard let shown = project(ref), !busy.contains(ref) else { return false }
        guard let runtime else {
            failure = LogicalProjectFailure(message: "This Project cannot be run from here.")
            return false
        }
        let generation = generations[ref.home, default: 0]
        busy.insert(ref)
        defer { if generations[ref.home, default: 0] == generation { busy.remove(ref) } }
        failure = nil
        do {
            let updated = try await runtime(ref, shown.revision, request)
            guard generations[ref.home, default: 0] == generation else { return false }
            remember(updated, in: ref.home)
            return true
        } catch {
            guard generations[ref.home, default: 0] == generation else { return false }
            await refuse(error, ref)
            return false
        }
    }

    /// Answers a waiting task's question through the Project. Accepted only if the owner took it; a stale or refused answer
    /// re-reads the owner and leaves the question where it was.
    public func answer(_ ref: LogicalProjectRef, task: ProjectTaskID, request: NativeThreadRequest) async -> Bool {
        guard let shown = project(ref), !busy.contains(ref) else { return false }
        guard let answerQuestion else {
            failure = LogicalProjectFailure(message: "This Project cannot be answered from here.")
            return false
        }
        let generation = generations[ref.home, default: 0]
        busy.insert(ref)
        defer { if generations[ref.home, default: 0] == generation { busy.remove(ref) } }
        failure = nil
        do {
            let result = try await answerQuestion(ref, shown.revision, task, request)
            guard generations[ref.home, default: 0] == generation else { return false }
            if case .accepted = result { return true }
            failure = LogicalProjectFailure(message: "The question could not be answered. Open the thread to check.")
            return false
        } catch {
            guard generations[ref.home, default: 0] == generation else { return false }
            await refuse(error, ref)
            return false
        }
    }

    /// Reuse an operation only for the same owner, Project, text and images. An ambiguous
    /// reply retains it for an explicit retry; changing the draft creates another operation.
    public func sendMessage(_ ref: LogicalProjectRef, text: String, images: [NativeImage] = []) async -> Bool {
        guard !busy.contains(ref),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty else { return false }
        let ownerID = project(ref)?.ownerID
        let operation = operations[ref].flatMap {
            $0.ownerID == ownerID && $0.text == text && $0.images == images ? $0.id : nil
        } ?? UUID()
        operations[ref] = (ownerID, text, images, operation)
        let ok = await run(ref, .message(operationID: operation, text: text, images: images.isEmpty ? nil : images))
        if ok, operations[ref]?.id == operation { operations[ref] = nil }
        return ok
    }

    /// The identity kept for an unconfirmed send, so sending the same words again is the explicit retry of the same operation.
    @ObservationIgnored private(set) var operations: [LogicalProjectRef: (ownerID: UUID?, text: String, images: [NativeImage], id: UUID)] = [:]

    public func forget(_ ref: LogicalProjectRef, memory: ProjectMemoryID) async -> Bool {
        await mutate(ref) { .forgetMemory(projectID: ref.id, expectedRevision: $0.revision, memoryID: memory) }
    }

    /// One scoped automation action against the Project revision shown. A stale answer re-reads the owner and keeps the person's
    /// draft; the toggle is a revisioned `setEnabled`, never the legacy unscoped one.
    public func automation(_ ref: LogicalProjectRef, _ id: AutomationID, _ action: ProjectAutomationAction) async -> Bool {
        await mutate(ref) { .automation(projectID: ref.id, expectedRevision: $0.revision, automationID: id, action: action) }
    }

    /// The owner's own host options, or nil when it will not say (an older owner, or not connected): the Hosts row then says
    /// "unknown" rather than guess.
    public func hostOptions(_ home: LogicalProjectHome) async -> [ProjectHostOption]? {
        let generation = generations[home, default: 0]
        let options = try? await ownerHosts?(home)
        return generations[home, default: 0] == generation ? options : nil
    }

    /// A person's decision on the Project's proposal to add a Space: the owner links it (or consumes it as denied) against the
    /// proposal's own revision. "Not now" is a denial: the owner consumes it, nothing remains actionable.
    public func decideSpace(_ ref: LogicalProjectRef, proposal: ProjectSpaceProposal, accept: Bool) async -> Bool {
        await run(ref, .decideSpace(proposalID: proposal.id, expectedProposalRevision: proposal.revision, accept: accept))
    }

    public func link(_ ref: LogicalProjectRef, space: SpaceID, host: ProjectHostReference? = nil) async -> Bool {
        await mutate(ref) { .linkSpace(projectID: ref.id, expectedRevision: $0.revision, spaceID: space, host: host) }
    }

    public func unlink(_ ref: LogicalProjectRef, space: SpaceID, host: ProjectHostReference? = nil) async -> Bool {
        await mutate(ref) { .unlinkSpace(projectID: ref.id, expectedRevision: $0.revision, spaceID: space, host: host) }
    }

    // MARK: Files (owner-relative, read-only)

    /// One directory of the Project's private folder on its OWNER. Paths are the owner's relative ones, never a path on this Mac.
    public func files(_ ref: LogicalProjectRef, path: String) async throws -> LogicalProjectFileListing {
        guard case .files(let listing) = try await send(ref.home, .files(projectID: ref.id, path: path)) else {
            throw LogicalProjectsError("protocol", "The host answered with something other than a file list.")
        }
        return listing
    }

    /// One file's bytes, as data to preview. Text and images only; the host refuses anything else.
    public func read(_ ref: LogicalProjectRef, path: String) async throws -> LogicalProjectFile {
        guard case .file(let file) = try await send(ref.home, .read(projectID: ref.id, path: path)) else {
            throw LogicalProjectsError("protocol", "The host answered with something other than a file.")
        }
        return file
    }

    /// Words for a Files refusal. The owner's own message is kept where it is specific.
    public static func filesMessage(_ error: Error) -> String {
        switch code(error) {
        case "update_required", "unsupported": "This host can't list project files yet. Update Shepherd on it."
        case "file_too_large": "Too large to preview. Previews show files up to 256 KiB."
        case "unsupported_file": "This file can't be previewed. Previews show text and PNG or JPEG images."
        case "disconnected": "The host is not connected."
        default: message(error)
        }
    }

    /// Removes the logical record. The host retains the project's directory and every artifact in it.
    public func delete(_ ref: LogicalProjectRef) async -> Bool {
        guard let shown = project(ref), !busy.contains(ref) else { return false }
        let generation = generations[ref.home, default: 0]
        busy.insert(ref)
        defer { if generations[ref.home, default: 0] == generation { busy.remove(ref) } }
        do {
            let result = try await send(ref.home, .delete(projectID: ref.id, expectedRevision: shown.revision))
            guard generations[ref.home, default: 0] == generation else { return false }
            if case .deleted = result { deleted.insert(ref); answers[ref] = nil; return true }
            return false
        } catch {
            guard generations[ref.home, default: 0] == generation else { return false }
            await refuse(error, ref)
            return false
        }
    }

    // MARK: Plumbing

    /// Runs one revisioned request. A success stores the returned project; a refusal re-reads and keeps the draft.
    private func mutate(_ ref: LogicalProjectRef, _ request: (Project) -> LogicalProjectsRequest) async -> Bool {
        guard let shown = project(ref), !busy.contains(ref) else { return false }
        let generation = generations[ref.home, default: 0]
        busy.insert(ref)
        defer { if generations[ref.home, default: 0] == generation { busy.remove(ref) } }
        failure = nil
        do {
            if case .project(let updated) = try await send(ref.home, request(shown)) {
                guard generations[ref.home, default: 0] == generation else { return false }
                remember(updated, in: ref.home)
                return true
            }
            return false
        } catch {
            guard generations[ref.home, default: 0] == generation else { return false }
            await refuse(error, ref)
            return false
        }
    }

    private func refuse(_ error: Error, _ ref: LogicalProjectRef) async {
        let stale = Self.isStale(error)
        failure = LogicalProjectFailure(message: Self.message(error), stale: stale)
        // Re-read, so the next action carries the host's revision. Never replay the edit.
        if stale || Self.refreshes(error) { await refresh(ref.home) }
    }

    private func remember(_ project: Project, in home: LogicalProjectHome) {
        let ref = LogicalProjectRef(home: home, id: project.id)
        // Never replace a newer record with an older answer.
        if let old = answers[ref], old.ownerID == project.ownerID, old.revision > project.revision { return }
        answers[ref] = project
    }

    public static func code(_ error: Error) -> String? {
        if let error = error as? LogicalProjectsError { return error.code }
        if case RemoteHostClientError.rejected(let code, _) = error { return code }
        return nil
    }

    public static func isStale(_ error: Error) -> Bool { code(error) == "stale_project" }
    public static func refreshes(_ error: Error) -> Bool { ["workspace_changed", "no_such_project"].contains(code(error) ?? "") }

    public static func message(_ error: Error) -> String {
        if let error = error as? LogicalProjectsError { return error.description }
        if case RemoteHostClientError.rejected(_, let message) = error { return message }
        return String(describing: error)
    }
}
