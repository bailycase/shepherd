import Foundation
import ShepherdProtocol
import ShepherdRemote

/// Where each user message Shepherd delivered came from (steered in, or from the queue with
/// its parts), per pi session, so a thread still says so after a relaunch. pi's session has no
/// room for it: a queue delivered "all at once" reaches pi as one message, and a queued
/// message's own send time is not pi's timestamp. One small JSON file per pi session in the
/// support directory's `thread-origins/`, keyed by the message's entry id
/// (`RPCThreadState.historyEntryID`), newest `limit` kept. Never pi's files.
///
/// A part is kept as its length, not its text: the text is pi's message, split where the
/// queue joined it (`NativeQueueRules.separator`).
final class ThreadOriginStore: @unchecked Sendable {
    static let limit = 512

    /// What the file keeps for one message.
    struct Record: Codable, Hashable, Sendable {
        struct Part: Codable, Hashable, Sendable {
            var id: UUID?
            /// UTF-8 bytes of the part's text within the message.
            var bytes: Int
            var sentAt: Double
            var images: Int
        }

        var steered: Bool?
        var parts: [Part]?

        init?(_ origin: NativeMessageOrigin) {
            switch origin {
            case .steered:
                steered = true
            case .queue(let parts):
                self.parts = parts.map { Part(id: $0.id, bytes: $0.text.utf8.count, sentAt: $0.sentAt, images: $0.images) }
            case .unknown:
                return nil
            }
        }

        /// The origin of the message whose text is `text`, or nil when the text no longer
        /// splits where the parts say (the message is not the one recorded).
        func origin(text: String) -> NativeMessageOrigin? {
            if steered == true { return .steered }
            guard let parts, !parts.isEmpty else { return nil }
            let bytes = Array(text.utf8)
            let separator = Array(NativeQueueRules.separator.utf8)
            var offset = 0
            var result: [NativeQueuePart] = []
            for (index, part) in parts.enumerated() {
                if index > 0 {
                    guard offset + separator.count <= bytes.count, Array(bytes[offset..<(offset + separator.count)]) == separator else { return nil }
                    offset += separator.count
                }
                guard part.bytes >= 0, offset + part.bytes <= bytes.count,
                      let piece = String(bytes: bytes[offset..<(offset + part.bytes)], encoding: .utf8) else { return nil }
                result.append(NativeQueuePart(id: part.id, text: piece, sentAt: part.sentAt, images: part.images))
                offset += part.bytes
            }
            return .queue(parts: result)
        }
    }

    private struct File: Codable {
        var version = 1
        /// Oldest first.
        var entries: [Entry] = []
    }

    private struct Entry: Codable {
        var id: String
        var record: Record
    }

    let directory: URL
    /// Writes run here, in order, off the server queue.
    private let writes = DispatchQueue(label: "shepherd.thread-origins", qos: .utility)

    init(directory: URL) {
        self.directory = directory
    }

    /// Everything recorded for `sessionID`, oldest first; empty when nothing was, or the file
    /// is unreadable.
    func load(sessionID: String) -> [(id: String, record: Record)] {
        guard let data = try? Data(contentsOf: url(for: sessionID)),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return file.entries.map { ($0.id, $0.record) }
    }

    /// Saves the session's records (the caller's whole list, oldest first), newest `limit` kept.
    func save(sessionID: String, records: [(id: String, record: Record)]) {
        let entries = records.suffix(Self.limit).map { Entry(id: $0.id, record: $0.record) }
        let url = url(for: sessionID)
        let directory = directory
        writes.async {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try JSONEncoder().encode(File(entries: Array(entries))).write(to: url, options: .atomic)
            } catch {
                ShepherdLog.warning("thread origins for \(sessionID) not saved: \(error)")
            }
        }
    }

    /// Waits for every write queued so far (tests).
    func flush() {
        writes.sync {}
    }

    private func url(for sessionID: String) -> URL {
        let safe = String(sessionID.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" || scalar == "." ? Character(scalar) : "_"
        })
        return directory.appendingPathComponent("\(safe.isEmpty ? "_" : safe).json")
    }
}
