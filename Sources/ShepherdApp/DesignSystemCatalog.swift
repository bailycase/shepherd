import Foundation
import Observation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// This Mac's design systems as the app last read them from its server: each system's record and
/// counts, and its tokens, README and file list. Read again when the server says a system changed
/// (`SessionServer.onDesignSystemsChanged`) and when a page that shows them opens; a system whose
/// revision didn't move keeps what was read. Owned by the view model.
@MainActor @Observable
final class DesignSystemCatalog {
    /// Every system, built-ins first, as the server lists them.
    private(set) var summaries: [DesignSystemSummary] = []
    /// Each system read whole, by namespace.
    private(set) var reads: [String: DesignSystemRead] = [:]
    /// The systems being read again from their projects (Re-sync), by namespace.
    private(set) var syncing: Set<String> = []
    /// The first read has landed.
    private(set) var loaded = false

    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var again = false

    func summary(_ namespace: String) -> DesignSystemSummary? {
        summaries.first { $0.namespace == namespace }
    }

    func tokens(_ namespace: String) -> DesignSystemTokens? {
        reads[namespace]?.tokens
    }

    /// The system a design's agent built (the most recently changed, when it built more than one).
    func system(builtBy design: DesignID) -> DesignSystemSummary? {
        summaries.filter { $0.info.ownerDesignID == design }.max { $0.info.updatedAt < $1.info.updatedAt }
    }

    /// Reads the systems again: their list, then each one whose revision moved. A load asked for
    /// while one runs goes once more after it.
    func load(_ read: DesignSystemReader) async {
        if let loading {
            again = true
            await loading.value
            return
        }
        let task = Task { [weak self] in
            repeat {
                self?.again = false
                await self?.loadOnce(read)
            } while self?.again == true
        }
        loading = task
        await task.value
        loading = nil
    }

    private func loadOnce(_ read: DesignSystemReader) async {
        let listed = await read.summaries()
        var next: [String: DesignSystemRead] = [:]
        for summary in listed {
            if var known = reads[summary.namespace], known.summary.info.revision == summary.info.revision,
               known.summary.builtIn == summary.builtIn {
                // A re-sync that changed nothing moves only when it synced.
                known.summary = summary
                next[summary.namespace] = known
            } else if let whole = try? await read.system(summary.namespace) {
                next[summary.namespace] = whole
            }
        }
        if summaries != listed { summaries = listed }
        if reads != next { reads = next }
        if !loaded { loaded = true }
    }

    /// Re-sync: reads the system's stylesheets again from its project. Throws what the server
    /// said; the catalog reads the result either way.
    func resync(_ namespace: String, _ read: DesignSystemReader) async throws {
        guard !syncing.contains(namespace) else { return }
        syncing.insert(namespace)
        defer { syncing.remove(namespace) }
        do {
            _ = try await read.resync(namespace)
        } catch {
            await load(read)
            throw error
        }
        await load(read)
    }
}

/// How the catalog reaches a server: This Mac's, or a stand-in in tests.
struct DesignSystemReader: Sendable {
    var summaries: @Sendable () async -> [DesignSystemSummary]
    var system: @Sendable (String) async throws -> DesignSystemRead
    var resync: @Sendable (String) async throws -> DesignSystemSyncResult
}
