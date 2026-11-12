import CryptoKit
import Darwin
import Foundation
import os
import ShepherdCore
import ShepherdRemote

/// Git's view of a checkout: which paths it tracks and which it would show as untracked. A file in neither is
/// ignored. Tests bring their own.
struct FleetGitClassifier {
    struct Lookup {
        var tracked: Set<String>
        var untracked: Set<String>
    }

    /// Of `paths` (relative to `root`), or of every file when nil. Nil: `root` isn't a git checkout, or git failed.
    var lookup: (_ root: String, _ paths: [String]?) -> Lookup?

    static let git = FleetGitClassifier { root, paths in
        if paths?.isEmpty == true { return Lookup(tracked: [], untracked: []) }
        func names(_ arguments: [String]) -> Set<String>? {
            let environment = ProcessInfo.processInfo.environment.merging(["GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0"]) { $1 }
            guard let result = try? BoundedCommand.run(["/usr/bin/git", "--literal-pathspecs", "-C", root] + arguments, environment: environment, timeout: 120),
                  result.status == 0 else { return nil }
            return Set(result.output.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) })
        }
        let scope = paths.map { ["--"] + $0 } ?? []
        guard let tracked = names(["ls-files", "-z"] + scope), let untracked = names(["ls-files", "-z", "-o", "--exclude-standard"] + scope) else { return nil }
        return Lookup(tracked: tracked, untracked: untracked)
    }
}

/// A warm, persisted index of one checkout's files (slice 4b): for each, its content hash, git's blob id for the
/// content, its size, time and git class; and the Merkle hash of every directory. Built once in the background
/// and kept current by FSEvents, so a dispatch can say what the checkout holds without reading it.
///
/// Everything here is confined to `queue`, a serial queue at utility priority: hashing never competes with a thread's
/// own work. A file is read again only when its size or modification time changed (or it was written in the last
/// two seconds, inside the clock's granularity), so a scan of a tree that was indexed before reads nothing.
///
/// What the index trusts events for it checks anyway: the kernel's own "must rescan" flags, ids that wrapped or a
/// journal that no longer reaches back to the saved id, a root that moved, and a spot check of a sample of what it
/// holds against the filesystem (`verify`) all end in a rescan of the root. Nothing in a repository is ever written:
/// the index lives under the fleet's own directory.
final class FleetContentIndex: @unchecked Sendable {
    enum State: String, Equatable, Sendable {
        case loading
        /// The first scan is running.
        case scanning
        case ready
        /// More files than `maxFiles`: not indexed.
        case tooLarge
        case notGit
    }

    /// Files one index takes. A checkout past it is left out and says so, rather than taking a gigabyte of memory.
    static let maxFiles = 500_000
    /// How long after a write a file's modification time can't yet be trusted to change again.
    private static let racyWindow: Int64 = 2_000_000_000
    /// Scans that walk a whole tree at once, across every index in the process.
    private static let scanSlots = DispatchSemaphore(value: 2)
    private static let metaInterval: TimeInterval = 2

    let root: String
    let queue: DispatchQueue
    private let storage: FleetIndexStorage
    private let classifier: FleetGitClassifier
    private let clock: @Sendable () -> Date
    private let maxFiles: Int
    private let latency: TimeInterval
    private let buffer = UnsafeMutableRawPointer.allocate(byteCount: 1 << 20, alignment: 16)

    private(set) var state: State = .loading {
        didSet { stateLock.withLock { latestState = state } }
    }
    private let stateLock = NSLock()
    private var latestState: State = .loading
    /// `state`, readable from any thread without waiting for the index's queue (which a scan holds for as long as it runs).
    var stateNow: State { stateLock.withLock { latestState } }
    private(set) var entries: [String: FleetIndexEntry] = [:]
    private(set) var exclusions: FleetExclusions
    private var tree = FleetMerkleTree()
    private var excluded: [String: FleetExclusions.Reason] = [:]
    /// Each directory's modification time when it was last listed: a directory that changed since had entries come or go.
    private var dirStamps: [String: Int64] = [:]
    private var events: FleetFSEvents?
    private var eventID: UInt64?
    private var volume: String?
    private var dirtyPaths: Set<String> = []
    private var newPaths: Set<String> = []
    private var journalLines = 0
    private var metaSavedAt = Date.distantPast
    private var pendingAdded: [FleetHash] = []
    private var pendingRemoved: [FleetHash] = []
    /// Counts every entry written or dropped, so a repair can tell whether it found anything.
    private var mutations = 0
    /// Stop was asked for: a scan in progress ends at its next directory.
    private let stopFlag = NSLock()
    private var _stopped = false
    private var stopped: Bool {
        get { stopFlag.withLock { _stopped } }
        set { stopFlag.withLock { _stopped = newValue } }
    }
    /// Files read and hashed so far: what a test reads to tell a dispatch that read only what changed from one that read everything.
    private(set) var filesHashed = 0
    /// Full walks made (the first scan included): what a test reads to tell a rescan from an event.
    private(set) var rescans = 0
    /// Batches of events that said some were lost (the kernel's buffer overflowed, the root moved): the reason for a rescan nobody asked for.
    private(set) var lostEvents = 0
    /// The index came from disk at start, not from a scan.
    private(set) var loadedFromDisk = false
    /// How long the first scan took, with git's classes and the save (what a person waits for the first time, in the background).
    private(set) var firstScan: Duration?

    /// Queue: hashes that came into the index and hashes that left it, together (the content hashes of files and the Merkle
    /// hashes of directories). The first call after a scan carries everything.
    var onDelta: (([FleetHash], [FleetHash]) -> Void)?
    /// Queue: `state` changed.
    var onState: (() -> Void)?
    /// Queue: a rescan was needed, and why (a log line, and what tests wait on).
    var onDrift: ((String) -> Void)?

    /// The path with every link resolved, as FSEvents reports it (`/private/var/...`, which `URL.resolvingSymlinksInPath` shortens to `/var/...`).
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return URL(fileURLWithPath: path).standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    init(root: String, storage: URL, exclusions: FleetExclusions = FleetExclusions(), classifier: FleetGitClassifier = .git,
         maxFiles: Int = FleetContentIndex.maxFiles, latency: TimeInterval = 0.05, clock: @escaping @Sendable () -> Date = Date.init) {
        self.root = Self.realPath(root)
        self.storage = FleetIndexStorage(directory: storage)
        self.exclusions = exclusions
        self.classifier = classifier
        self.clock = clock
        self.maxFiles = maxFiles
        self.latency = latency
        queue = DispatchQueue(label: "shepherd.fleet.index.\(storage.lastPathComponent)", qos: .utility)
    }

    deinit { buffer.deallocate() }

    // MARK: Lifecycle (queue)

    /// Loads what was saved (or scans), then follows events from where the saved index left off.
    func start() {
        guard events == nil, !stopped else { return }
        if !load() {
            state = .scanning
            onState?()
            let from = FleetFSEvents.currentEventID()
            volume = FleetFSEvents.volumeID(of: root)
            let began = ContinuousClock.now
            rescan(initial: true)
            firstScan = ContinuousClock.now - began
            if state == .ready { eventID = from }
        }
        guard state == .ready else { return }
        persist(force: true)
        let stream = FleetFSEvents(root: root, queue: queue, latency: latency) { [weak self] in self?.ingest($0, classifyingInBackground: true) }
        events = stream
        if !stream.start(since: eventID) {
            // Without events the index would drift unseen: the periodic check rescans instead.
            onDrift?("events unavailable")
        }
    }

    /// Asks a scan in progress to end. Safe from any thread; `stop()` then runs on the queue.
    func requestStop() { stopped = true }

    /// Stops following and saves where it got to.
    func stop() {
        stopped = true
        if let latest = events?.latestEventID { eventID = max(eventID ?? 0, latest) }
        events?.stop()
        events = nil
        if state == .ready { persist(force: true) }
    }

    /// Removes what the index put on disk.
    func erase() {
        stop()
        storage.remove()
    }

    /// Tests: the stream (to make it drop events).
    var eventStream: FleetFSEvents? { events }

    /// Changes the rules: what is left out changes with them, so the root is walked again.
    func setExclusions(_ new: FleetExclusions) {
        guard new != exclusions else { return }
        exclusions = new
        guard state == .ready else { return }
        rescan()
        persist(force: true)
    }

    /// Everything the index contributes to a manifest.
    var allHashes: [FleetHash] { entries.values.map(\.hash) + tree.directoryHashes.map(\.hash) }

    var rootHash: FleetHash { tree.root }

    func hash(ofDirectory path: String) -> FleetHash? { tree.hash(ofDirectory: path) }

    var bytesOnDisk: Int { storage.bytesOnDisk }

    // MARK: Loading

    private func load() -> Bool {
        guard let saved = storage.load(root: root, rules: exclusions.key) else { return false }
        let now = FleetFSEvents.volumeID(of: root)
        // Ids saved against another volume's journal, or none, can't be replayed: walk the tree.
        guard let id = saved.meta.eventID, saved.meta.volume == now, now != nil, !saved.entries.isEmpty else { return false }
        entries = saved.entries
        for (path, entry) in entries { tree.set(path, kind: entry.kind, hash: entry.hash) }
        journalLines = saved.journalLines
        loadedFromDisk = true
        eventID = id
        volume = now
        finishBatch(classify: false, persistChanges: false)
        state = .ready
        onState?()
        return true
    }

    // MARK: Scanning

    /// Walks the whole root and brings the index in line with it. Reads only what changed.
    func rescan(initial: Bool = false) {
        Self.scanSlots.wait()
        defer { Self.scanSlots.signal() }
        let before = mutations
        rescans += 1
        let complete = scan("", deep: true)
        guard !stopped else { return }
        guard complete else {
            clearAll()
            state = .tooLarge
            onState?()
            return
        }
        guard let lookup = classifier.lookup(root, nil) else {
            clearAll()
            state = .notGit
            onState?()
            return
        }
        apply(lookup)
        finishBatch(classify: false, persistChanges: !initial)
        if initial {
            do { try storage.writeSnapshot(entries); journalLines = 0; dirtyPaths = [] } catch { ShepherdLog.warning("fleet index: could not save \(root): \(error)") }
        }
        if state != .ready {
            state = .ready
            onState?()
        }
        if !initial, mutations != before { onDrift?("rescan found changes") }
    }

    /// Gives every entry its class from git's lists.
    private func apply(_ lookup: FleetGitClassifier.Lookup) {
        for (path, entry) in entries {
            let state: FleetGitClass = lookup.tracked.contains(path) ? .tracked : lookup.untracked.contains(path) ? .untracked : .ignored
            if entry.state != state {
                entries[path]?.state = state
                dirtyPaths.insert(path)
            }
        }
    }

    private func clearAll() {
        for entry in entries.values { pendingRemoved.append(entry.hash) }
        for directory in tree.directoryHashes { pendingRemoved.append(directory.hash) }
        entries = [:]
        tree = FleetMerkleTree()
        excluded = [:]
        dirStamps = [:]
        dirtyPaths = []
        newPaths = []
        flushDelta()
        storage.remove()
        journalLines = 0
    }

    private static func nanoseconds(_ time: timespec) -> Int64 { Int64(time.tv_sec) * 1_000_000_000 + Int64(time.tv_nsec) }

    private func absolute(_ relative: String) -> String { relative.isEmpty ? root : root + "/" + relative }

    private static func split(_ path: String) -> (parent: String, name: String) {
        guard let slash = path.lastIndex(of: "/") else { return ("", path) }
        return (String(path[..<slash]), String(path[path.index(after: slash)...]))
    }

    private func relative(_ path: String) -> String? {
        if path == root { return "" }
        return path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : nil
    }

    /// Lists a directory with the status of each name. Nil when it can't be read.
    private func list(_ path: String) -> (items: [(name: String, status: stat)], modified: Int64)? {
        guard let directory = opendir(path) else { return nil }
        defer { closedir(directory) }
        let descriptor = dirfd(directory)
        var own = stat()
        fstat(descriptor, &own)
        var items: [(String, stat)] = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." || name == ".git" { continue }
            var status = stat()
            if fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 { items.append((name, status)) }
        }
        return (items, Self.nanoseconds(own.st_mtimespec))
    }

    /// Brings the directory `path` in line with the disk: its files, and its directories that are new (all of them when `deep`).
    /// False when the index outgrew `maxFiles`.
    @discardableResult
    private func scan(_ path: String, deep: Bool) -> Bool {
        if stopped { return false }
        let location = absolute(path)
        if !path.isEmpty {
            let (parent, _) = Self.split(path)
            let reason = exclusions.reason(forDirectory: path, probe: .init(
                inside: { access(location + "/" + $0, F_OK) == 0 },
                beside: { access(self.absolute(parent) + "/" + $0, F_OK) == 0 }))
            removeExcludedMarks(under: path)
            if let reason {
                removePath(path)
                excluded[path] = reason
                return true
            }
        }
        guard let listing = list(location) else {
            if !path.isEmpty { removePath(path) }
            return true
        }
        dirStamps[path] = listing.modified
        var seen = Set<String>()
        for (name, status) in listing.items {
            let child = path.isEmpty ? name : path + "/" + name
            seen.insert(name)
            switch status.st_mode & S_IFMT {
            case S_IFDIR:
                if deep || (tree.names(in: child) == nil && excluded[child] == nil) {
                    guard scan(child, deep: deep) else { return false }
                }
            case S_IFREG, S_IFLNK:
                if exclusions.excludes(file: child) { removePath(child); continue }
                upsert(child, status)
                guard entries.count <= maxFiles else { return false }
            default:
                removePath(child)
            }
        }
        for (name, _) in tree.names(in: path) ?? [:] where !seen.contains(name) { removePath(path.isEmpty ? name : path + "/" + name) }
        for key in excluded.keys where Self.split(key).parent == path && !seen.contains(Self.split(key).name) { excluded[key] = nil }
        return true
    }

    private func removeExcludedMarks(under path: String) {
        for key in excluded.keys where key == path || key.hasPrefix(path + "/") { excluded[key] = nil }
    }

    /// Reads `path` (a file or link, with its status from the listing) when it changed, and records it.
    private func upsert(_ path: String, _ status: stat) {
        let modified = Self.nanoseconds(status.st_mtimespec)
        let size = UInt64(status.st_size)
        let isLink = status.st_mode & S_IFMT == S_IFLNK
        let kind: FleetEntryKind = isLink ? .symlink : status.st_mode & 0o111 != 0 ? .executable : .file
        let old = entries[path]
        if let old, old.size == size, old.modified == modified {
            let racy = Int64(clock().timeIntervalSince1970 * 1e9) - modified < Self.racyWindow
            if !racy {
                // A chmod changes the mode and not the modification time.
                if old.kind != kind { var changed = old; changed.kind = kind; record(path, changed, replacing: old) }
                return
            }
        }
        let content: (FleetHash, FleetGitBlobID)?
        if isLink {
            var target = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let count = readlink(absolute(path), &target, Int(PATH_MAX))
            content = count >= 0 ? Self.hashes(of: Data(target.prefix(count).map { UInt8(bitPattern: $0) })) : nil
        } else {
            content = hashFile(absolute(path), size: size)
        }
        guard let (hash, git) = content else { return }
        record(path, FleetIndexEntry(kind: kind, size: size, modified: modified, hash: hash, gitID: git, state: old?.state ?? .untracked), replacing: old)
        if old == nil { newPaths.insert(path) }
    }

    private func record(_ path: String, _ entry: FleetIndexEntry, replacing old: FleetIndexEntry?) {
        guard old != entry else { return }
        entries[path] = entry
        dirtyPaths.insert(path)
        mutations += 1
        if old?.hash != entry.hash {
            if let old { pendingRemoved.append(old.hash) }
            pendingAdded.append(entry.hash)
        }
        if old?.hash != entry.hash || old?.kind != entry.kind { tree.set(path, kind: entry.kind, hash: entry.hash) }
    }

    private func dropEntry(_ path: String) {
        guard let old = entries.removeValue(forKey: path) else { return }
        pendingRemoved.append(old.hash)
        dirtyPaths.insert(path)
        newPaths.remove(path)
        mutations += 1
    }

    /// Removes a file, or a directory and everything under it, from the index.
    private func removePath(_ path: String) {
        let (parent, name) = Self.split(path)
        if let node = tree.names(in: parent)?[name] {
            if node.kind == .directory { removeEntries(under: path) } else { dropEntry(path) }
            tree.remove(path)
        } else {
            dropEntry(path)
        }
        removeExcludedMarks(under: path)
    }

    private func removeEntries(under directory: String) {
        for (name, node) in tree.names(in: directory) ?? [:] {
            let child = directory + "/" + name
            if node.kind == .directory { removeEntries(under: child) } else { dropEntry(child) }
        }
        dirStamps[directory] = nil
    }

    private static func hashes(of content: Data) -> (FleetHash, FleetGitBlobID) { (FleetHash(of: content), FleetGitBlobID.of(content)) }

    /// SHA-256 and git's blob id of a file, read once. Nil when it can't be read or changed size while it was.
    private func hashFile(_ path: String, size: UInt64) -> (FleetHash, FleetGitBlobID)? {
        filesHashed += 1
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var sha = SHA256()
        var git = Insecure.SHA1()
        git.update(data: Array("blob \(size)\0".utf8))
        var total: UInt64 = 0
        while true {
            let count = read(descriptor, buffer, 1 << 20)
            if count < 0 { if errno == EINTR { continue }; return nil }
            if count == 0 { break }
            total += UInt64(count)
            let view = UnsafeRawBufferPointer(start: buffer, count: count)
            sha.update(bufferPointer: view)
            git.update(bufferPointer: view)
        }
        guard total == size else { return nil }
        return (FleetHash(digest: sha.finalize()), FleetGitBlobID(digest: git.finalize()))
    }

    // MARK: Finishing a batch

    /// Settles what a pass changed: directory hashes, git classes of new files, the delta for the manifest, the disk.
    ///
    /// `classifyingInBackground`: the git classes of new files are asked of git beside the index, not in the middle of the batch. A
    /// file's class says whether it is tracked, untracked or ignored; no hash, tree or manifest depends on it, so a dispatch that
    /// follows an edit doesn't wait for two git processes to tell it what a new file is.
    private func finishBatch(classify: Bool = true, persistChanges: Bool = true, classifyingInBackground: Bool = false) {
        for change in tree.commit() {
            if let old = change.old { pendingRemoved.append(old) }
            if let new = change.new { pendingAdded.append(new) }
        }
        if classify, !newPaths.isEmpty {
            if classifyingInBackground {
                unclassified.formUnion(newPaths)
                if !classifying { classifyNext() }
            } else {
                apply(classes: newPaths)
            }
        }
        newPaths = []
        flushDelta()
        if persistChanges { persist() }
    }

    /// Files whose class is being (or is about to be) asked of git, and whether a lookup is out.
    private var unclassified = Set<String>()
    private var classifying = false

    private func apply(classes paths: Set<String>) {
        let paths = Array(paths)
        guard let lookup = paths.count > 400 ? classifier.lookup(root, nil) : classifier.lookup(root, paths) else { return }
        applyClasses(of: paths, lookup)
    }

    private func applyClasses(of paths: [String], _ lookup: FleetGitClassifier.Lookup) {
        for path in paths where entries[path] != nil {
            let state: FleetGitClass = lookup.tracked.contains(path) ? .tracked : lookup.untracked.contains(path) ? .untracked : .ignored
            if entries[path]?.state != state { entries[path]?.state = state; dirtyPaths.insert(path) }
        }
    }

    /// Asks git for the classes of what is waiting, off the queue, and puts the answer in on it; goes on while more has come.
    private func classifyNext() {
        guard !unclassified.isEmpty, !stopped else { classifying = false; return }
        classifying = true
        let paths = Array(unclassified)
        unclassified = []
        let (root, classifier) = (self.root, self.classifier)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let lookup = paths.count > 400 ? classifier.lookup(root, nil) : classifier.lookup(root, paths)
            self?.queue.async {
                guard let self else { return }
                if let lookup, !self.stopped {
                    self.applyClasses(of: paths, lookup)
                    self.persist()
                }
                self.classifyNext()
            }
        }
    }

    private func flushDelta() {
        guard !pendingAdded.isEmpty || !pendingRemoved.isEmpty else { return }
        let (added, removed) = (pendingAdded, pendingRemoved)
        pendingAdded = []
        pendingRemoved = []
        onDelta?(added, removed)
    }

    // MARK: Events (queue)

    /// Turns a batch of events into the smallest amount of reading that brings the index current.
    func ingest(_ batch: [FleetFSEvents.Event], classifyingInBackground: Bool = false) {
        guard state == .ready, !stopped else { return }
        var rescanAll = false
        var deep = Set<String>(), directories = Set<String>(), files = Set<String>()
        var gitChanged = false
        for event in batch {
            if event.idsWrapped || event.dropped || event.rootChanged || event.isMount { rescanAll = true; lostEvents += 1; continue }
            guard let path = relative(event.path) else { continue }
            if event.mustScan { deep.insert(path); continue }
            if path == ".git" || path.hasPrefix(".git/") {
                if path == ".git/index" || path == ".git/info/exclude" { gitChanged = true }
                continue
            }
            let (parent, name) = Self.split(path)
            if path.isEmpty { continue }
            if path.split(separator: "/").contains(".git") { continue }
            if name == ".gitignore" { gitChanged = true }
            if FleetExclusions.markers.contains(name), event.flags & UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed) != 0 {
                deep.insert(parent)
            }
            if event.isDirectory { directories.insert(path) } else { files.insert(path) }
        }
        if rescanAll {
            onDrift?("events lost")
            rescan()
        } else {
            for path in deep { scanAfterEvent(path, deep: true) }
            for path in directories.sorted() { scanAfterEvent(path, deep: false) }
            for path in files.sorted() { refreshFile(path) }
            if gitChanged { reclassify() }
            finishBatch(classifyingInBackground: classifyingInBackground)
        }
        if let latest = batch.map(\.id).max() { eventID = max(eventID ?? 0, latest) }
        persist()
    }

    private func isUnderExcluded(_ path: String) -> Bool {
        var end = path.startIndex
        while let slash = path[end...].firstIndex(of: "/") {
            if excluded[String(path[..<slash])] != nil { return true }
            end = path.index(after: slash)
        }
        return false
    }

    /// The shallowest directory above `path` (or `path` itself, with `includingSelf`) the index doesn't know yet.
    private func shallowestUnknown(above path: String, includingSelf: Bool) -> String? {
        var end = path.startIndex
        var candidates: [String] = []
        while let slash = path[end...].firstIndex(of: "/") {
            candidates.append(String(path[..<slash]))
            end = path.index(after: slash)
        }
        if includingSelf { candidates.append(path) }
        return candidates.first { tree.names(in: $0) == nil && excluded[$0] == nil }
    }

    private func scanAfterEvent(_ path: String, deep: Bool) {
        guard !isUnderExcluded(path), !path.isEmpty else { return scanRoot() }
        var status = stat()
        guard lstat(absolute(path), &status) == 0 else { return removePath(path) }
        guard status.st_mode & S_IFMT == S_IFDIR else { return refreshFile(path) }
        if let unknown = shallowestUnknown(above: path, includingSelf: false) { scan(unknown, deep: false); return }
        scan(path, deep: deep)
    }

    private func scanRoot() { scan("", deep: false) }

    private func refreshFile(_ path: String) {
        guard !isUnderExcluded(path) else { return }
        var status = stat()
        guard lstat(absolute(path), &status) == 0 else { return removePath(path) }
        switch status.st_mode & S_IFMT {
        case S_IFDIR:
            scanAfterEvent(path, deep: false)
        case S_IFREG, S_IFLNK:
            if let unknown = shallowestUnknown(above: path, includingSelf: false) { scan(unknown, deep: false); return }
            if exclusions.excludes(file: path) { removePath(path); return }
            upsert(path, status)
        default:
            removePath(path)
        }
    }

    /// Git's lists changed (a commit, an add, a change to what is ignored): every entry gets its class again.
    func reclassify() {
        guard let lookup = classifier.lookup(root, nil) else { return }
        apply(lookup)
    }

    // MARK: Snapshots (slice 4c)

    /// What a dispatch reads: the entries and the Merkle tree as they are now (value copies, so reading them costs nothing). Queue.
    func snapshotView() -> (entries: [String: FleetIndexEntry], tree: FleetMerkleTree, mutations: Int, treeChecked: Bool)? {
        state == .ready ? (entries, tree, mutations, treeCheckedAt == mutations) : nil
    }

    /// The tree was found to agree with the entries as they were at `mutations` (a dispatch that finds nothing changed since doesn't look again). Queue.
    func treeAgreed(at version: Int) { treeCheckedAt = version }

    private var treeCheckedAt = -1

    /// A directory whose time changed: what is new in it or gone from it. Files it still has are not looked at (their own size and time
    /// were, in `catchUp`), so a directory of thousands of recently written files isn't hashed again because one name came or went.
    private func reconcileNames(in path: String) {
        guard !isUnderExcluded(path) else { return }
        guard path.isEmpty || tree.names(in: path) != nil else { return scanAfterEvent(path, deep: false) }
        guard let listing = list(absolute(path)) else { return removePath(path) }
        dirStamps[path] = listing.modified
        var seen = Set<String>()
        let known = tree.names(in: path) ?? [:]
        for (name, status) in listing.items {
            seen.insert(name)
            let child = path.isEmpty ? name : path + "/" + name
            switch status.st_mode & S_IFMT {
            case S_IFDIR:
                if known[name] == nil, excluded[child] == nil { scan(child, deep: false) }
            case S_IFREG, S_IFLNK:
                if entries[child] == nil { if exclusions.excludes(file: child) { continue }; upsert(child, status) }
            default:
                if known[name] != nil { removePath(child) }
            }
        }
        for name in known.keys where !seen.contains(name) { removePath(path.isEmpty ? name : path + "/" + name) }
    }

    /// What a dispatch relies on: nothing the system hasn't yet told the index about is missing from it. Every file the index holds is
    /// looked at (size and time, across the cores: a few milliseconds for tens of thousands of files) and so is every directory it
    /// scanned (a file made, removed or renamed in one changes its time); what differs is read again here, as an event for it would have
    /// made the index do. Events and `settle()` get nearly all of it first, so this finds nothing in the usual case. Queue. Returns how many
    /// paths it had to read again.
    @discardableResult
    func catchUp() -> Int {
        guard state == .ready, !stopped else { return 0 }
        let files = Array(entries), directories = Array(dirStamps)
        let root = self.root
        let stale = OSAllocatedUnfairLock<(files: [String], directories: [String])>(initialState: ([], []))
        func absolute(_ path: String) -> String { path.isEmpty ? root : root + "/" + path }
        let chunk = max(512, (files.count + directories.count) / 16 + 1)
        let total = files.count + directories.count
        DispatchQueue.concurrentPerform(iterations: (total + chunk - 1) / chunk) { part in
            var changedFiles: [String] = [], changedDirectories: [String] = []
            for position in (part * chunk)..<min(total, (part + 1) * chunk) {
                var status = stat()
                if position < files.count {
                    let (path, entry) = files[position]
                    if lstat(absolute(path), &status) != 0 || UInt64(status.st_size) != entry.size || Self.nanoseconds(status.st_mtimespec) != entry.modified { changedFiles.append(path) }
                } else {
                    let (path, stamp) = directories[position - files.count]
                    if lstat(absolute(path), &status) != 0 || Self.nanoseconds(status.st_mtimespec) != stamp { changedDirectories.append(path) }
                }
            }
            if !changedFiles.isEmpty || !changedDirectories.isEmpty { stale.withLock { $0.files += changedFiles; $0.directories += changedDirectories } }
        }
        let (changedFiles, changedDirectories) = stale.withLock { $0 }
        guard !changedFiles.isEmpty || !changedDirectories.isEmpty else { return 0 }
        // Directories first (what is new or gone in them), shallowest first, then the files that are still there and differ.
        for path in changedDirectories.sorted(by: { ($0.split(separator: "/").count, $0) < ($1.split(separator: "/").count, $1) }) { reconcileNames(in: path) }
        for path in changedFiles.sorted() { refreshFile(path) }
        finishBatch(classifyingInBackground: true)
        return changedFiles.count + changedDirectories.count
    }

    /// Lets the events the system already holds for this root reach the index, so a file written a moment ago is in it. Not from
    /// the index's own queue.
    func settle() {
        let stream = queue.sync { events }
        stream?.flush()
        queue.sync {}
    }

    /// A file or directory this index holds, where it is now.
    struct Located: Equatable, Sendable {
        var path: String
        var size: UInt64
        var modified: Int64
        var kind: FleetEntryKind
    }

    private var reverse: (mutations: Int, files: [FleetHash: String], gitIDs: [FleetGitBlobID: FleetHash], directories: [FleetHash: String])?

    private func reverseMaps() -> (files: [FleetHash: String], gitIDs: [FleetGitBlobID: FleetHash], directories: [FleetHash: String]) {
        if let reverse, reverse.mutations == mutations { return (reverse.files, reverse.gitIDs, reverse.directories) }
        var files: [FleetHash: String] = [:], gitIDs: [FleetGitBlobID: FleetHash] = [:], directories: [FleetHash: String] = [:]
        files.reserveCapacity(entries.count)
        for (path, entry) in entries {
            if files[entry.hash] == nil { files[entry.hash] = path }
            gitIDs[entry.gitID] = entry.hash
        }
        for (path, hash) in tree.directoryHashes where !path.isEmpty && directories[hash] == nil { directories[hash] = path }
        reverse = (mutations, files, gitIDs, directories)
        return (files, gitIDs, directories)
    }

    /// Where this index holds each of `hashes` (a file's content hash) and `directories` (a Merkle hash), and the content hash of each
    /// of `gitIDs` (a blob id). Queue.
    func locate(files wanted: Set<FleetHash>, directories wantedDirectories: Set<FleetHash>, gitIDs wantedIDs: Set<FleetGitBlobID>)
        -> (files: [FleetHash: Located], directories: [FleetHash: Located], hashes: [FleetGitBlobID: FleetHash]) {
        guard state == .ready else { return ([:], [:], [:]) }
        let maps = reverseMaps()
        var files: [FleetHash: Located] = [:], directories: [FleetHash: Located] = [:], hashes: [FleetGitBlobID: FleetHash] = [:]
        for hash in wanted {
            guard let path = maps.files[hash], let entry = entries[path] else { continue }
            files[hash] = Located(path: absolute(path), size: entry.size, modified: entry.modified, kind: entry.kind)
        }
        for hash in wantedDirectories {
            guard let path = maps.directories[hash] else { continue }
            directories[hash] = Located(path: absolute(path), size: 0, modified: dirStamps[path] ?? 0, kind: .file)
        }
        for id in wantedIDs { if let hash = maps.gitIDs[id] { hashes[id] = hash } }
        return (files, directories, hashes)
    }

    // MARK: Checking

    /// Whether a Merkle tree built again from `entries` has the root `tree` has (reads nothing from disk; nothing of the index's state).
    static func treeAgrees(entries: [String: FleetIndexEntry], tree: FleetMerkleTree) -> Bool {
        var rebuilt = FleetMerkleTree()
        for (path, entry) in entries { rebuilt.set(path, kind: entry.kind, hash: entry.hash) }
        rebuilt.commit()
        return rebuilt.root == tree.root
    }

    /// Compares a sample of what the index holds with the disk, and the Merkle tree with one built again from the entries.
    /// Drift found is repaired by a rescan of the root. True when there was any.
    @discardableResult
    func verify(sample: Int = 64, reclassifying: Bool = false, checkingTree: Bool = true) -> Bool {
        guard state == .ready, !stopped else { return false }
        var drift: String?
        if checkingTree {
            if Self.treeAgrees(entries: entries, tree: tree) { treeCheckedAt = mutations } else { drift = "directory hashes disagree with the entries" }
        }
        if drift == nil {
            // Everything when the sample covers it, else that many entries at random.
            let paths = sample >= entries.count ? Array(entries.keys) : (0..<sample).compactMap { _ in entries.randomElement()?.key }
            for path in paths {
                guard let entry = entries[path] else { continue }
                var status = stat()
                if lstat(absolute(path), &status) != 0 || UInt64(status.st_size) != entry.size || Self.nanoseconds(status.st_mtimespec) != entry.modified {
                    drift = "\(path) changed behind the index"
                    break
                }
            }
        }
        if drift == nil {
            let wanted = max(8, sample / 4)
            let directories = wanted >= dirStamps.count ? Array(dirStamps.keys) : (0..<wanted).compactMap { _ in dirStamps.randomElement()?.key }
            for path in directories {
                guard let stamp = dirStamps[path] else { continue }
                var status = stat()
                if lstat(absolute(path), &status) != 0 || Self.nanoseconds(status.st_mtimespec) != stamp {
                    // A directory that changed isn't drift by itself: look at it, and call it drift only if the index was wrong.
                    let before = mutations
                    scan(path, deep: false)
                    finishBatch()
                    if mutations != before { drift = "\(path) held entries the index lacked" }
                    break
                }
            }
        }
        if reclassifying { reclassify() }
        guard let drift else { return false }
        onDrift?(drift)
        rescan()
        persist()
        return true
    }

    // MARK: Saving

    /// Writes what changed since the last write; the meta file (event id) at most every couple of seconds unless `force`.
    private func persist(force: Bool = false) {
        do {
            if !dirtyPaths.isEmpty {
                if journalLines + dirtyPaths.count > max(5_000, entries.count) {
                    try storage.writeSnapshot(entries)
                    journalLines = 0
                } else {
                    try storage.appendJournal(dirtyPaths, entries: entries)
                    journalLines += dirtyPaths.count
                }
                dirtyPaths = []
            }
            let now = clock()
            if force || now.timeIntervalSince(metaSavedAt) > Self.metaInterval {
                var id = eventID
                if let latest = events?.latestEventID { id = max(id ?? 0, latest) }
                try storage.writeMeta(.init(version: FleetIndexStorage.version, root: root, rules: exclusions.key, eventID: id, volume: volume))
                metaSavedAt = now
            }
        } catch {
            ShepherdLog.warning("fleet index: could not save \(root): \(error)")
        }
    }
}
