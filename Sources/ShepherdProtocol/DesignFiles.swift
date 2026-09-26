import Foundation
import ShepherdCore

/// A design's files as its host has them at one revision: the index and every board file under
/// `project/` (listed or not, as the Design format shows them) with its SHA-256, so a reader
/// fetches only boards whose hash changed.
public struct DesignSnapshot: Hashable, Sendable, Codable {
    public var designID: DesignID
    /// Moves with every change to the design's files; a write naming an older one is refused.
    public var revision: UInt64
    public var index: DesignIndex
    /// Each board file's SHA-256, lower-case hex.
    public var boards: [DesignPath: String]

    public init(designID: DesignID, revision: UInt64, index: DesignIndex, boards: [DesignPath: String]) {
        self.designID = designID
        self.revision = revision
        self.index = index
        self.boards = boards
    }

    private enum CodingKeys: String, CodingKey { case designID, revision, index, boards }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        designID = try c.decode(DesignID.self, forKey: .designID)
        revision = try c.decode(UInt64.self, forKey: .revision)
        index = try c.decode(DesignIndex.self, forKey: .index)
        boards = try Self.decodePathMap(c.decode([String: String].self, forKey: .boards), in: c, key: .boards)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(designID, forKey: .designID)
        try c.encode(revision, forKey: .revision)
        try c.encode(index, forKey: .index)
        try c.encode(Dictionary(uniqueKeysWithValues: boards.map { ($0.key.rawValue, $0.value) }), forKey: .boards)
    }

    private static func decodePathMap(_ raw: [String: String], in c: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) throws -> [DesignPath: String] {
        var map: [DesignPath: String] = [:]
        for (path, value) in raw {
            guard let path = DesignPath(path) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "not a board path: \(path)")
            }
            map[path] = value
        }
        return map
    }
}

/// One board's source at a revision.
public struct DesignBoardSource: Hashable, Sendable, Codable {
    public var path: DesignPath
    public var source: String
    public var sha256: String
    public var revision: UInt64

    public init(path: DesignPath, source: String, sha256: String, revision: UInt64) {
        self.path = path
        self.source = source
        self.sha256 = sha256
        self.revision = revision
    }
}

/// What a write to a design left behind.
public struct DesignWriteResult: Hashable, Sendable, Codable {
    /// The design's revision after the write (unchanged when the write changed nothing).
    public var revision: UInt64
    /// False when the write asked for what the files already held.
    public var changed: Bool
    /// The written board's SHA-256; nil for an index update.
    public var sha256: String?
    /// For a board write, whether it made the board's file (true) or rewrote one (false); nil
    /// for an index update. The design agent's activity line reads it ("Drew" or "Updated").
    public var created: Bool?
    /// What passed but is worth fixing in the written board.
    public var warnings: [DesignBoardCheck.Warning]
    /// The canvas's title and listed board count after the write.
    public var title: String?
    public var boardCount: Int

    public init(revision: UInt64, changed: Bool, sha256: String? = nil, created: Bool? = nil,
                warnings: [DesignBoardCheck.Warning] = [], title: String?, boardCount: Int) {
        self.revision = revision
        self.changed = changed
        self.sha256 = sha256
        self.created = created
        self.warnings = warnings
        self.title = title
        self.boardCount = boardCount
    }
}
