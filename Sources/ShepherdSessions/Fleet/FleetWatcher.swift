import CoreServices
import Foundation

/// Tells the sync when a file it keeps in step changes behind its back: pi rewriting
/// `settings.json`, a hand edit of an instruction file. It watches each file and the folder it is
/// in (an atomic write replaces the file, and the folder is what notices), waits out a burst of
/// events (300 ms), and calls `onChange` on the server queue. It never reads or compares anything:
/// the materializer compares content, so its own writes cost one scan and no op. A whole folder
/// (a skill, an extension someone is working on) is watched with one FSEvents stream, so a save at
/// any depth is noticed without a descriptor for every folder under it.
final class FleetWatcher {
    static let debounce: TimeInterval = 0.3

    private let queue: DispatchQueue
    private let onChange: () -> Void
    private var paths: [URL] = []
    private var fileOnly: [URL] = []
    private var sources: [DispatchSourceFileSystemObject] = []
    private var trees: [URL] = []
    private var stream: FSEventStreamRef?
    private var pendingFire: DispatchWorkItem?
    private var stopped = false

    init(queue: DispatchQueue, onChange: @escaping () -> Void) {
        self.queue = queue
        self.onChange = onChange
    }

    /// Watches `file` and its folder, which is created if it isn't there. `folder: false` watches the file
    /// alone (one that exists and is replaced by rename, like a git config: the old file's end is the
    /// event), for a folder too busy to be worth an event per write.
    func watch(file: URL, folder: Bool = true) {
        if folder {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            paths.append(file)
        } else {
            fileOnly.append(file)
        }
        arm()
    }

    /// Watches every folder in `folders` and everything under it, replacing the folders watched before.
    /// A folder that isn't there is made (a skills folder nothing was installed in yet).
    func watch(trees folders: [URL]) {
        let wanted = Array(Set(folders.map { $0.standardizedFileURL.path })).sorted().map { URL(fileURLWithPath: $0, isDirectory: true) }
        guard wanted != trees, !stopped else { return }
        trees = wanted
        stopStream()
        guard !wanted.isEmpty else { return }
        for folder in wanted { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let paths = wanted.map { $0.resolvingSymlinksInPath().path } as CFArray
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FleetWatcher>.fromOpaque(info).takeUnretainedValue().fired()
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, paths, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private func stopStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    func stop() {
        stopped = true
        pendingFire?.cancel()
        sources.forEach { $0.cancel() }
        sources = []
        stopStream()
        trees = []
    }

    deinit { stopStream() }

    /// (Re)opens a source on every watched file and folder: a replaced file is a new inode.
    private func arm() {
        sources.forEach { $0.cancel() }
        sources = []
        guard !stopped else { return }
        var targets: [URL] = []
        for path in paths {
            let folder = path.deletingLastPathComponent()
            for url in [folder, path] where !targets.contains(url) { targets.append(url) }
        }
        for url in fileOnly where !targets.contains(url) { targets.append(url) }
        for url in targets {
            let fd = open(url.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .attrib, .link], queue: queue)
            source.setEventHandler { [weak self] in self?.fired() }
            source.setCancelHandler { close(fd) }
            source.activate()
            sources.append(source)
        }
    }

    private func fired() {
        guard !stopped else { return }
        pendingFire?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped else { return }
            self.arm()
            // A source registers with the kernel after this block ends: scanning from the next block means a
            // write made after the scan is one the new sources see, not one that falls between the two.
            self.queue.async { [weak self] in
                guard let self, !self.stopped else { return }
                self.onChange()
            }
        }
        pendingFire = work
        queue.asyncAfter(deadline: .now() + Self.debounce, execute: work)
    }
}
