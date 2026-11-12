import Foundation

/// Tells the sync when a file it keeps in step changes behind its back: pi rewriting
/// `settings.json`, a hand edit of an instruction file. It watches each file and the folder it is
/// in (an atomic write replaces the file, and the folder is what notices), waits out a burst of
/// events (300 ms), and calls `onChange` on the server queue. It never reads or compares anything:
/// the materializer compares content, so its own writes cost one scan and no op.
final class FleetWatcher {
    static let debounce: TimeInterval = 0.3

    private let queue: DispatchQueue
    private let onChange: () -> Void
    private var paths: [URL] = []
    private var fileOnly: [URL] = []
    private var sources: [DispatchSourceFileSystemObject] = []
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

    func stop() {
        stopped = true
        pendingFire?.cancel()
        sources.forEach { $0.cancel() }
        sources = []
    }

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
            self.onChange()
        }
        pendingFire = work
        queue.asyncAfter(deadline: .now() + Self.debounce, execute: work)
    }
}
