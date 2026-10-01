import Foundation
import ShepherdCore

// The requests and results of the design agent's batch tools (docs/designs.md › The design
// agent): `boards_edit`, `checkpoint_create`/`list`/`restore` and `board_render`. They travel
// as one nested object in their extension message, so a field a build doesn't know is ignored
// and a missing one has its default.

// MARK: - boards_edit

/// `boards_edit`: find-and-replace edits applied to many boards as one change.
public struct DesignBatchEditRequest: Hashable, Sendable, Codable {
    /// A board, and the edits it gets.
    public struct Board: Hashable, Sendable, Codable {
        public var path: String
        /// Edits for this board alone; nil: the request's shared ones.
        public var edits: [DesignBoardEdit]?

        public init(path: String, edits: [DesignBoardEdit]? = nil) {
            self.path = path
            self.edits = edits
        }
    }

    /// The boards to change, in the order to report them.
    public var boards: [Board]
    /// Edits for every board in `boards` that names none of its own.
    public var edits: [DesignBoardEdit]
    /// Write nothing unless every board matches every edit.
    public var atomic: Bool
    /// Report what would happen and write nothing.
    public var dryRun: Bool
    /// Save the design under this name before writing.
    public var checkpoint: String?
    public var tokens: DesignTokenMode?
    /// Snap every off-system value on the boards, not only the ones this write introduces
    /// (`design_check`'s snap).
    public var snapExisting: Bool
    public var baseRevision: UInt64?

    /// Most boards one call may name.
    public static let maxBoards = 200

    public init(boards: [Board], edits: [DesignBoardEdit] = [], atomic: Bool = false, dryRun: Bool = false,
                checkpoint: String? = nil, tokens: DesignTokenMode? = nil, snapExisting: Bool = false, baseRevision: UInt64? = nil) {
        self.boards = boards
        self.edits = edits
        self.atomic = atomic
        self.dryRun = dryRun
        self.checkpoint = checkpoint
        self.tokens = tokens
        self.snapExisting = snapExisting
        self.baseRevision = baseRevision
    }

    private enum CodingKeys: String, CodingKey { case boards, edits, atomic, dryRun, checkpoint, tokens, snapExisting, baseRevision }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        boards = try c.decodeIfPresent([Board].self, forKey: .boards) ?? []
        edits = try c.decodeIfPresent([DesignBoardEdit].self, forKey: .edits) ?? []
        atomic = try c.decodeIfPresent(Bool.self, forKey: .atomic) ?? false
        dryRun = try c.decodeIfPresent(Bool.self, forKey: .dryRun) ?? false
        checkpoint = try c.decodeIfPresent(String.self, forKey: .checkpoint)
        tokens = try c.decodeIfPresent(DesignTokenMode.self, forKey: .tokens)
        snapExisting = try c.decodeIfPresent(Bool.self, forKey: .snapExisting) ?? false
        baseRevision = try c.decodeIfPresent(UInt64.self, forKey: .baseRevision)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(boards, forKey: .boards)
        if !edits.isEmpty { try c.encode(edits, forKey: .edits) }
        if atomic { try c.encode(true, forKey: .atomic) }
        if dryRun { try c.encode(true, forKey: .dryRun) }
        try c.encodeIfPresent(checkpoint, forKey: .checkpoint)
        try c.encodeIfPresent(tokens, forKey: .tokens)
        if snapExisting { try c.encode(true, forKey: .snapExisting) }
        try c.encodeIfPresent(baseRevision, forKey: .baseRevision)
    }
}

/// What a batch did to one board.
public struct DesignBatchBoardResult: Hashable, Sendable, Codable {
    public enum Status: String, Hashable, Sendable, Codable {
        /// Written.
        case edited
        /// The edits apply, and nothing was written (dry run, or atomic with a board that failed).
        case wouldEdit = "would_edit"
        /// The edits left the text as it was.
        case unchanged
        /// An edit matched nothing, or several times without `all`: `edit` and `matches` say which.
        case noMatch = "no_match"
        /// The edited board fails the checks a board write passes.
        case refused
        /// No such board.
        case missing
        /// Not a board path, or an edit that is empty or too many.
        case invalid
    }

    public var path: String
    public var status: Status
    /// For `no_match`: the failing edit (from 1) and how many times it matched (0: nothing).
    public var edit: Int?
    public var matches: Int?
    /// The refusal's words, or why it is invalid.
    public var message: String?
    /// How many matches each edit replaced.
    public var replaced: [Int]
    public var report: DesignBoardReport?

    public init(path: String, status: Status, edit: Int? = nil, matches: Int? = nil, message: String? = nil, replaced: [Int] = [],
                report: DesignBoardReport? = nil) {
        self.path = path
        self.status = status
        self.edit = edit
        self.matches = matches
        self.message = message
        self.replaced = replaced
        self.report = report
    }
}

public struct DesignBatchResult: Hashable, Sendable, Codable {
    /// The one write: its revision after, and whether anything changed.
    public var result: DesignWriteResult
    public var boards: [DesignBatchBoardResult]
    public var dryRun: Bool
    public var atomic: Bool
    /// Atomic, and a board didn't match: nothing was written.
    public var blocked: Bool
    /// The checkpoint the call saved first.
    public var checkpoint: DesignCheckpointInfo?
    /// Checkpoints the save made room by dropping.
    public var pruned: [String]

    public init(result: DesignWriteResult, boards: [DesignBatchBoardResult], dryRun: Bool, atomic: Bool, blocked: Bool,
                checkpoint: DesignCheckpointInfo? = nil, pruned: [String] = []) {
        self.result = result
        self.boards = boards
        self.dryRun = dryRun
        self.atomic = atomic
        self.blocked = blocked
        self.checkpoint = checkpoint
        self.pruned = pruned
    }
}

// MARK: - Checkpoints

/// A saved state of a design: every board file and canvas.json at one revision.
public struct DesignCheckpointInfo: Hashable, Sendable, Codable {
    public var name: String
    /// Milliseconds since 1970.
    public var createdAt: Double
    public var boards: Int
    public var bytes: Int
    /// The design's revision when it was saved.
    public var revision: UInt64

    public init(name: String, createdAt: Double, boards: Int, bytes: Int, revision: UInt64) {
        self.name = name
        self.createdAt = createdAt
        self.boards = boards
        self.bytes = bytes
        self.revision = revision
    }
}

public enum DesignCheckpointName {
    public static let maxLength = 60
    /// Checkpoints a design keeps; saving past it drops the oldest.
    public static let maxPerDesign = 20
    /// All of a design's checkpoints together, in bytes; saving past it drops the oldest.
    public static let maxBytesPerDesign = 200_000_000

    /// A name as it is kept: whitespace runs as one space, trimmed. Nil unless it is 1 to 60
    /// characters of letters, digits, spaces and `_ - . , ' ( ) # + :`, starting with a letter
    /// or digit (so it is never a path, a flag or a command).
    public static func clean(_ raw: String) -> String? {
        let name = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !name.isEmpty, name.count <= maxLength, let first = name.first, first.isLetter || first.isNumber else { return nil }
        let allowed = Set("_-.,'()#+: ")
        guard name.allSatisfy({ $0.isLetter || $0.isNumber || allowed.contains($0) }) else { return nil }
        return name
    }

    /// The name `before restore <name>` an automatic checkpoint takes, cut to fit.
    public static func beforeRestore(_ name: String) -> String {
        let prefix = "before restore "
        return prefix + String(name.prefix(maxLength - prefix.count)).trimmingCharacters(in: .whitespaces)
    }
}

public struct DesignCheckpointRequest: Hashable, Sendable, Codable {
    public enum Action: String, Hashable, Sendable, Codable { case create, list, restore }

    public var action: Action
    public var name: String?

    public init(action: Action, name: String? = nil) {
        self.action = action
        self.name = name
    }
}

public struct DesignCheckpointResult: Hashable, Sendable, Codable {
    public var action: DesignCheckpointRequest.Action
    /// Every checkpoint the design keeps now, oldest first.
    public var checkpoints: [DesignCheckpointInfo]
    /// The one created, or restored.
    public var checkpoint: DesignCheckpointInfo?
    /// A restore saved the design first, under this name.
    public var automatic: DesignCheckpointInfo?
    public var pruned: [String]
    /// A restore's one write.
    public var write: DesignWriteResult?
    /// A restore's boards: put back to what the checkpoint held, made again, and removed (they
    /// came after it).
    public var restored: [String]
    public var recreated: [String]
    public var removed: [String]

    public init(action: DesignCheckpointRequest.Action, checkpoints: [DesignCheckpointInfo], checkpoint: DesignCheckpointInfo? = nil,
                automatic: DesignCheckpointInfo? = nil, pruned: [String] = [], write: DesignWriteResult? = nil,
                restored: [String] = [], recreated: [String] = [], removed: [String] = []) {
        self.action = action
        self.checkpoints = checkpoints
        self.checkpoint = checkpoint
        self.automatic = automatic
        self.pruned = pruned
        self.write = write
        self.restored = restored
        self.recreated = recreated
        self.removed = removed
    }
}

// MARK: - board_render

/// `board_render`: a board drawn by the app, for the agent to look at.
public struct DesignRenderRequest: Hashable, Sendable, Codable {
    public var path: String
    /// The size to lay the board out at, in CSS px; its frame's by default (else its `$preview`).
    public var width: Int?
    public var height: Int?
    /// 1 to 2 (the default 1): pixels per CSS px, before the byte cap.
    public var scale: Double?
    /// Props for this drawing, over the ones Tweak holds for the board.
    public var props: JSONValue?

    public init(path: String, width: Int? = nil, height: Int? = nil, scale: Double? = nil, props: JSONValue? = nil) {
        self.path = path
        self.width = width
        self.height = height
        self.scale = scale
        self.props = props
    }

    public static let widthRange = 40...8000
    public static let scaleRange: ClosedRange<Double> = 1...2

    private enum CodingKeys: String, CodingKey { case path, width, height, scale, props }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        width = try c.decodeIfPresent(Int.self, forKey: .width)
        height = try c.decodeIfPresent(Int.self, forKey: .height)
        scale = try c.decodeIfPresent(Double.self, forKey: .scale)
        props = try c.decodeIfPresent(JSONValue.self, forKey: .props)
    }
}

/// What the app is asked to draw: the board, and the files it needs (`DesignExportFiles`: the
/// canvas, the board and every board it imports, the project's other files and its uploads).
public struct DesignRenderJob: Sendable {
    public var designID: DesignID
    public var path: DesignPath
    public var request: DesignRenderRequest
    public var files: DesignExportFiles

    public init(designID: DesignID, path: DesignPath, request: DesignRenderRequest, files: DesignExportFiles) {
        self.designID = designID
        self.path = path
        self.request = request
        self.files = files
    }
}

/// A render that didn't happen, as the agent is told: a stable `code` and words to act on.
public struct DesignRenderFailure: Error, Hashable, Sendable, CustomStringConvertible {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { message }
}

/// What the app drew: the image the agent gets, and the words that go with it.
public struct DesignRendered: Hashable, Sendable {
    public var image: BrowserImage
    public var text: String

    public init(image: BrowserImage, text: String) {
        self.image = image
        self.text = text
    }
}
