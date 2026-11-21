import Foundation
import ShepherdCore
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

        init(id: String, record: NativeQuestionRecord, endedAt: Double) {
            self.id = id
            self.record = record
            self.endedAt = endedAt
        }

        private enum CodingKeys: String, CodingKey { case id, record, endedAt }
        private enum RecordKey: String, CodingKey { case kind, question, answer, confirmed, outcome, askedAt }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            id = try fields.decode(String.self, forKey: .id)
            endedAt = try fields.decode(Double.self, forKey: .endedAt)
            // The wire decoder tolerates partial records from older hosts. The file writer never emits them.
            let saved = try fields.nestedContainer(keyedBy: RecordKey.self, forKey: .record)
            record = try NativeQuestionRecord(kind: saved.decodeWhenPresent(.kind),
                question: saved.decode(String.self, forKey: .question), answer: saved.decodeWhenPresent(.answer),
                confirmed: saved.decodeWhenPresent(.confirmed), outcome: saved.decode(NativeQuestionRecord.Outcome.self, forKey: .outcome),
                askedAt: saved.decode(Double.self, forKey: .askedAt))
        }
    }

    /// What the file keeps for one message.
    struct Record: Codable, Hashable, Sendable {
        struct Part: Codable, Hashable, Sendable {
            var id: UUID?
            /// UTF-8 bytes of the part's text within the message.
            var bytes: Int
            var sentAt: Double
            var images: Int

            init(id: UUID?, bytes: Int, sentAt: Double, images: Int) {
                self.id = id
                self.bytes = bytes
                self.sentAt = sentAt
                self.images = images
            }

            private enum CodingKeys: String, CodingKey { case id, bytes, sentAt, images }

            init(from decoder: Decoder) throws {
                let fields = try decoder.container(keyedBy: CodingKeys.self)
                id = try fields.decodeWhenPresent(.id)
                bytes = try fields.decode(Int.self, forKey: .bytes)
                sentAt = try fields.decode(Double.self, forKey: .sentAt)
                images = try fields.decode(Int.self, forKey: .images)
                guard bytes >= 0, images >= 0 else { throw CocoaError(.fileReadCorruptFile) }
            }
        }

        var steered: Bool?
        var parts: [Part]?
        /// The design references' copies (`DesignReferencePayload.id`) a message the user sent in
        /// this thread carried: the thread draws that message's fence as chips, and no other's.
        var references: [String]?
        /// The `/name args` the user typed for a prompt template pi expanded, which pi's text
        /// no longer names (`NativeThreadMessage.typedCommand`).
        var command: String?

        init(references: [String]? = nil, command: String? = nil) {
            self.references = references
            self.command = command
        }

        private enum CodingKeys: String, CodingKey { case steered, parts, references, command }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            steered = try fields.decodeWhenPresent(.steered)
            parts = try fields.decodeWhenPresent(.parts)
            references = try fields.decodeWhenPresent(.references)
            command = try fields.decodeWhenPresent(.command)
        }

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
                guard part.bytes >= 0, part.bytes <= bytes.count - offset,
                      let piece = String(bytes: bytes[offset..<(offset + part.bytes)], encoding: .utf8) else { return nil }
                result.append(NativeQueuePart(id: part.id, text: piece, sentAt: part.sentAt, images: part.images))
                offset += part.bytes
            }
            return .queue(parts: result)
        }
    }

    private struct File: Codable, Equatable {
        var version = 1
        /// Oldest first.
        var entries: [Entry] = []
        /// Oldest first. Absent from files written before questions were kept.
        var questions: [Question]?

        init(entries: [Entry] = [], questions: [Question]? = nil) {
            self.entries = entries
            self.questions = questions
        }

        private enum CodingKeys: String, CodingKey { case version, entries, questions }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            version = try fields.decode(Int.self, forKey: .version)
            guard version == 1 else { throw CocoaError(.fileReadCorruptFile) }
            entries = try fields.decode([Entry].self, forKey: .entries)
            questions = try fields.decodeWhenPresent(.questions)
        }
    }

    private struct Entry: Codable, Equatable {
        var id: String
        var record: Record
    }

    struct Snapshot: Sendable {
        var entries: [(id: String, record: Record)]
        var questions: [Question]
        var generation: UInt64
        var problem: String?
    }

    private struct Stamp: Equatable {
        var fingerprint: String

        init?(_ url: URL) {
            var info = stat()
            guard stat(url.path, &info) == 0 else { return nil }
            fingerprint = "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
        }
    }

    private struct Cached {
        var file = File()
        var stamp: Stamp?
        var missing = false
        var generation: UInt64 = 0
        var problem: String?

        var snapshot: Snapshot {
            Snapshot(entries: file.entries.map { ($0.id, $0.record) }, questions: file.questions ?? [],
                     generation: generation, problem: problem)
        }
    }

    let directory: URL
    /// One queue owns the cache, reads, and replacements. The server never waits on it.
    let io = DispatchQueue(label: "shepherd.thread-origins", qos: .utility)
    private var cache: [URL: Cached] = [:]

    init(directory: URL) {
        self.directory = directory
    }

    func load(sessionID: String) -> [(id: String, record: Record)] { loadSession(sessionID: sessionID).entries }

    func loadQuestions(sessionID: String) -> [Question] { loadSession(sessionID: sessionID).questions }

    /// Standalone preview and tests. Live threads use the asynchronous read.
    func loadSession(sessionID: String) -> Snapshot {
        io.sync { refresh(url(for: sessionID)).snapshot }
    }

    func loadSession(sessionID: String, receive: @escaping (Snapshot) -> Void) {
        io.async { receive(self.refresh(self.url(for: sessionID)).snapshot) }
    }

    /// `generation` belongs to the read the caller built these lists on, not the time the write runs.
    func save(sessionID: String, records: [(id: String, record: Record)], questions: [Question] = [],
              generation: UInt64, refused: ((Snapshot) -> Void)? = nil) {
        let entries = records.suffix(Self.limit).map { Entry(id: $0.id, record: $0.record) }
        let questions = Array(questions.suffix(Self.questionLimit))
        let url = url(for: sessionID)
        io.async {
            do {
                let file = File(entries: entries, questions: questions.isEmpty ? nil : questions)
                let data = try JSONEncoder().encode(file)
                var current = self.refresh(url, force: true)
                guard current.problem == nil, generation == current.generation else {
                    refused?(current.snapshot)
                    return
                }
                try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                current.file = file
                current.missing = false
                current.stamp = Stamp(url)
                self.cache[url] = current
            } catch {
                ShepherdLog.warning("thread origins not saved at \(url.path): \(error.localizedDescription)")
            }
        }
    }

    /// Waits for every write queued so far: the server stopping, so a relaunch reads them, and tests.
    func flush() { io.sync {} }

    private func refresh(_ url: URL, force: Bool = false) -> Cached {
        var current = cache[url] ?? Cached()
        let stamp = Stamp(url)
        if !force, let stamp, stamp == current.stamp { return current }
        let wasDamaged = current.problem != nil
        switch PersistedFile<File>.load(from: url, exactEnvelope: true) {
        case .loaded(let file):
            if wasDamaged || (cache[url] != nil && (file != current.file || stamp != current.stamp)) { current.generation &+= 1 }
            current.file = file
            current.missing = false
            current.problem = nil
        case .missing:
            if wasDamaged {
                current.generation &+= 1
            } else if !current.missing, current.stamp != nil {
                current.generation &+= 1
                current.file = File()
            }
            current.missing = true
            current.problem = nil
        case .damaged(let original, let error):
            if !wasDamaged { current.generation &+= 1 }
            let reason = if original != nil { "Invalid thread history JSON." }
                else if (error as? CocoaError)?.code == .fileReadNoPermission { "Permission denied." }
                else { "The file could not be read." }
            let problem = "Saved questions and message details could not be read at \(url.path). \(reason) Fix access or restore a known-good backup on the host, then refresh the thread. New details won't be saved until then."
            current.problem = problem
            if !wasDamaged { ShepherdLog.warning(problem) }
        }
        if wasDamaged, current.problem == nil { ShepherdLog.info("Thread history metadata recovered at \(url.path)") }
        current.stamp = stamp
        cache[url] = current
        return current
    }

    private func url(for sessionID: String) -> URL {
        let safe = String(sessionID.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" || scalar == "." ? Character(scalar) : "_"
        })
        return directory.appendingPathComponent("\(safe.isEmpty ? "_" : safe).json", isDirectory: false)
    }
}

private extension KeyedDecodingContainer {
    func decodeWhenPresent<Value: Decodable>(_ key: Key) throws -> Value? {
        try contains(key) ? decode(Value.self, forKey: key) : nil
    }
}
