import CryptoKit
import Foundation
import ImageIO
import ShepherdProtocol
import UniformTypeIdentifiers

/// The images in a thread (docs/native-thread.md › Images). pi saves every image it was sent or a tool made in
/// its own session (verified: user and tool-result image blocks are written to the session file whole), and
/// `get_messages` names each one by hash (`RPCImageRef`), so the host stores nothing: a snapshot names each image
/// (`NativeThreadBlock.imageID`, bounded metadata, no bytes) and `NativeThreadRequest.image` asks pi for that one
/// image (`get_image`) and checks the bytes before serving a piece. An id is `entry|index|sha256`: the history entry, which image in it, and
/// the image's whole SHA-256 (hex), so an id from another thread, an older history or a made-up one finds nothing, and the bytes served
/// are always the bytes the id names.
enum ThreadImages {
    struct Meta: Equatable {
        var mimeType: String
        var width: Int
        var height: Int
        var byteCount: Int
        var hash: String
    }

    /// The metadata of every image in pi's saved history `messages`, keyed by `key(entryID:index:)`, with entry ids from
    /// `RPCThreadState.shownHistory` (the list the snapshot is built from). **Heavy** (it decodes each image's header and takes its
    /// SHA-256) and so only ever run off the thread's queue, once per history the thread projects; the projection that follows
    /// on the owner's queue only looks entries up (`RPCThreadState.projectHistory(images:)`). Nothing is cached between calls: an
    /// identity that is not the whole content's hash is not an identity, and a table built from these very messages cannot be stale.
    static func table(for messages: [RPCMessage]) -> [String: Meta] {
        var table: [String: Meta] = [:]
        for (entryID, message) in RPCThreadState.shownHistory(messages) {
            var index = 0
            for case .image(let mime, let base64, let ref) in message.content {
                if let meta = ref.map({ named(mimeType: mime, ref: $0) }) ?? inspect(mimeType: mime, base64: base64)?.meta {
                    table[key(entryID: entryID, index: index)] = meta
                }
                index += 1
            }
        }
        return table
    }

    static func hasImages(_ messages: [RPCMessage]) -> Bool {
        messages.contains { $0.content.contains { if case .image = $0 { true } else { false } } }
    }

    static func key(entryID: String, index: Int) -> String { "\(entryID)|\(index)" }

    /// Told, for tests, each time an image's bytes are decoded and hashed (`inspect`), with the size of its base64: the queue it ran on
    /// is what a test checks, and the size lets it ignore work another test is doing at the same time.
    nonisolated(unsafe) static var onHeavyWork: ((_ byteCount: Int) -> Void)?

    static func id(entryID: String, index: Int, meta: Meta) -> String { "\(entryID)|\(index)|\(meta.hash)" }

    /// `(entry, index, hash)` of an id, nil when it is not one.
    static func parse(_ id: String) -> (entryID: String, index: Int, hash: String)? {
        let parts = id.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count >= 3, let hash = parts.last, hash.count == hashLength, let index = Int(parts[parts.count - 2]), index >= 0 else { return nil }
        let entry = parts.dropLast(2).joined(separator: "|")
        return entry.isEmpty ? nil : (entry, index, String(hash))
    }

    /// The image `id` names, from the bytes pi returned for its hash: nil unless they are an image the thread offers whose
    /// whole SHA-256 is the id's. Heavy: never on the server queue.
    static func verified(_ id: String, mimeType: String, base64: String) -> (mimeType: String, data: Data)? {
        guard let want = parse(id), let checked = inspect(mimeType: mimeType, base64: base64), checked.meta.hash == want.hash else { return nil }
        return (mimeType, checked.data)
    }

    /// What pi said of an image it named without its bytes, when the thread would offer it: an offered type, a size within the
    /// bounds and a whole hash. Draws the block; `verified` checks the bytes themselves when they are served.
    static func named(mimeType: String, ref: RPCImageRef) -> Meta? {
        guard NativeImage.threadMimeTypes.contains(mimeType), (1...NativeImage.maxBytes).contains(ref.byteCount),
              NativeImage.fitsPixelBound(width: ref.width, height: ref.height),
              ref.sha256.count == hashLength, ref.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        return Meta(mimeType: mimeType, width: ref.width, height: ref.height, byteCount: ref.byteCount, hash: ref.sha256)
    }

    // MARK: Limits

    /// The whole SHA-256, in hex: the id carries the content's identity, not a prefix of it.
    static let hashLength = 64

    /// A chunk of `data` from `offset`, at most `NativeImage.chunkBytes`; nil when `offset` is past the end.
    static func chunk(_ id: String, mimeType: String, data: Data, offset: Int) -> NativeImageChunk? {
        guard offset >= 0, offset < data.count else { return nil }
        let end = min(data.count, offset + NativeImage.chunkBytes)
        return NativeImageChunk(imageID: id, mimeType: mimeType, totalBytes: data.count, offset: offset,
                                data: data.subdata(in: (data.startIndex + offset)..<(data.startIndex + end)))
    }

    // MARK: Decoding

    /// The image in `base64` as the thread offers it, or nil: an offered type that is what its own bytes are, within the byte bound and the
    /// pixel bound (overflow-safe, from the header, no bitmap). Returns the decoded bytes with their metadata and full SHA-256.
    static func inspect(mimeType: String, base64: String) -> (meta: Meta, data: Data)? {
        onHeavyWork?(base64.utf8.count)
        guard NativeImage.threadMimeTypes.contains(mimeType), base64.utf8.count <= (NativeImage.maxBytes * 4 / 3) + 8,
              let data = Data(base64Encoded: base64), data.count <= NativeImage.maxBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              // The bytes' own type must be the one the block says: a TIFF (or anything ImageIO reads) labelled png is refused.
              let detected = CGImageSourceGetType(source) as String?, UTType(detected)?.preferredMIMEType == mimeType,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              NativeImage.fitsPixelBound(width: width, height: height) else { return nil }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (Meta(mimeType: mimeType, width: width, height: height, byteCount: data.count, hash: hash), data)
    }
}
