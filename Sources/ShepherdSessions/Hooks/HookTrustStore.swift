import Foundation

/// `<support>/hooks/trust.json` (docs/hooks.md › Identity and trust): which exact hooks the
/// person trusted, which of those are off, and whether the Claude Code and Codex readers are on.
public struct HookTrust: Equatable, Sendable, Codable {
    /// Why a hash was trusted.
    public enum Source: String, Codable, Sendable { case review, proposal, edit }

    /// One trusted hook: where it was and what it was, so a later change can be diffed.
    public struct Record: Equatable, Sendable, Codable {
        public var slot: String
        /// The canonical JSON of the handler when it was trusted.
        public var entry: String
        public var matcher: String
        /// ISO 8601.
        public var at: String
        public var by: String

        public init(slot: String, entry: String, matcher: String, at: String, by: String) {
            self.slot = slot; self.entry = entry; self.matcher = matcher; self.at = at; self.by = by
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            slot = (try? c.decode(String.self, forKey: .slot)) ?? ""
            entry = (try? c.decode(String.self, forKey: .entry)) ?? ""
            matcher = (try? c.decode(String.self, forKey: .matcher)) ?? ""
            at = (try? c.decode(String.self, forKey: .at)) ?? ""
            by = (try? c.decode(String.self, forKey: .by)) ?? ""
        }
    }

    /// The Sources switches: whether Claude Code's and Codex's files are read. Both default on.
    public struct Readers: Equatable, Sendable, Codable {
        public var claude = true
        public var codex = true
        public init(claude: Bool = true, codex: Bool = true) { self.claude = claude; self.codex = codex }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            claude = (try? c.decode(Bool.self, forKey: .claude)) ?? true
            codex = (try? c.decode(Bool.self, forKey: .codex)) ?? true
        }
        /// Whether files of `format` are read.
        public func reads(_ format: HookFormat) -> Bool {
            switch format {
            case .shepherd: true
            case .claude: claude
            case .codex: codex
            }
        }
    }

    public var version = 1
    /// Keyed by hash.
    public var trusted: [String: Record] = [:]
    /// Trusted hashes that are switched off.
    public var off: [String] = []
    public var readers = Readers()

    public init(trusted: [String: Record] = [:], off: [String] = [], readers: Readers = Readers()) {
        self.trusted = trusted; self.off = off; self.readers = readers
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decode(Int.self, forKey: .version)) ?? 1
        trusted = (try? c.decode([String: Record].self, forKey: .trusted)) ?? [:]
        off = (try? c.decode([String].self, forKey: .off)) ?? []
        readers = (try? c.decode(Readers.self, forKey: .readers)) ?? Readers()
    }

    /// Whether a hook with this hash runs: trusted and not off.
    public func runs(_ hash: String) -> Bool { trusted[hash] != nil && !off.contains(hash) }

    /// The review state of a hook at `slot` with `hash`.
    public func review(hash: String, slot: String) -> HookReview {
        if trusted[hash] != nil { return off.contains(hash) ? .off : .on }
        if let previous = trusted.values.filter({ $0.slot == slot }).max(by: { $0.at < $1.at }) { return .changed(previous: previous) }
        return .new
    }
}

/// Reads and writes `trust.json`. Every change reads the file, applies itself and writes the whole
/// file by temp file and rename; a missing or invalid file reads as empty.
// ponytail: an in-process lock only; the runtime's proposal path can race a write from the app.
// Add a lock file shared with the runtime if that shows up.
public final class HookTrustStore: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()

    /// `support` is Shepherd's Application Support folder; the file is `<support>/hooks/trust.json`.
    public init(support: URL) {
        url = support.appendingPathComponent("hooks", isDirectory: true).appendingPathComponent("trust.json")
    }

    /// The file as it is now, or an empty trust when it is missing or invalid.
    public func read() -> HookTrust {
        lock.withLock { load() }
    }

    /// Trusts each entry's current hash (Review's Trust, a proposal, an edit), on.
    public func trust(_ entries: [HookEntry], by source: HookTrust.Source, now: Date = Date()) throws {
        try change { trust in
            for entry in entries {
                trust.trusted[entry.hash] = HookTrust.Record(slot: entry.slot, entry: entry.canonical, matcher: entry.matcher,
                                                             at: Self.timestamp(now), by: source.rawValue)
                trust.off.removeAll { $0 == entry.hash }
            }
        }
    }

    /// Review's Keep off: trusts each entry's hash but leaves it off, so it is reviewed and doesn't run.
    public func keepOff(_ entries: [HookEntry], now: Date = Date()) throws {
        try change { trust in
            for entry in entries {
                trust.trusted[entry.hash] = HookTrust.Record(slot: entry.slot, entry: entry.canonical, matcher: entry.matcher,
                                                             at: Self.timestamp(now), by: HookTrust.Source.review.rawValue)
                if !trust.off.contains(entry.hash) { trust.off.append(entry.hash) }
            }
        }
    }

    /// Forgets these hashes, so their hooks are new again and don't run.
    public func untrust(_ hashes: [String]) throws {
        try change { trust in
            for hash in hashes { trust.trusted[hash] = nil }
            trust.off.removeAll { hashes.contains($0) }
        }
    }

    /// Switches a trusted hook on or off. Does nothing for a hash that isn't trusted.
    public func setOn(_ hash: String, _ on: Bool) throws {
        try change { trust in
            guard trust.trusted[hash] != nil else { return }
            trust.off.removeAll { $0 == hash }
            if !on { trust.off.append(hash) }
        }
    }

    /// Turns the Claude Code or Codex reader on or off. Shepherd's own files are always read.
    public func setReader(_ format: HookFormat, _ on: Bool) throws {
        try change { trust in
            switch format {
            case .shepherd: break
            case .claude: trust.readers.claude = on
            case .codex: trust.readers.codex = on
            }
        }
    }

    /// Applies `body` to the current file and writes the result whole.
    public func change(_ body: (inout HookTrust) throws -> Void) throws {
        try lock.withLock {
            var trust = load()
            let before = trust
            try body(&trust)
            guard trust != before || !FileManager.default.fileExists(atPath: url.path) else { return }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            var data = try encoder.encode(trust)
            data.append(UInt8(ascii: "\n"))
            try PiHome.write(data, to: url, mode: 0o600)
        }
    }

    private func load() -> HookTrust {
        guard let data = try? Data(contentsOf: url), let trust = try? JSONDecoder().decode(HookTrust.self, from: data) else { return HookTrust() }
        return trust
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
