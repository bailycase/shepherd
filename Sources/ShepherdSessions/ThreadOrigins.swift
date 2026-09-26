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
///
/// The same file keeps the session's question records (`NativeQuestionRecord`, newest
/// `questionLimit`): pi's session holds no UI dialogs, so what pi asked and what the user
/// answered would otherwise leave the thread with the app.
final class ThreadOriginStore: @unchecked Sendable {
    static let limit = 512
    static let questionLimit = 256

    /// One question pi asked, by its dialog id, and when it ended (ms): where the thread shows it.
    struct Question: Codable, Hashable, Sendable {
        var id: String
        var record: NativeQuestionRecord
        var endedAt: Double
    }

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
            case .user, .designComment, .designMarkup, .unknown:
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
        /// Oldest first. Absent from files written before questions were kept.
        var questions: [Question]?
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
        file(sessionID)?.entries.map { ($0.id, $0.record) } ?? []
    }

    /// The questions recorded for `sessionID`, oldest first; empty when none were.
    func loadQuestions(sessionID: String) -> [Question] {
        file(sessionID)?.questions ?? []
    }

    /// Saves the session's records and questions (the caller's whole lists, oldest first), the
    /// newest `limit` and `questionLimit` kept.
    func save(sessionID: String, records: [(id: String, record: Record)], questions: [Question] = []) {
        let entries = records.suffix(Self.limit).map { Entry(id: $0.id, record: $0.record) }
        let questions = Array(questions.suffix(Self.questionLimit))
        let url = url(for: sessionID)
        let directory = directory
        writes.async {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let file = File(entries: Array(entries), questions: questions.isEmpty ? nil : questions)
                try JSONEncoder().encode(file).write(to: url, options: .atomic)
            } catch {
                ShepherdLog.warning("thread origins for \(sessionID) not saved: \(error)")
            }
        }
    }

    /// Waits for every write queued so far: the server stopping, so a relaunch reads them, and tests.
    func flush() {
        writes.sync {}
    }

    private func file(_ sessionID: String) -> File? {
        guard let data = try? Data(contentsOf: url(for: sessionID)) else { return nil }
        return try? JSONDecoder().decode(File.self, from: data)
    }

    private func url(for sessionID: String) -> URL {
        let safe = String(sessionID.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" || scalar == "." ? Character(scalar) : "_"
        })
        return directory.appendingPathComponent("\(safe.isEmpty ? "_" : safe).json")
    }
}
