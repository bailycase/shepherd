import CoreServices
import Darwin
import Foundation

/// One FSEvents stream over a checkout (slice 4b): file level events with their ids, replayed from a saved
/// id after a restart, and every flag that says events were lost or the root moved handed to the index to act
/// on. The index owns what the events mean; this only delivers them.
///
/// `handler` runs on `queue`. FSEvents reports real paths (`/private/var/...` for a `/var/...` folder), so the
/// root given is resolved first and `root` is what events are relative to.
final class FleetFSEvents {
    struct Event: Equatable {
        var path: String
        var flags: FSEventStreamEventFlags
        var id: FSEventStreamEventId

        private func has(_ flag: Int) -> Bool { flags & UInt32(flag) != 0 }
        /// Events under `path` were coalesced or dropped (by the kernel or the user space buffer): look at the whole directory again.
        var mustScan: Bool { has(kFSEventStreamEventFlagMustScanSubDirs) }
        var dropped: Bool { has(kFSEventStreamEventFlagUserDropped) || has(kFSEventStreamEventFlagKernelDropped) }
        /// The root, or a folder above it, was renamed or removed.
        var rootChanged: Bool { has(kFSEventStreamEventFlagRootChanged) }
        /// The ids restarted from zero: nothing saved before is comparable.
        var idsWrapped: Bool { has(kFSEventStreamEventFlagEventIdsWrapped) }
        /// The end of a replay from a saved id.
        var historyDone: Bool { has(kFSEventStreamEventFlagHistoryDone) }
        var isDirectory: Bool { has(kFSEventStreamEventFlagItemIsDir) }
        var isMount: Bool { has(kFSEventStreamEventFlagMount) || has(kFSEventStreamEventFlagUnmount) }
    }

    let root: String
    private let queue: DispatchQueue
    private let latency: TimeInterval
    private let handler: ([Event]) -> Void
    private var stream: FSEventStreamRef?
    /// Tests: events are received and thrown away, the way a dropped one is, so a test can make an index drift.
    var isDropping = false

    init(root: String, queue: DispatchQueue, latency: TimeInterval = 0.05, handler: @escaping ([Event]) -> Void) {
        self.root = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        self.queue = queue
        self.latency = latency
        self.handler = handler
    }

    /// The newest id the system has handed out: the point a scan that starts now is current as of.
    static func currentEventID() -> UInt64 { FSEventsGetCurrentEventId() }

    /// The id of the volume's journal `path` is on. Ids saved against another journal mean nothing.
    static func volumeID(of path: String) -> String? {
        var info = stat()
        guard stat(path, &info) == 0, let uuid = FSEventsCopyUUIDForDevice(info.st_dev) else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    /// Starts delivering events from `since` (everything the journal still holds after it, then live ones) or from now.
    @discardableResult
    func start(since: UInt64?) -> Bool {
        guard stream == nil else { return true }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
            guard let info else { return }
            let owner = Unmanaged<FleetFSEvents>.fromOpaque(info).takeUnretainedValue()
            let names = unsafeBitCast(paths, to: CFArray.self) as? [String] ?? []
            var events: [Event] = []
            events.reserveCapacity(count)
            for index in 0..<min(count, names.count) { events.append(Event(path: names[index], flags: flags[index], id: ids[index])) }
            owner.deliver(events)
        }
        let options = kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes
        guard let stream = FSEventStreamCreate(nil, callback, &context, [root] as CFArray, since ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                               latency, FSEventStreamCreateFlags(options)) else { return false }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return false
        }
        self.stream = stream
        return true
    }

    private func deliver(_ events: [Event]) {
        guard !isDropping, !events.isEmpty else { return }
        handler(events)
    }

    /// The newest id the stream has delivered, or nil when it isn't running.
    var latestEventID: UInt64? { stream.map { FSEventStreamGetLatestEventId($0) } }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
