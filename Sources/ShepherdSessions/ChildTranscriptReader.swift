import Darwin
import Foundation
import ShepherdProtocol

/// One bounded tail, confined to this worker. Missing sidecars are versions too: their
/// independent appearance changes attribution without changing the transcript itself.
final class ChildTranscriptReader: @unchecked Sendable {
    let queue = DispatchQueue(label: "shepherd.transcript.utility", qos: .utility)
    private let cache: ThreadReadCache
    private let owner: UUID
    static let cacheBytes = 16 * 1024 * 1024

    init(cache: ThreadReadCache = .shared, owner: UUID = UUID()) {
        self.cache = cache
        self.owner = owner
    }

    deinit { cache.remove(owner: owner, name: "transcript") }

    private static func version(_ file: String) -> String? {
        var info = stat()
        guard stat(file, &info) == 0 else { return nil }
        return "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
    }

    func read(runID: String, file: String, generation: String, before: String?) -> (NativeThreadResult, built: Bool) {
        guard let reservation = cache.reserve(bytes: ThreadReadCache.transcriptWorkBytes) else {
            return (.failure(code: "transcript_unavailable", message: "Transcript readers are busy. Try again."), false)
        }
        defer { withExtendedLifetime(reservation) {} }
        let interval = RPCThreadState.signposter.beginInterval("Child transcript", id: RPCThreadState.signposter.makeSignpostID())
        defer { RPCThreadState.signposter.endInterval("Child transcript", interval) }
        let sidecar = URL(fileURLWithPath: file).deletingLastPathComponent().appendingPathComponent(RPCThreadState.userMessagesFile).path
        let versions = [Self.version(file), Self.version(sidecar)]
        if case .transcript(let cached) = cache.value(owner: owner, name: "transcript"),
           cached.file == file, cached.generation == generation, cached.versions == versions {
            return (RPCThreadState.transcriptPage(runID: runID, projected: cached.rows, beforeEntryID: before), false)
        }
        cache.remove(owner: owner, name: "transcript")
        guard let rows = RPCThreadState.transcriptMessages(file: file) else {
            return (.failure(code: "transcript_unavailable", message: "The subagent's session file is not readable."), true)
        }
        // A writer raced the read: return this bounded snapshot, but never reuse it.
        let cost = rows.reduce(0) { $0 + RPCThreadState.bytes($1) + MemoryLayout<NativeThreadMessage>.stride }
        if versions == [Self.version(file), Self.version(sidecar)], cost <= Self.cacheBytes {
            cache.insert(.transcript(.init(file: file, generation: generation, versions: versions, rows: rows)),
                         bytes: cost, owner: owner, name: "transcript")
        }
        return (RPCThreadState.transcriptPage(runID: runID, projected: rows, beforeEntryID: before), true)
    }
}
