import Foundation
import ImageIO
import ShepherdProtocol
import UniformTypeIdentifiers

/// The images of one thread, fetched from the host that saved them and kept briefly (docs/native-thread.md › Images).
/// A snapshot names an image (`NativeImageRef`) and this asks for its bytes in `NativeImage.chunkBytes` pieces
/// until it holds `totalBytes`, then reads the finished bytes' own raster header and checks it against the type, byte and pixel
/// limits and against whatever the snapshot said of the image. Nothing is cached or returned before that check, and nothing the
/// host sends (metadata or pieces) is trusted for its size: counts and dimensions are checked for sign and overflow first.
///
/// Bounded: at most `memoryLimit` bytes of finished images stay (the least recently used go first), at most
/// `maxInFlight` fetches run at once, and a second ask for an image already on its way waits for that fetch
/// instead of starting another. Each asker is its own waiter: one that is cancelled returns at once, and the fetch itself
/// is cancelled when its last waiter has gone (or the thread leaves the screen, or the session changes).
@MainActor
public final class NativeThreadImages {
    public enum Outcome: Equatable, Sendable {
        case image(Data)
        /// The host no longer has it, or does not offer it: draw the chip.
        case unavailable
        /// A failure that may pass (the connection): the viewer can offer to try again.
        case failed(String)
        /// The fetch was stopped before it finished: the thread left the screen, its poll restarted, or the session changed. Not a failure of the
        /// image, and never something to show a person as an error: a view that is still here offers to try again.
        case cancelled
    }

    public typealias Fetch = @MainActor (NativeThreadRequest) async throws -> NativeThreadResult

    /// What a lost or refused request says: the host's own words are for its log, not for a person looking at a picture.
    public static let connectionMessage = "Couldn't reach the host."

    public static let memoryLimit = 24 * 1024 * 1024
    public static let maxInFlight = 4

    private var fetch: Fetch?
    private var sessionID: String?
    private var cache: [String: Data] = [:]
    private var order: [String] = []
    private var bytes = 0
    /// One entry per image on its way. `token` says which fetch it is: a fetch that was cancelled, or outlived a session change,
    /// finishes later and must not remove the entry (or the cache) of a newer one for the same id.
    private struct Running {
        let token: UUID
        var task: Task<Void, Never>?
        var waiters: [UUID: CheckedContinuation<Outcome, Never>] = [:]
    }
    private var running: [String: Running] = [:]
    /// Changes with each session, so a fetch from the old one cannot fill the new one's cache.
    private var epoch = UUID()
    private var waiting: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []
    /// Fetches started, for tests.
    public private(set) var started = 0

    public init() {}

    /// The session whose images the next fetches ask for; a new one drops everything held (the ids belong to the old one).
    public func configure(sessionID: String?, fetch: Fetch?) {
        if self.sessionID != sessionID {
            cancelAll()
            epoch = UUID()
            cache.removeAll()
            order.removeAll()
            bytes = 0
        }
        self.sessionID = sessionID
        self.fetch = fetch
    }

    /// What is already here, without asking; refreshes its place in the cache.
    public func cached(_ id: String) -> Data? {
        guard let data = cache[id] else { return nil }
        order.removeAll { $0 == id }
        order.append(id)
        return data
    }

    public var heldBytes: Int { bytes }
    public var inFlight: Int { running.count }

    /// Lets go of every piece held (the thread is far from the screen); fetches under way stop
    /// too. The session stays, so the next viewer fetches again.
    public func releaseHeld() {
        cancelAll()
        cache.removeAll()
        order.removeAll()
        bytes = 0
    }

    /// The bytes of image `ref`: held, or on their way, or fetched now. Cancelling the caller returns it at once; the fetch goes on
    /// for any other caller, and stops when none is left.
    public func image(_ ref: NativeImageRef) async -> Outcome {
        if let data = cached(ref.id) { return .image(data) }
        let waiter = UUID()
        // The token of the fetch this caller joins, known once it has joined (the handler below may run before that).
        let joined = Joined()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
                if Task.isCancelled { continuation.resume(returning: .cancelled); return }
                let token = join(ref, waiter: waiter, continuation: continuation)
                joined.token = token
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.leave(ref.id, waiter: waiter, token: joined.token) }
        }
    }

    /// Where a caller's cancellation finds the fetch it joined.
    private final class Joined: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UUID?
        var token: UUID? {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    /// Adds a waiter to the fetch of `ref.id`, starting it when none is on its way. Returns that fetch's token.
    private func join(_ ref: NativeImageRef, waiter: UUID, continuation: CheckedContinuation<Outcome, Never>) -> UUID {
        if var entry = running[ref.id] {
            entry.waiters[waiter] = continuation
            running[ref.id] = entry
            return entry.token
        }
        let token = UUID()
        let session = epoch
        running[ref.id] = Running(token: token, task: nil, waiters: [waiter: continuation])
        let task = Task { [weak self] in
            let outcome = await self?.load(ref, epoch: session) ?? .failed("The thread closed.")
            self?.finish(ref.id, token: token, outcome: outcome)
        }
        running[ref.id]?.task = task
        return token
    }

    /// The fetch ended: every waiter that is still here gets its outcome. Only the fetch's own entry is removed, never a
    /// newer one for the same id (a fetch cancelled earlier finishes late).
    private func finish(_ id: String, token: UUID, outcome: Outcome) {
        guard let entry = running[id], entry.token == token else { return }
        running[id] = nil
        for continuation in entry.waiters.values { continuation.resume(returning: outcome) }
    }

    /// A waiter was cancelled: it returns now; the fetch is cancelled when it was the last one.
    private func leave(_ id: String, waiter: UUID, token: UUID?) {
        guard let token, var entry = running[id], entry.token == token, let continuation = entry.waiters.removeValue(forKey: waiter) else { return }
        continuation.resume(returning: .cancelled)
        if entry.waiters.isEmpty {
            entry.task?.cancel()
            running[id] = nil
        } else {
            running[id] = entry
        }
    }

    /// Stops the fetches under way (the thread left the screen, or the session changed). Pieces already held stay.
    public func cancelAll() {
        let entries = running
        running.removeAll()
        for entry in entries.values {
            entry.task?.cancel()
            for continuation in entry.waiters.values { continuation.resume(returning: .cancelled) }
        }
    }

    // MARK: Fetching

    /// What the snapshot's numbers for `ref` allow, or nil when they cannot be believed: a count or dimension that is negative,
    /// zero, over its limit, or whose product overflows or passes the pixel bound.
    private static func promise(of ref: NativeImageRef) -> (bytes: Int?, width: Int?, height: Int?)? {
        guard NativeImage.threadMimeTypes.contains(ref.mimeType) else { return nil }
        if let size = ref.byteCount, size <= 0 || size > NativeImage.maxBytes { return nil }
        switch (ref.width, ref.height) {
        case (nil, nil): break
        case (let width?, let height?): guard NativeImage.fitsPixelBound(width: width, height: height) else { return nil }
        default: return nil
        }
        return (ref.byteCount, ref.width, ref.height)
    }

    private func load(_ ref: NativeImageRef, epoch session: UUID) async -> Outcome {
        guard let fetch, let sessionID else { return .failed("The thread is not ready.") }
        guard let promise = Self.promise(of: ref) else { return .unavailable }
        guard await slot() else { return .cancelled }
        defer { release() }
        started += 1
        var data = Data()
        var total: Int?
        var mimeType: String?
        while total == nil || data.count < total! {
            if Task.isCancelled || session != epoch { return .cancelled }
            let result: NativeThreadResult
            do {
                result = try await fetch(.image(expectedSessionID: sessionID, imageID: ref.id, offset: data.count))
            } catch {
                // A thread's request failing is the connection, not something to read aloud: a view says so in its own words.
                return .failed(Self.connectionMessage)
            }
            if Task.isCancelled || session != epoch { return .cancelled }
            switch result {
            case .imageChunk(let chunk):
                // One piece, in order, of this image: the type the snapshot named and every earlier piece agreed on, a total that is
                // positive, within the limit and the same each time (and the byte count the snapshot promised, when it did).
                guard chunk.imageID == ref.id, chunk.offset == data.count, !chunk.data.isEmpty,
                      chunk.data.count <= NativeImage.chunkBytes, chunk.mimeType == ref.mimeType, mimeType == nil || mimeType == chunk.mimeType,
                      chunk.totalBytes > 0, chunk.totalBytes <= NativeImage.maxBytes, total == nil || total == chunk.totalBytes,
                      promise.bytes == nil || promise.bytes == chunk.totalBytes,
                      chunk.data.count <= chunk.totalBytes - data.count else { return .unavailable }
                total = chunk.totalBytes
                mimeType = chunk.mimeType
                data.append(chunk.data)
            case .failure(let code, _) where code == NativeImageCode.unknown || code == NativeImageCode.unsupported:
                return .unavailable
            case .failure(let code, _):
                return code == "stale_session" ? .failed("The thread changed. Reopen the image.") : .failed(Self.connectionMessage)
            default:
                return .unavailable
            }
        }
        // The finished bytes must be the image they were said to be, by their own header, before anyone holds or draws them.
        guard Self.rasterHeaderMatches(data, mimeType: ref.mimeType, width: promise.width, height: promise.height) else { return .unavailable }
        // A newer session has taken over while the last piece was on its way: this image is not its to keep.
        guard session == epoch, !Task.isCancelled else { return .cancelled }
        remember(ref.id, data)
        return .image(data)
    }

    /// The type, size and pixel count in `data`'s own header: the type the snapshot named, a positive size within the pixel bound
    /// (overflow-safe), and the dimensions the snapshot gave when it gave any. No bitmap is made.
    static func rasterHeaderMatches(_ data: Data, mimeType: String, width: Int?, height: Int?) -> Bool {
        guard data.count <= NativeImage.maxBytes, let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let kind = CGImageSourceGetType(source) as String?, UTType(kind)?.preferredMIMEType == mimeType,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let actualWidth = properties[kCGImagePropertyPixelWidth] as? Int, let actualHeight = properties[kCGImagePropertyPixelHeight] as? Int,
              NativeImage.fitsPixelBound(width: actualWidth, height: actualHeight) else { return false }
        if let width, let height, width != actualWidth || height != actualHeight { return false }
        return true
    }

    private func remember(_ id: String, _ data: Data) {
        guard cache[id] == nil else { return }
        cache[id] = data
        order.append(id)
        bytes += data.count
        while bytes > Self.memoryLimit, let oldest = order.first {
            order.removeFirst()
            bytes -= cache.removeValue(forKey: oldest)?.count ?? 0
        }
    }

    /// Takes one of `maxInFlight` places, waiting its turn. A fetch that is cancelled while it waits leaves the line at once and
    /// never takes a place: false. The line holds one entry per waiting fetch, so cancelling them all leaves it empty.
    private func slot() async -> Bool {
        if Task.isCancelled { return false }
        if active < Self.maxInFlight, waiting.isEmpty {
            active += 1
            return true
        }
        let id = UUID()
        let granted: Bool = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                if Task.isCancelled { continuation.resume(returning: false); return }
                waiting.append((id, continuation))
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.abandon(id) }
        }
        return granted
    }

    /// A cancelled fetch leaves the line: its entry is removed and resumed with false.
    private func abandon(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(returning: false)
    }

    private var active = 0

    /// A place is free: the next fetch in line takes it (the place passes to it, so `active` stays), else it is released.
    private func release() {
        if waiting.isEmpty { active -= 1; return }
        waiting.removeFirst().continuation.resume(returning: true)
    }

    /// Fetches waiting for a place, for tests.
    public var queued: Int { waiting.count }
}
