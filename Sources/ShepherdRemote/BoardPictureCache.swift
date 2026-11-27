import CoreGraphics
import CryptoKit
import Foundation

/// What a board's finished picture depends on: the board file's content hash, its tweaked props,
/// its size, the width the picture was drawn at, the screen scale and the renderer that drew it. A
/// board that changes has a new key, so it draws again; one that doesn't never does.
public struct BoardPictureKey: Hashable, Sendable {
    /// The board file's SHA-256, lower-case hex.
    public var content: String
    /// The board's tweaked props as JSON, nil when it has none.
    public var props: String?
    /// A digest of what the board draws from outside its own file (`BoardDependencies`): the
    /// design-system files and imported pieces it reads. Empty when it reads none.
    public var dependencies: String
    /// The board's own size in points.
    public var board: CGSize
    /// How wide the picture is drawn, in points (one of `BoardPictureTier.widths` for the canvas).
    public var width: Int
    /// Pixels per point.
    public var scale: Int
    /// The renderer's version: the app that drew it, so a new runtime draws again.
    public var renderer: String

    public init(content: String, props: String? = nil, dependencies: String = "", board: CGSize, width: Int, scale: Int, renderer: String) {
        self.content = content
        self.props = props
        self.dependencies = dependencies
        self.board = board
        self.width = width
        self.scale = scale
        self.renderer = renderer
    }

    /// The picture's file name: a hash of every field, so no two keys share one.
    public var name: String {
        let text = [renderer, content, dependencies, props ?? "", "\(Int(board.width))x\(Int(board.height))", "\(width)", "\(scale)"]
            .joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// The widths a canvas draws a board's picture at: the smallest that is at least as wide as the
/// board is shown, so a board at 5% of a 1280-point page is 160 points and 320 pixels, not 1280, and
/// a canvas of hundreds of boards keeps hundreds of small pictures. Zooming in past a tier draws the
/// board again at the next.
public enum BoardPictureTier {
    public static let widths: [CGFloat] = [160, 320, 640]

    /// The picture width for a board `shown` points wide.
    public static func width(shown: CGFloat) -> CGFloat {
        widths.first { $0 >= shown } ?? widths[widths.count - 1]
    }

    /// The picture width for a board `boardWidth` points wide at `zoom`.
    public static func width(boardWidth: CGFloat, zoom: CGFloat) -> CGFloat {
        width(shown: boardWidth * zoom)
    }
}

/// Finished board pictures kept on disk (the app's Caches folder), by `BoardPictureKey`, so a design
/// opened again, or after the app relaunches, shows them without drawing a board. Bounded by
/// `byteLimit`: past it the pictures used least recently go first. Thread-safe; its files are
/// the encoded pictures and nothing else is trusted from the folder.
public final class BoardPictureCache: @unchecked Sendable {
    public let directory: URL
    public let byteLimit: Int
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var entries: [String: (bytes: Int, used: Date)]?
    private var total = 0

    public init(directory: URL, byteLimit: Int = 256 * 1024 * 1024, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.byteLimit = byteLimit
        self.now = now
    }

    /// The bytes and the number of pictures kept.
    public var bytes: Int { locked { load(); return total } }
    public var count: Int { locked { load(); return entries?.count ?? 0 } }

    /// Whether a picture is kept for `key`; never reads it.
    public func contains(_ key: BoardPictureKey) -> Bool {
        locked { load(); return entries?[key.name] != nil }
    }

    /// The kept picture's bytes, counted as used now; nil when none is kept.
    public func data(for key: BoardPictureKey) -> Data? {
        let name = key.name
        let url = file(name)
        let found: Data? = locked {
            load()
            guard entries?[name] != nil else { return nil }
            guard let data = try? Data(contentsOf: url) else {
                drop(name)
                return nil
            }
            let date = now()
            entries?[name]?.used = date
            try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            return data
        }
        return found
    }

    /// Keeps `data` for `key`, then gives up the least recently used pictures while the folder is over its limit.
    public func store(_ data: Data, for key: BoardPictureKey) {
        let name = key.name
        locked {
            load()
            let url = file(name)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                try? FileManager.default.setAttributes([.modificationDate: now()], ofItemAtPath: url.path)
            } catch {
                return
            }
            if let old = entries?[name] { total -= old.bytes }
            entries?[name] = (data.count, now())
            total += data.count
            trim(keeping: name)
        }
    }

    /// Forgets one picture (it did not decode).
    public func remove(_ key: BoardPictureKey) {
        locked {
            load()
            drop(key.name)
        }
    }

    /// Forgets every picture.
    public func removeAll() {
        locked {
            try? FileManager.default.removeItem(at: directory)
            entries = [:]
            total = 0
        }
    }

    // MARK: Folder

    private func file(_ name: String) -> URL { directory.appendingPathComponent(name + ".png") }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Reads the folder once: each picture's size and when it was last used.
    private func load() {
        guard entries == nil else { return }
        var found: [String: (bytes: Int, used: Date)] = [:]
        total = 0
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        for url in urls where url.pathExtension == "png" {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard let size = values?.fileSize else { continue }
            found[url.deletingPathExtension().lastPathComponent] = (size, values?.contentModificationDate ?? .distantPast)
            total += size
        }
        entries = found
        trim(keeping: nil)
    }

    private func drop(_ name: String) {
        guard let old = entries?.removeValue(forKey: name) else { return }
        total -= old.bytes
        try? FileManager.default.removeItem(at: file(name))
    }

    /// Past the limit, removes the least recently used until the folder is at 90% of it (so the next
    /// store doesn't trim again), never `kept`.
    private func trim(keeping kept: String?) {
        guard total > byteLimit, let entries else { return }
        let target = byteLimit / 10 * 9
        for (name, _) in entries.sorted(by: { $0.value.used != $1.value.used ? $0.value.used < $1.value.used : $0.key < $1.key })
        where total > target && name != kept {
            drop(name)
        }
    }
}
