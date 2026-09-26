import Foundation
import ShepherdCore

/// A file of a design system's folder (`tokens.json`, `tokens.css`, `README.md`,
/// `components/Button.html`): a path the system keeps, and the same path under a design's
/// `project/ds/<namespace>/` once it is installed.
public enum DesignSystemFile {
    public static let tokens = "tokens.json"
    public static let stylesheet = "tokens.css"
    public static let readme = "README.md"
    /// Shepherd's record of the system (`DesignSystemInfo`): never one of its files, never
    /// installed.
    public static let info = "system.json"

    /// The kinds of file a system holds: text a board can load or a reader can read.
    public static let extensions: Set<String> = ["json", "css", "js", "md", "html", "svg", "txt"]
    public static let maxFiles = 64
    /// Each file fits the extension socket's frame.
    public static let maxFileBytes = 900_000
    public static let maxTotalBytes = 8_000_000
    public static let maxPathLength = 200

    /// Whether `path` may name a file of a system: segments of `[A-Za-z0-9_][A-Za-z0-9_.-]*`
    /// joined by `/`, at most 6 deep, no `..`, one of `extensions`, and never `system.json`.
    public static func isPath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= maxPathLength, !path.hasPrefix("/"), !path.contains("\\"),
              !path.contains(".."), path != info else { return false }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count <= 6, segments.allSatisfy(DesignPath.isSegment) else { return false }
        let name = segments.last.map(String.init) ?? ""
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        return extensions.contains(name[name.index(after: dot)...].lowercased())
    }

    /// Whether `path` may name a stylesheet a system is read from, relative to its project:
    /// the same segments, a `.css`, `.scss` or `.less` file.
    public static func isSourcePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 400, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("..") else { return false }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count <= 16, segments.allSatisfy(DesignPath.isSegment) else { return false }
        let lower = path.lowercased()
        return lower.hasSuffix(".css") || lower.hasSuffix(".scss") || lower.hasSuffix(".less")
    }
}

/// Shepherd's record of a design system (`<support>/design-systems/<namespace>/system.json`):
/// its revision, who may write it, and where it was read from. Not a file of the system, so an
/// installed copy never carries it.
public struct DesignSystemInfo: Hashable, Sendable, Codable {
    public var namespace: String
    public var title: String
    /// Moves with every change to the system's files; a write naming an older one is refused.
    public var revision: UInt64
    /// Milliseconds since 1970.
    public var createdAt: Double
    public var updatedAt: Double
    /// When its tokens were last read from their stylesheets (nil: never).
    public var syncedAt: Double?
    /// The design whose agent built it: only that design's agent writes it.
    public var ownerDesignID: DesignID?
    /// The project it was read from, and its stylesheets there, relative to the project.
    public var spaceID: SpaceID?
    public var sources: [String]

    public init(namespace: String, title: String, revision: UInt64 = 0, createdAt: Double, updatedAt: Double? = nil,
                syncedAt: Double? = nil, ownerDesignID: DesignID? = nil, spaceID: SpaceID? = nil, sources: [String] = []) {
        self.namespace = namespace
        self.title = title
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.syncedAt = syncedAt
        self.ownerDesignID = ownerDesignID
        self.spaceID = spaceID
        self.sources = sources
    }

    private enum CodingKeys: String, CodingKey {
        case namespace, title, revision, createdAt, updatedAt, syncedAt, ownerDesignID, spaceID, sources
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        namespace = try c.decode(String.self, forKey: .namespace)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? namespace
        revision = try c.decodeIfPresent(UInt64.self, forKey: .revision) ?? 0
        createdAt = try c.decodeIfPresent(Double.self, forKey: .createdAt) ?? 0
        updatedAt = try c.decodeIfPresent(Double.self, forKey: .updatedAt) ?? createdAt
        syncedAt = try c.decodeIfPresent(Double.self, forKey: .syncedAt)
        ownerDesignID = try c.decodeIfPresent(DesignID.self, forKey: .ownerDesignID)
        spaceID = try c.decodeIfPresent(SpaceID.self, forKey: .spaceID)
        sources = try c.decodeIfPresent([String].self, forKey: .sources) ?? []
    }
}

/// A design system as a list shows it: its record, whether Shepherd ships it (Night Watch), and
/// how many tokens of each kind it has.
public struct DesignSystemSummary: Hashable, Sendable, Codable {
    public var info: DesignSystemInfo
    /// Built into Shepherd: read-only, and never synced.
    public var builtIn: Bool
    public var counts: DesignSystemCounts
    /// Its tokens.json can't be read (nil counts then read as zero).
    public var unreadable: Bool

    public init(info: DesignSystemInfo, builtIn: Bool = false, counts: DesignSystemCounts = DesignSystemCounts(),
                unreadable: Bool = false) {
        self.info = info
        self.builtIn = builtIn
        self.counts = counts
        self.unreadable = unreadable
    }

    public var namespace: String { info.namespace }
}

/// One design system whole: its summary, its tokens (read into Shepherd's schema), its
/// README, and the files its folder holds.
public struct DesignSystemRead: Hashable, Sendable, Codable {
    public var summary: DesignSystemSummary
    public var tokens: DesignSystemTokens?
    public var readme: String?
    public var files: [String]

    /// A README is read up to this many bytes.
    public static let maxReadmeBytes = 64_000

    public init(summary: DesignSystemSummary, tokens: DesignSystemTokens?, readme: String?, files: [String]) {
        self.summary = summary
        self.tokens = tokens
        self.readme = readme
        self.files = files
    }
}

/// A system installed in a design: its record in canvas.json's `designSystems`, and the tokens
/// its copy under `project/ds/<namespace>/` holds (from tokens.json, else the custom
/// properties of tokens.css; nil when neither reads).
public struct DesignSystemInstalled: Hashable, Sendable, Codable {
    public var namespace: String
    public var title: String?
    /// Installed by Shepherd (its record says `"origin": "shepherd"`); a record from claude.ai
    /// is kept as it is.
    public var shepherd: Bool
    public var version: String?
    public var tokens: DesignSystemTokens?
    /// Where the tokens were read from: `ds/acme-web/tokens.json`.
    public var tokensFile: String?

    public init(namespace: String, title: String?, shepherd: Bool, version: String? = nil, tokens: DesignSystemTokens?,
                tokensFile: String?) {
        self.namespace = namespace
        self.title = title
        self.shepherd = shepherd
        self.version = version
        self.tokens = tokens
        self.tokensFile = tokensFile
    }
}

/// What `system_read` without a namespace answers: every system this host has, and the ones the
/// design has installed (the design's own system first).
public struct DesignSystemListing: Hashable, Sendable, Codable {
    public var systems: [DesignSystemSummary]
    public var installed: [DesignSystemInstalled]
    /// The system the design is drawn in (`Design.systemNamespace`).
    public var primary: String?

    public init(systems: [DesignSystemSummary], installed: [DesignSystemInstalled], primary: String?) {
        self.systems = systems
        self.installed = installed
        self.primary = primary
    }
}

/// A `system_write`: a system's tokens and files, where they were read from, and whether to
/// install it in the writer's design. With no tokens and no files it writes nothing and only
/// installs.
public struct DesignSystemWrite: Hashable, Sendable, Codable {
    public var namespace: String
    public var title: String?
    /// tokens.json as JSON: Shepherd's schema, or a canvas's own shape.
    public var tokens: JSONValue?
    /// Other files by path: text to write, or null to remove.
    public var files: [String: JSONValue]?
    /// The project's stylesheets the tokens were read from, relative to the project: what
    /// Re-sync reads again.
    public var sources: [String]?
    public var install: Bool?
    /// The system's revision this write is based on (nil: whatever it is at).
    public var baseRevision: UInt64?

    public init(namespace: String, title: String? = nil, tokens: JSONValue? = nil, files: [String: JSONValue]? = nil,
                sources: [String]? = nil, install: Bool? = nil, baseRevision: UInt64? = nil) {
        self.namespace = namespace
        self.title = title
        self.tokens = tokens
        self.files = files
        self.sources = sources
        self.install = install
        self.baseRevision = baseRevision
    }

    /// Whether it writes the system's folder (anything besides installing).
    public var writesFiles: Bool {
        tokens != nil || !(files ?? [:]).isEmpty || sources != nil || title != nil
    }
}

/// What a `system_write` left behind: the system after it, whether its files changed, what an
/// install wrote to the design, and what is worth knowing.
public struct DesignSystemWriteResult: Hashable, Sendable, Codable {
    public var summary: DesignSystemSummary
    public var changed: Bool
    /// The design's write, when the system was installed in it.
    public var installed: DesignWriteResult?
    public var notes: [String]

    public init(summary: DesignSystemSummary, changed: Bool, installed: DesignWriteResult? = nil, notes: [String] = []) {
        self.summary = summary
        self.changed = changed
        self.installed = installed
        self.notes = notes
    }
}

/// What a Re-sync did: the system after it and what changed in its tokens.
public struct DesignSystemSyncResult: Hashable, Sendable, Codable {
    public var summary: DesignSystemSummary
    public var changes: DesignSystemSyncChanges

    public init(summary: DesignSystemSummary, changes: DesignSystemSyncChanges) {
        self.summary = summary
        self.changes = changes
    }
}

extension DesignIndex.SystemRecord {
    /// The record Shepherd writes when it installs a system: its title, folder, the revision it
    /// copied (`version`), when (`copiedAt`, RFC 3339), and `"origin": "shepherd"`.
    public static func shepherd(title: String, namespace: String, revision: UInt64, copiedAt: Date) -> DesignIndex.SystemRecord {
        DesignIndex.SystemRecord(title: title, namespace: namespace, extra: [
            "version": .string(String(revision)),
            "copiedAt": .string(ISO8601DateFormatter().string(from: copiedAt)),
            "origin": .string("shepherd"),
        ])
    }

    /// Installed by Shepherd, rather than kept from claude.ai.
    public var isShepherds: Bool { extra["origin"]?.stringValue == "shepherd" }
}
