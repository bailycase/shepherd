import Darwin
import Foundation
import ShepherdProtocol

// Artifacts (docs/design/side-pane-artifacts.md): every file a successful `write` call made in this thread. There is no new tool and no
// version history: a path written again is the same artifact, listed once, newest first, with the age of its latest write.

/// What an artifact is, from its file name's extension: how the Artifacts tab previews it.
public enum NativeArtifactKind: String, Equatable, Hashable, Sendable, CaseIterable {
    case markdown, html, svg
    /// Any other file: plain source, in mono.
    case text

    public init(path: String) {
        switch (path as NSString).pathExtension.lowercased() {
        case "md", "markdown", "mdx": self = .markdown
        case "html", "htm": self = .html
        case "svg": self = .svg
        default: self = .text
        }
    }

    /// The kind as the card's and the row's second line says it: "HTML · 6m ago".
    public var label: String {
        switch self {
        case .markdown: "Markdown"
        case .html: "HTML"
        case .svg: "SVG"
        case .text: "Text"
        }
    }

    /// The tile's glyph (PaneArtifacts: `</>` for a page, a document, a picture).
    public var symbol: String {
        switch self {
        case .markdown, .text: "doc.text"
        case .html: "chevron.left.forwardslash.chevron.right"
        case .svg: "photo"
        }
    }

    /// Whether Preview differs from Source. A plain text file has one view, so it draws no Preview | Source switch.
    public var hasPreview: Bool { self != .text }

    /// Whether the thread draws a card for it where it was made. Reports, plans and diagrams get one (the board's); every file the agent
    /// writes is in the pane's list, but a source file would only repeat the "Edited N files" line above it.
    public var showsCard: Bool { self != .text }
}

/// One file the agent made in this thread.
public struct NativeArtifact: Equatable, Hashable, Sendable, Identifiable {
    /// The path as the `write` call gave it (relative to the agent's folder, or absolute): the key the host serves it by.
    public var path: String
    /// Its file name.
    public var name: String
    public var kind: NativeArtifactKind
    /// When its latest write landed (ms since epoch); nil when pi stamped none.
    public var createdAt: Double?

    public var id: String { path }

    public init(path: String, createdAt: Double? = nil) {
        self.path = path
        self.name = (path as NSString).lastPathComponent
        self.kind = NativeArtifactKind(path: path)
        self.createdAt = createdAt
    }

    /// "HTML · 6m ago", "Markdown · just now"; the kind alone while its age is unknown.
    public func detail(now: Date = Date()) -> String {
        guard let createdAt else { return kind.label }
        return kind.label + " · " + NativeArtifactAge.text(createdAt, now: now)
    }
}

/// Where an artifact is on the machine its agent runs on: `~` expanded, a relative path against the agent's folder, `.` and `..` folded.
/// The host resolves a request with it, and the Mac opens a local artifact in an editor from it.
public func nativeArtifactFilePath(_ path: String, cwd: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    let absolute = expanded.hasPrefix("/") ? expanded : (cwd as NSString).appendingPathComponent(expanded)
    return (absolute as NSString).standardizingPath
}

/// Reads an artifact's file. The one reader the host serves a client with and the Mac reads its own threads' files with.
public enum NativeArtifactFile {
    public enum Read: Equatable, Sendable {
        case chunk(NativeArtifactChunk)
        /// An offset that is no place in the file.
        case outOfRange
        /// Gone, not a regular file, a link, or over `NativeArtifactChunk.maxBytes`.
        case unavailable
    }

    /// One piece of `path` (as the write call gave it, against `cwd`) from `offset`. The file is opened without following a link at its last
    /// component (a link put there after the agent wrote it is refused, so a path cannot be turned into another file), must be a regular
    /// file, and is served only up to `NativeArtifactChunk.maxBytes`. Reads the disk: never on a serial server queue or the main thread.
    public static func read(_ path: String, offset: Int, cwd: String) -> Read {
        guard offset >= 0 else { return .outOfRange }
        let fd = open(nativeArtifactFilePath(path, cwd: cwd), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return .unavailable }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0,
              info.st_size <= NativeArtifactChunk.maxBytes else { return .unavailable }
        let total = Int(info.st_size)
        guard offset < total || (offset == 0 && total == 0) else { return .outOfRange }
        var data = Data(count: min(NativeImage.chunkBytes, total - offset))
        let count = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, off_t(offset)) }
        // The file shrank after fstat: it is not the file the client was told about.
        guard count == data.count else { return .unavailable }
        return .chunk(NativeArtifactChunk(path: path, totalBytes: total, offset: offset, data: data))
    }

    /// The whole file, nil when it cannot be served.
    public static func readAll(_ path: String, cwd: String) -> Data? {
        var data = Data()
        var total: Int?
        while total == nil || data.count < total! {
            guard case .chunk(let chunk) = read(path, offset: data.count, cwd: cwd), total == nil || total == chunk.totalBytes else { return nil }
            total = chunk.totalBytes
            data.append(chunk.data)
        }
        return data
    }
}

public enum NativeArtifactAge {
    /// "just now", "6m ago", "3h ago", "2d ago": coarse on purpose, since the line is not a clock.
    public static func text(_ ms: Double, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince1970 - ms / 1000)
        if seconds < 60 { return "just now" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))h ago" }
        return "\(Int(seconds / 86_400))d ago"
    }
}

/// The artifacts in `calls` (chronological): each path a finished, successful `write` made, once, newest write first. A failed, stopped
/// or running write made nothing.
public func nativeArtifacts(_ calls: [NativeActivityCall]) -> [NativeArtifact] {
    var latest: [String: (order: Int, createdAt: Double?)] = [:]
    for (order, call) in calls.enumerated() where call.name == "write" && call.state == .done && !call.stopped {
        guard let path = call.path, !path.isEmpty else { continue }
        latest[path] = (order, call.endedAt ?? call.startedAt)
    }
    return latest.sorted { $0.value.order > $1.value.order }.map { NativeArtifact(path: $0.key, createdAt: $0.value.createdAt) }
}

/// The artifacts in a thread's messages. `call` builds a call from a message (the store passes its cache).
public func nativeArtifacts(_ messages: [NativeThreadMessage],
                            call: (NativeThreadMessage) -> NativeActivityCall = NativeActivityCall.init) -> [NativeArtifact] {
    nativeArtifacts(messages.filter { $0.toolName == "write" }.map(call))
}

// MARK: Reading one

/// The file behind an artifact, fetched from the host that holds it in `NativeArtifactChunk.maxBytes`-bounded 256 KiB pieces (the same
/// way `NativeThreadImages` fetches an image), and kept briefly. The host serves only a path one of this thread's `write` calls made;
/// nothing here names an arbitrary file.
@MainActor
public final class NativeThreadArtifacts {
    public enum Outcome: Equatable, Sendable {
        case file(Data)
        /// The host no longer has it, cannot serve it (gone, a link, too big), or predates artifacts.
        case unavailable
        /// A failure that may pass (the connection): the view offers to try again.
        case failed(String)
        case cancelled
    }

    public typealias Fetch = @MainActor (NativeThreadRequest) async throws -> NativeThreadResult

    public static let connectionMessage = "Couldn't reach the host."
    public static let memoryLimit = 24 * 1024 * 1024

    private var fetch: Fetch?
    private var sessionID: String?
    private var epoch = UUID()
    private var cache: [String: Data] = [:]
    private var order: [String] = []
    private var bytes = 0
    /// Fetches started, for tests.
    public private(set) var started = 0

    public init() {}

    /// The session whose files the next fetches ask for; a new one drops everything held.
    public func configure(sessionID: String?, fetch: Fetch?) {
        if self.sessionID != sessionID {
            epoch = UUID()
            cache.removeAll()
            order.removeAll()
            bytes = 0
        }
        self.sessionID = sessionID
        self.fetch = fetch
    }

    /// A rewrite is a new file: the key carries the latest write's stamp.
    private static func key(_ artifact: NativeArtifact) -> String { "\(artifact.path)@\(artifact.createdAt ?? 0)" }

    public func cached(_ artifact: NativeArtifact) -> Data? { cache[Self.key(artifact)] }

    public func load(_ artifact: NativeArtifact) async -> Outcome {
        if let data = cached(artifact) { return .file(data) }
        guard let fetch, let sessionID else { return .failed("The thread is not ready.") }
        let session = epoch
        started += 1
        var data = Data()
        var total: Int?
        while total == nil || data.count < total! {
            if Task.isCancelled || session != epoch { return .cancelled }
            let result: NativeThreadResult
            do {
                result = try await fetch(.artifact(expectedSessionID: sessionID, path: artifact.path, offset: data.count))
            } catch {
                return .failed(Self.connectionMessage)
            }
            if Task.isCancelled || session != epoch { return .cancelled }
            switch result {
            case .artifactChunk(let chunk):
                // In order, for this path, within the limit, and the same size each time: a size that moves means the file did.
                guard chunk.path == artifact.path, chunk.offset == data.count, chunk.data.count <= NativeImage.chunkBytes,
                      chunk.totalBytes >= 0, chunk.totalBytes <= NativeArtifactChunk.maxBytes, total == nil || total == chunk.totalBytes,
                      chunk.data.count <= chunk.totalBytes - data.count, chunk.totalBytes == 0 || !chunk.data.isEmpty else { return .unavailable }
                total = chunk.totalBytes
                data.append(chunk.data)
            case .failure(let code, _) where code == NativeArtifactCode.unknown || code == NativeArtifactCode.unavailable:
                return .unavailable
            case .failure(let code, _):
                return code == "stale_session" ? .failed("The thread changed. Open it again.") : .failed(Self.connectionMessage)
            default:
                return .unavailable
            }
        }
        guard session == epoch, !Task.isCancelled else { return .cancelled }
        remember(Self.key(artifact), data)
        return .file(data)
    }

    private func remember(_ key: String, _ data: Data) {
        guard cache[key] == nil else { return }
        cache[key] = data
        order.append(key)
        bytes += data.count
        while bytes > Self.memoryLimit, let oldest = order.first {
            order.removeFirst()
            bytes -= cache.removeValue(forKey: oldest)?.count ?? 0
        }
    }
}

// MARK: The open artifact

/// An artifact's bytes, ready to draw. Parsed once, off the main thread, when it is opened: a view only reads it.
public enum NativeArtifactDocument: Equatable, Sendable {
    /// `blocks` is Preview (the thread's own prose renderer), `source` is Source.
    case markdown(blocks: [NativeMarkdownBlock], source: String)
    /// A page with its own styles: drawn in a locked-down web view (`NWArtifactWebView`), never as prose.
    case html(String)
    /// A picture: drawn as an image, so nothing in it runs.
    case svg(String)
    /// Any other file: its text, in mono.
    case text(String)

    /// Source, whatever the kind.
    public var source: String {
        switch self {
        case .markdown(_, let source), .html(let source), .svg(let source), .text(let source): source
        }
    }

    /// The largest Markdown drawn as prose. Prose lays out every block at once (it is the thread's renderer, not a lazy list), so a
    /// longer file (a log the agent wrote as a 9,000-item list) would hang the window; it shows as its source instead.
    public static let markdownPreviewBytes = 128 * 1024

    public init(_ artifact: NativeArtifact, data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        switch artifact.kind {
        case .markdown where data.count > Self.markdownPreviewBytes: self = .text(text)
        case .markdown: self = .markdown(blocks: nativeMarkdownBlocks(text), source: text)
        case .html: self = .html(text)
        case .svg: self = .svg(text)
        case .text: self = .text(text)
        }
    }
}

extension NativeThreadArtifacts {
    public enum Opened: Equatable, Sendable {
        case document(NativeArtifactDocument, data: Data)
        case unavailable
        case failed(String)
        case cancelled
    }

    /// The artifact fetched and parsed for drawing; the parse is off the main actor.
    public func open(_ artifact: NativeArtifact) async -> Opened {
        switch await load(artifact) {
        case .file(let data):
            let document = await Task.detached(priority: .userInitiated) { NativeArtifactDocument(artifact, data: data) }.value
            return .document(document, data: data)
        case .unavailable: return .unavailable
        case .failed(let message): return .failed(message)
        case .cancelled: return .cancelled
        }
    }
}
