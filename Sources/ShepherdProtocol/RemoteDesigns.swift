import Foundation
import ShepherdCore

// The Design tool over the remote listener (`RemoteProtocol.designsCapability`): a client lists a
// host's designs, fetches their files by hash and renders the boards itself, and changes a design
// through the same server mutations the host's own canvas uses. docs/designs.md › Remote.

extension RemoteProtocol {
    /// The host serves `RemoteRequest.design` while its Design tool experiment is on, and pushes
    /// `designChanged` for the designs a client watches. A client lists it too: it reads those
    /// pushes and `capabilitiesChanged`.
    public static let designsCapability = "designs.v1"
    /// The host takes Pencil markup (`RemoteDesignRequest.sendMarkup`) and applies the design
    /// agent's proposals from it (`addProposedComments`). Offered with `designsCapability`.
    public static let designMarkupCapability = "design.markup.v1"
    /// The most file bytes one design reply carries: files inline in `boards`, or one piece of a
    /// file or upload. Base64 keeps it well under the 1 MiB frame.
    public static let designChunkBytes = 256 * 1024
}

/// Where a board's files come from when it renders: a design's project files by their path
/// (`tokens.css`, `A.dc.html`, `ds/acme/bundle.js`), and its uploads (`/_blob/<id>`). A host's
/// design folder is one; a remote host's files, fetched by hash and cached on this device, are
/// another (`RemoteDesignFiles`). Paths are checked by the renderer before they are asked for.
public protocol DesignFileSource: Sendable {
    /// A project file's bytes, or nil when the design has no such file.
    func projectFile(_ path: String) async -> Data?
    /// An upload's file name (`<id>.<ext>`, for its type) and bytes, or nil.
    func blob(_ id: String) async -> (name: String, data: Data)?
}

/// A design as a host's Designs list shows it.
public struct RemoteDesignSummary: Codable, Hashable, Sendable, Identifiable {
    public var design: Design
    /// The design's files' revision.
    public var revision: UInt64
    /// Boards its canvas lists.
    public var boardCount: Int
    /// Comments not yet resolved.
    public var openComments: Int
    /// The first board in `order`, for its thumbnail: fetched by hash like any file.
    public var firstBoard: RemoteDesignFirstBoard?

    public var id: DesignID { design.id }

    public init(design: Design, revision: UInt64, boardCount: Int, openComments: Int, firstBoard: RemoteDesignFirstBoard?) {
        self.design = design
        self.revision = revision
        self.boardCount = boardCount
        self.openComments = openComments
        self.firstBoard = firstBoard
    }
}

/// A design's first board: its path, hash and canvas size.
public struct RemoteDesignFirstBoard: Codable, Hashable, Sendable {
    public var path: DesignPath
    public var sha256: String
    public var width: Double
    public var height: Double

    public init(path: DesignPath, sha256: String, width: Double, height: Double) {
        self.path = path
        self.sha256 = sha256
        self.width = width
        self.height = height
    }
}

/// A host's designs, most recently changed first, and its design systems.
public struct RemoteDesignListing: Codable, Hashable, Sendable {
    public var designs: [RemoteDesignSummary]
    public var systems: [DesignSystemSummary]

    public init(designs: [RemoteDesignSummary], systems: [DesignSystemSummary]) {
        self.designs = designs
        self.systems = systems
    }
}

/// One file under a design's `project/`: its path there, SHA-256 (lower-case hex) and size.
public struct RemoteDesignFileInfo: Codable, Hashable, Sendable {
    public var path: String
    public var sha256: String
    public var size: Int

    public init(path: String, sha256: String, size: Int) {
        self.path = path
        self.sha256 = sha256
        self.size = size
    }
}

/// A design's index with the hash of every file its boards may load: the boards and the rest of
/// `project/` (installed systems, stylesheets, fonts, images), never `canvas.json` (it is the
/// index) nor any `support.js` (each device serves its own runtime there).
public struct RemoteDesignIndex: Codable, Hashable, Sendable {
    public var snapshot: DesignSnapshot
    public var files: [RemoteDesignFileInfo]

    public init(snapshot: DesignSnapshot, files: [RemoteDesignFileInfo]) {
        self.snapshot = snapshot
        self.files = files
    }
}

/// A file a `boards` request found changed: its bytes when they fit the reply, else nil (fetch
/// it in pieces with `RemoteDesignRequest.file`).
public struct RemoteDesignFile: Codable, Hashable, Sendable {
    public var path: String
    public var sha256: String
    public var size: Int
    public var data: Data?

    public init(path: String, sha256: String, size: Int, data: Data?) {
        self.path = path
        self.sha256 = sha256
        self.size = size
        self.data = data
    }
}

/// What a `boards` request answers: the files whose hash differs from the one the client named
/// (its bytes inline while they fit `designChunkBytes`), the paths it already holds, and the ones
/// the design doesn't have.
public struct RemoteDesignFiles: Codable, Hashable, Sendable {
    public var designID: DesignID
    public var revision: UInt64
    public var changed: [RemoteDesignFile]
    public var unchanged: [String]
    public var missing: [String]

    public init(designID: DesignID, revision: UInt64, changed: [RemoteDesignFile], unchanged: [String], missing: [String]) {
        self.designID = designID
        self.revision = revision
        self.changed = changed
        self.unchanged = unchanged
        self.missing = missing
    }
}

/// A piece of one file or upload, from `offset`: `total` bytes in all, whose SHA-256 is
/// `sha256`. A download resumes by asking for the next offset.
public struct RemoteDesignChunk: Codable, Hashable, Sendable {
    /// The upload's file name (`<id>.<ext>`); nil for a project file.
    public var name: String?
    public var sha256: String
    public var offset: Int
    public var total: Int
    public var data: Data

    public init(name: String? = nil, sha256: String, offset: Int, total: Int, data: Data) {
        self.name = name
        self.sha256 = sha256
        self.offset = offset
        self.total = total
        self.data = data
    }

    /// The last piece.
    public var isLast: Bool { offset + data.count >= total }
}

/// Several boards written as one change (Tweak's "Every <name>", an undo): the write, each
/// board's hash now, and the version each changed board's earlier content was kept as.
public struct RemoteDesignBoardsWrite: Codable, Hashable, Sendable {
    public var result: DesignWriteResult
    public var shas: [String: String]
    public var versions: [String: Int]

    public init(result: DesignWriteResult, shas: [String: String], versions: [String: Int]) {
        self.result = result
        self.shas = shas
        self.versions = versions
    }

    public init(_ write: DesignBoardsWrite) {
        self.init(result: write.result,
                  shas: Dictionary(uniqueKeysWithValues: write.shas.map { ($0.key.rawValue, $0.value) }),
                  versions: Dictionary(uniqueKeysWithValues: write.versions.map { ($0.key.rawValue, $0.value) }))
    }

    /// Back in the host's shape; a path outside the grammar (never sent by a host) is left out.
    public var write: DesignBoardsWrite {
        DesignBoardsWrite(result: result,
                          shas: Dictionary(uniqueKeysWithValues: shas.compactMap { key, sha in DesignPath(key).map { ($0, sha) } }),
                          versions: Dictionary(uniqueKeysWithValues: versions.compactMap { key, n in DesignPath(key).map { ($0, n) } }))
    }
}

/// Client → host, inside `RemoteRequest.design` (`designsCapability`). Paths travel as the
/// client wrote them; the host checks each against the grammar before touching a file.
public enum RemoteDesignRequest: Codable, Hashable, Sendable {
    /// The host's designs and design systems.
    case list
    /// A design's index, revision, and every file's hash.
    case index(designID: DesignID)
    /// The files among `paths` (nil: every file of the index) whose hash isn't the one
    /// `knownShas` names for them.
    case boards(designID: DesignID, paths: [String]?, knownShas: [String: String])
    /// A piece of one project file from `offset`, while it still has the hash `sha256`.
    case file(designID: DesignID, path: String, sha256: String, offset: Int)
    /// A piece of one upload (`/_blob/<id>`) from `offset`.
    case asset(designID: DesignID, blobID: String, offset: Int)
    case comments(designID: DesignID)
    /// Pins a comment, as the host's canvas does: checked against the board's source, then
    /// handed to the design agent fenced as data.
    case addComment(designID: DesignID, draft: DesignCommentDraft, baseRevision: UInt64?)
    case replyToComment(designID: DesignID, commentID: UUID, text: String, baseRevision: UInt64?)
    case resolveComment(designID: DesignID, commentID: UUID, resolved: Bool, baseRevision: UInt64?)
    /// Writes boards' whole sources as one change (Tweak).
    case writeBoards(designID: DesignID, sources: [String: String], baseRevision: UInt64?)
    /// A canvas update (a board moved, a Tweak's props).
    case updateIndex(designID: DesignID, patch: JSONValue, baseRevision: UInt64?)
    case duplicateBoard(designID: DesignID, path: String, baseRevision: UInt64?)
    /// Puts boards back to kept versions (Tweak's Undo), only while each still has the hash
    /// `ifCurrent` names.
    case restoreVersions(designID: DesignID, versions: [String: Int], ifCurrent: [String: String]?)
    /// One design system whole.
    case system(namespace: String)
    /// The designs this client shows: the host pushes `designChanged` for these alone. Replaces
    /// the last set.
    case watch(designIDs: [DesignID])
    /// The viewer's Pencil markup (`designMarkupCapability`): checked against the boards'
    /// sources, then handed to the design agent fenced as data, as a turn of its own.
    case sendMarkup(designID: DesignID, markup: DesignMarkup)
    /// The design agent's proposals from the markup, kept as comments at the comments'
    /// revision (`designMarkupCapability`). `deliver` hands each to the agent as a comment is
    /// ("Apply both"); without it they stay on the canvas as comments ("Keep as comments"). A
    /// proposal the design already keeps a comment for is not kept twice.
    case addProposedComments(designID: DesignID, drafts: [DesignCommentDraft], deliver: Bool, baseRevision: UInt64?)

    /// The design it touches, if one.
    public var designID: DesignID? {
        switch self {
        case .list, .system, .watch: nil
        case .index(let id), .boards(let id, _, _), .file(let id, _, _, _), .asset(let id, _, _), .comments(let id),
             .addComment(let id, _, _), .replyToComment(let id, _, _, _), .resolveComment(let id, _, _, _),
             .writeBoards(let id, _, _), .updateIndex(let id, _, _), .duplicateBoard(let id, _, _), .restoreVersions(let id, _, _),
             .sendMarkup(let id, _), .addProposedComments(let id, _, _, _):
            id
        }
    }

    /// Whether it changes the design (a write, a comment).
    public var writes: Bool {
        switch self {
        case .addComment, .replyToComment, .resolveComment, .writeBoards, .updateIndex, .duplicateBoard, .restoreVersions,
             .sendMarkup, .addProposedComments: true
        default: false
        }
    }

    /// The capability beside `designsCapability` the host must offer for it, if one.
    public var capability: String? {
        switch self {
        case .sendMarkup, .addProposedComments: RemoteProtocol.designMarkupCapability
        default: nil
        }
    }
}

/// Host → client, inside `RemoteReply.design`.
public enum RemoteDesignResult: Codable, Hashable, Sendable {
    case listing(RemoteDesignListing)
    case index(RemoteDesignIndex)
    case files(RemoteDesignFiles)
    case chunk(RemoteDesignChunk)
    case comments(DesignComments)
    /// A comment as kept, and why it didn't reach the design agent (nil: it went, or waits in
    /// the agent's queue).
    case comment(DesignComment, undelivered: String?)
    case written(DesignWriteResult)
    case boardsWritten(RemoteDesignBoardsWrite)
    case duplicated(path: DesignPath, result: DesignWriteResult)
    case system(DesignSystemRead)
    /// The markup reached the design agent's queue, or why it couldn't (the record is not
    /// kept: send it again).
    case markupSent(undelivered: String?)
    /// The proposals as kept (each once), and why any didn't reach the design agent.
    case proposedCommentsAdded([DesignComment], undelivered: String?)
    case ok
}

/// Stable codes a host refuses a design request with (beside `DesignStoreError.code`).
public enum RemoteDesignCode {
    /// The host's Design tool experiment is off.
    public static let off = "designs_off"
    /// The file's hash moved since the client read it: read the index again.
    public static let staleFile = "stale_file"
    public static let noSuchFile = "no_such_file"
    /// A markup record outside its grammar, or naming a board or element the design lacks.
    public static let invalidMarkup = "invalid_markup"
}
