import CoreServices
import Darwin
import Foundation
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestKit
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// The refusal corpus (C-AUTH): for each request family, the reply and the observable state after a request the host must refuse.
/// It characterizes what the host does today, against `Tests/Fixtures/c-auth.json`, and weakens no check to see one. A refusal's side
/// effects are observed as events (a file written under the scratch root, a child process started), not as sizes and PIDs afterwards.
@Suite("Refusal corpus", .mainActorExclusive)
@MainActor
struct RefusalCorpusTests {
    @Test func refusalCorpusMatchesGolden() async {
        // A child process of its own: "no process started" watches this process for forks, which no other test may cause.
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.checkingRefusals() }
        }
        expectScenarioCompleted(result)
    }

    private static func checkingRefusals() async throws {
        try await ValidationGolden.check("c-auth.json", from: #filePath, completion: "refusal corpus matched the golden") { golden in
            let seed = try #require(golden.seed as? [String: String])
            let corpus = try await Corpus(seed: seed)
            defer { corpus.stop() }
            try await corpus.run()
            if let directory = ValidationEvidence.directory {
                let observed = corpus.observations.map { ["step": $0.step, "fields": $0.fields] as [String: Any] }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: ["observations": observed], options: [.sortedKeys, .prettyPrinted])
                    .write(to: directory.appendingPathComponent("observed.json"), options: .atomic)
            }
            for (step, fields) in corpus.observations { try golden.observe(step, fields) }
        }
    }
}

// MARK: - The wire

/// A raw NDJSON client of the remote listener (TCP) or of a Unix socket. Reads wait off the main actor: the host answers some
/// requests from the main actor.
private final class Wire: @unchecked Sendable {
    enum Frame { case line(Data), closed, timeout }

    private let fd: Int32
    private var buffer = Data()
    private var counter = 0
    /// What the host's `helloOk` offered this client, once it has answered.
    var offered: [String] = []

    init(port: UInt16) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        try Self.finish(connected)
    }

    init(unixPath: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = try SessionServer.socketAddress(for: unixPath)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try Self.finish(connected)
    }

    private static func finish(_ connected: Int32) throws {
        guard connected == 0 else { throw WireFailure("connect: errno \(errno)") }
    }

    deinit { close(fd) }

    /// The next request id on this connection, so a replay numbers them the same.
    func nextID() -> Int {
        counter += 1
        return counter
    }

    func send(_ data: Data) throws {
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < data.count {
                let n = write(fd, raw.baseAddress! + offset, data.count - offset)
                if n > 0 { offset += n; continue }
                if errno == EINTR { continue }
                // The host closed the connection: the next read says so.
                if errno == EPIPE || errno == ECONNRESET { return }
                throw WireFailure("write: errno \(errno)")
            }
        }
    }

    func next(timeout: Duration = .seconds(10)) async -> Frame {
        await Task.detached { [self] in read(timeout: timeout) }.value
    }

    private func read(timeout: Duration) -> Frame {
        let deadline = ContinuousClock.now + timeout
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                return .line(Data(line))
            }
            guard ContinuousClock.now < deadline else { return .timeout }
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, 50)
            if ready < 0, errno != EINTR { return .closed }
            guard ready > 0 else { continue }
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n > 0 { buffer.append(contentsOf: chunk[0..<n]) } else if n == 0 || (errno != EINTR && errno != EAGAIN) { return .closed }
        }
    }
}

private struct WireFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - Side effects as events

/// FSEvents on the scratch root, so a write shows even when it leaves a file the size it was. Events come with the flags the kernel
/// reported. `drain` writes a file in a directory beside the root and waits for its event: the kernel orders them, so every earlier
/// event has been delivered by then.
private final class FileEvents: @unchecked Sendable {
    /// FSEvents may or may not merge a write's "modified" into its "renamed" (an atomic save): the kinds kept are created, removed, and
    /// any other change, which is the part that is the same on every run.
    private static let created = UInt32(kFSEventStreamEventFlagItemCreated), removed = UInt32(kFSEventStreamEventFlagItemRemoved)
    private static let changed = UInt32(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemInodeMetaMod
                                        | kFSEventStreamEventFlagItemXattrMod | kFSEventStreamEventFlagItemChangeOwner)
    /// An atomic write (`Data.write(options: .atomic)`) of the preferences file first makes `host-preferences.json.sb-<random>` beside it, whose
    /// name differs on every run; the event on `host-preferences.json` itself is the write, so only that one name, directly under the root, is left out.
    static func isPreferencesTemporary(_ path: String, under root: String) -> Bool {
        path.dropFirst(root.count).range(of: #"^/host-preferences\.json\.sb-[^/]+$"#, options: .regularExpression) != nil
    }

    private let root: String
    private let barrierDirectory: URL
    private let seen = Locked<[String: UInt32]>([:])
    private var stream: FSEventStreamRef?
    private var barriers = 0

    init(root: URL, barrierDirectory: URL) {
        // FSEvents reports real paths (`/private/var/...`), which `resolvingSymlinksInPath` strips back to `/var`.
        func real(_ url: URL) -> String { realpath(url.path, nil).map { String(cString: $0) } ?? url.path }
        self.root = real(root)
        self.barrierDirectory = URL(fileURLWithPath: real(barrierDirectory), isDirectory: true)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            let events = Unmanaged<FileEvents>.fromOpaque(info!).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            for index in 0..<min(count, list.count) { events.seen.withValue { $0[list[index], default: 0] |= flags[index] } }
        }
        let watched = [self.root, self.barrierDirectory.path] as CFArray
        stream = FSEventStreamCreate(nil, callback, &context, watched, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.01,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
                                                              | kFSEventStreamCreateFlagUseCFTypes))
        FSEventStreamSetDispatchQueue(stream!, DispatchQueue(label: "c-auth.file-events"))
        FSEventStreamStart(stream!)
    }

    deinit { stop() }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Every file event under the root since the last drain, as "path flags", in path order.
    func drain() async throws -> [String] {
        barriers += 1
        let barrier = barrierDirectory.appendingPathComponent("barrier-\(barriers)")
        try Data().write(to: barrier)
        try await wait(for: barrier.path, flag: UInt32(kFSEventStreamEventFlagItemCreated))
        try FileManager.default.removeItem(at: barrier)
        try await wait(for: barrier.path, flag: UInt32(kFSEventStreamEventFlagItemRemoved))
        let events = seen.withValue { all in defer { all = [:] }; return all }
        return events.filter { $0.key.hasPrefix(root) && !Self.isPreferencesTemporary($0.key, under: root) }.map { path, flags in
            let kinds = [(Self.created, "created"), (Self.changed, "changed"), (Self.removed, "removed")]
                .filter { flags & $0.0 != 0 }.map(\.1).joined(separator: ",")
            return "\(path.dropFirst(root.count)) \(kinds)"
        }.sorted()
    }

    private func wait(for path: String, flag: UInt32) async throws {
        for _ in 0..<500 {
            if seen.withValue({ ($0[path] ?? 0) & flag != 0 }) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw WireFailure("no file event for the barrier \(path)")
    }
}

/// A kqueue on this process's forks: a child started and gone again in between two looks still leaves its event.
private final class ForkWatch {
    private let queue = kqueue()

    init() throws {
        var change = kevent(ident: UInt(getpid()), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_CLEAR),
                            fflags: UInt32(NOTE_FORK), data: 0, udata: nil)
        guard queue >= 0, kevent(queue, &change, 1, nil, 0, nil) == 0 else { throw WireFailure("kqueue: errno \(errno)") }
    }

    deinit { close(queue) }

    /// Whether this process started a child since the last call. A `kevent` failure throws: it is not "no child".
    func started() throws -> Bool {
        var event = kevent()
        var immediately = timespec()
        while true {
            let count = kevent(queue, nil, 0, &event, 1, &immediately)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw WireFailure("fork watch: kevent errno \(errno)") }
            // An error on the registered watch comes back as an event with EV_ERROR and the errno in `data`.
            if count > 0, event.flags & UInt16(EV_ERROR) != 0 { throw WireFailure("fork watch: event error \(event.data)") }
            return count > 0
        }
    }
}

// MARK: - The corpus

@MainActor
private final class Corpus {
    let app: AppHarness
    let port: UInt16
    let space: Space
    /// The reserved space a Project's coordinator lives in, and one id no host has.
    let reservedSpace: Space
    let unknownSpace = SpaceID()
    let thread: AgentFixture
    let coordinator: AgentFixture
    let automation: Automation
    let unknown = AgentID()
    var observations: [(step: String, fields: [String: Any])] = []
    private var observer: Wire!
    private let fileEvents: FileEvents
    private let forks: ForkWatch
    private var labels: [String: String] = [:]
    private var numbered = 0

    /// A client that lists nothing in `hello`, as an older one does.
    private static let bare: [String] = []
    /// What a current iPhone lists, less what the step is about.
    private static let current = RemoteProtocol.clientCapabilities

    init(seed: [String: String]) async throws {
        app = try AppHarness()
        space = Fixture.space(seed["space"]!, path: app.dir.path)
        thread = Fixture.agent(seed["thread"]!, in: space)
        // A Project's coordinator lives in the Space the host keeps for Projects, out of every client's list.
        let reserved = Space(name: seed["projectsSpace"]!, path: app.dir.path, hidden: true, holdsProjects: true)
        reservedSpace = reserved
        var owner = Fixture.agent(seed["coordinator"]!, in: reserved)
        owner.agent.coordinatorFor = ProjectID()
        coordinator = owner
        // Off, so that nothing starts it: a request names it, and the guard under test is the one in front of the run log.
        automation = Automation(name: seed["automation"]!, prompt: "Watch the build.", cwd: app.dir.path, enabled: false)
        // The host's fleet starts with the app's host services: named, and with no Bonjour or iCloud.
        app.server.configureFleet(name: seed["fleetName"]!, advertises: false)
        var seeded = Fixture.state(spaces: [space, reserved], agents: [thread, owner])
        seeded.automations = [automation]
        try await app.start(with: seeded)
        fileEvents = FileEvents(root: app.dir, barrierDirectory: try makeScratchDirectory("barrier"))
        forks = try ForkWatch()
        port = try app.server.startRemoteListener(port: 0, tokenURL: app.dir.appendingPathComponent("remote-token"))
        app.scratch.useRealPeerCheck()
        for (id, label) in [(thread.agent.id.rawValue, "<thread>"), (coordinator.agent.id.rawValue, "<coordinator>"),
                            (unknown.rawValue, "<unknown agent>"), (space.id.rawValue, "<space>"),
                            (automation.id.rawValue, "<automation>")] {
            labels[id.lowercased()] = label
        }
        observer = try await connect(capabilities: Self.bare, name: "observer")
        try await provingTheWatches()
    }

    func stop() {
        observer = nil
        fileEvents.stop()
        app.stop()
    }

    /// A watch that saw nothing would pass every refusal: show that each sees a write and a child process before they are relied on.
    private func provingTheWatches() async throws {
        _ = try await fileEvents.drain()
        let probe = app.dir.appendingPathComponent("watch-probe")
        try Data("x".utf8).write(to: probe)
        try Data("y".utf8).write(to: probe)
        try FileManager.default.removeItem(at: probe)
        guard try await fileEvents.drain().contains(where: { $0.hasPrefix("/watch-probe ") }) else { throw WireFailure("the file watch saw no write") }
        _ = try forks.started()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run()
        child.waitUntilExit()
        guard try forks.started() else { throw WireFailure("the fork watch saw no child process") }
    }

    // MARK: Normalizing

    /// Generated IDs and temp roots become labels, numbered by first appearance, so a capture replays.
    private func normalize(_ text: String) -> String {
        var text = text
        for root in [app.dir.path, app.dir.resolvingSymlinksInPath().path, "/private" + app.dir.path] {
            text = text.replacingOccurrences(of: root, with: "<scratch>")
        }
        let pattern = try! NSRegularExpression(pattern: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")
        var result = "", last = text.startIndex
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            let key = text[range].lowercased()
            if labels[key] == nil {
                numbered += 1
                labels[key] = "<id \(numbered)>"
            }
            result += text[last..<range.lowerBound] + labels[key]!
            last = range.upperBound
        }
        return result + text[last...]
    }

    /// `value` as one entry per path (`a.b[0].c`), normalized; a list of plain values is one entry. JSON structure and types are kept: an
    /// empty object is an entry (`{}`), and null is null, not the text "null".
    private func flatten(_ value: Any, _ path: String, into fields: inout [String: Any]) {
        switch value {
        case let object as [String: Any]:
            if object.isEmpty, !path.isEmpty { fields[path] = object }
            // Sorted, so IDs are numbered in the same order every run.
            for key in object.keys.sorted() { flatten(object[key]!, path.isEmpty ? key : "\(path).\(key)", into: &fields) }
        case let array as [Any]:
            if array.allSatisfy({ !($0 is [String: Any] || $0 is [Any]) }) {
                fields[path] = array.map { ($0 as? String).map(normalize) ?? $0 }
            } else {
                for (index, member) in array.enumerated() { flatten(member, "\(path)[\(index)]", into: &fields) }
            }
        case let text as String: fields[path] = normalize(text)
        case is NSNull: fields[path] = NSNull()
        default: fields[path] = value
        }
    }

    /// `object` flattened under `prefix`, without the top-level members in `leaving` (a secret).
    private func fields(of object: [String: Any]?, prefix: String, leaving: Set<String> = []) -> [String: Any] {
        guard let object else { return [prefix: "<none>"] }
        // A frame that is not JSON has no fields (`exchange` gives it `[:]`), which is not an empty object sent.
        if object.isEmpty { return [:] }
        var result: [String: Any] = [:]
        flatten(object.filter { !leaving.contains($0.key) }, prefix, into: &result)
        return result
    }

    // MARK: Connections

    private func connect(capabilities: [String]?, name: String = "acme-phone") async throws -> Wire {
        let wire = try Wire(port: port)
        let (_, reply) = try await exchange(wire, .hello(id: wire.nextID(), token: app.server.clientTokenForTests(), clientName: name,
                                                         protocolVersion: RemoteProtocol.version, capabilities: capabilities))
        guard case .object(let object) = reply, object["type"] as? String == "helloOk" else { throw WireFailure("no helloOk: \(reply)") }
        wire.offered = object["capabilities"] as? [String] ?? []
        return wire
    }

    enum Reply { case object([String: Any]), closed, timeout }

    private func json(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Sends one frame and waits for the reply that carries its id (a push has none).
    private func exchange(_ wire: Wire, _ request: RemoteRequest) async throws -> (sent: [String: Any], reply: Reply) {
        try await exchange(wire, raw: NDJSON.encode(request))
    }

    private func exchange(_ wire: Wire, raw: Data) async throws -> (sent: [String: Any], reply: Reply) {
        try wire.send(raw)
        // A frame that is not JSON (an undecodable request) has no fields to record.
        let sent = (try? JSONSerialization.jsonObject(with: raw) as? [String: Any]) ?? [:]
        return (sent, try await awaitReply(wire))
    }

    private func awaitReply(_ wire: Wire) async throws -> Reply {
        while true {
            switch await wire.next() {
            case .line(let data):
                let object = try json(data)
                if object["id"] != nil { return .object(object) }
            case .closed: return .closed
            case .timeout: return .timeout
            }
        }
    }

    // MARK: Observing

    /// What a client's `stateFetch` and the stored file said at one moment, flattened and normalized, and the file events since the last one.
    private struct Snapshot {
        var state: [String: Any]
        var stored: [String: Any]
        var fileEvents: [String]
        var launchedChild: Bool
    }

    /// Fails unless the host answers with a state that decodes as one and `state.json` reads back as JSON: an unreadable snapshot never
    /// compares equal to another.
    private func snapshot() async throws -> Snapshot {
        let events = try await fileEvents.drain()
        let (_, reply) = try await exchange(observer, .stateFetch(id: observer.nextID()))
        guard case .object(let object) = reply, object["type"] as? String == "state", let state = object["state"] as? [String: Any],
              (try? NDJSON.decode(ShepherdState.self, from: JSONSerialization.data(withJSONObject: state))) != nil else {
            throw WireFailure("the observer's stateFetch was not answered with a decodable state: \(reply)")
        }
        let stored = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: app.scratch.stateURL)) as? [String: Any])
        var flatState: [String: Any] = [:], flatStored: [String: Any] = [:]
        flatten(state, "", into: &flatState)
        flatten(stored, "", into: &flatStored)
        return Snapshot(state: flatState, stored: flatStored, fileEvents: events, launchedChild: try forks.started())
    }

    private func text(_ value: Any?) -> String {
        guard let value, let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]) else {
            return "<none>"
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// The paths whose values differ, as "path: before > after".
    private func changes(from before: [String: Any], to after: [String: Any]) -> [String] {
        Set(before.keys).union(after.keys).sorted().compactMap { key in
            text(before[key]) == text(after[key]) ? nil : "\(key): \(text(before[key])) > \(text(after[key]))"
        }
    }

    /// What a request left behind: the fields of the state a second client reads and of `state.json` that changed, the file events under
    /// the scratch root (a write that leaves a file the same size is one) and whether this process started a child.
    private func aftermath(_ before: Snapshot) async throws -> [String: Any] {
        let after = try await snapshot()
        return [
            "stateFetch.changed": changes(from: before.state, to: after.state),
            "state.json.changed": changes(from: before.stored, to: after.stored),
            "files.events": after.fileEvents.map(normalize),
            "process.started": after.launchedChild,
        ]
    }

    /// `state.json`'s own field for an agent, read from the file.
    private func persisted(_ id: AgentID, _ field: String) throws -> Any {
        let stored = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: app.scratch.stateURL)) as? [String: Any])
        let agent = try #require((stored["agents"] as? [[String: Any]])?.first { ($0["id"] as? String) == id.rawValue })
        return try #require(agent[field])
    }

    private func record(_ step: String, _ fields: [String: Any]) {
        observations.append((step, fields))
    }

    /// Sends a request on `wire` and records the reply, whether `wire` still answers (`probing`), and what the request left behind.
    private func refuse(_ step: String, on wire: Wire, probing: Bool = true, extra: () throws -> [String: Any] = { [:] },
                        _ make: (Int) -> RemoteRequest) async throws {
        try await refuse(step, on: wire, raw: NDJSON.encode(make(wire.nextID())), probing: probing, extra: extra)
    }

    private func refuse(_ step: String, on wire: Wire, raw: Data, probing: Bool = true, extra: () throws -> [String: Any] = { [:] }) async throws {
        let before = try await snapshot()
        let (sent, reply) = try await exchange(wire, raw: raw)
        var result = fields(of: sent, prefix: "request", leaving: ["token", "sendToken"])
        result.merge(replyFields(reply)) { $1 }
        if probing { result["connection.after"] = try await probe(wire) }
        result.merge(try await aftermath(before)) { $1 }
        result.merge(try extra()) { $1 }
        record(step, result)
    }

    /// The whole reply, normalized.
    private func replyFields(_ reply: Reply) -> [String: Any] {
        switch reply {
        case .object(let object): return fields(of: object, prefix: "reply")
        case .closed: return ["reply": "<closed>"]
        case .timeout: return ["reply": "<no reply>"]
        }
    }

    /// Whether `wire` still answers a `stateFetch`, and as what.
    private func probe(_ wire: Wire) async throws -> String {
        let (_, reply) = try await exchange(wire, .stateFetch(id: wire.nextID()))
        switch reply {
        case .object(let object): return [object["type"] as? String, object["code"] as? String].compactMap { $0 }.joined(separator: "/")
        case .closed: return "closed"
        case .timeout: return "no reply"
        }
    }

    // MARK: The corpus

    func run() async throws {
        try await recordSeed()
        try await beforeHello()
        try await helloRefusals()
        try await capabilities()
        try await hostSettings()
        try await fleetRequestLimits()
        try await localOnly()
        try await otherAgents()
        try await fleetPeerAnswers()
        try await extensionSocket()
        // Last, so the ids it names are numbered after every earlier step's.
        try await spaceLifecycle()
    }

    private func recordSeed() async throws {
        let (_, reply) = try await exchange(observer, .stateFetch(id: observer.nextID()))
        guard case .object(let object) = reply else { throw WireFailure("no state") }
        var seeded = fields(of: object, prefix: "reply")
        record("seeded", seeded)
        let stored = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: app.scratch.stateURL)) as? [String: Any])
        record("stored", fields(of: stored, prefix: "state.json"))
    }

    private func unauthenticated() throws -> Wire { try Wire(port: port) }

    private func beforeHello() async throws {
        try await refuse("before-hello/stateFetch", on: unauthenticated()) { .stateFetch(id: $0) }
        try await refuse("before-hello/agentAction", on: unauthenticated()) {
            .agentAction(id: $0, agentID: thread.agent.id, action: .rename(name: "renamed before hello"))
        }
        try await refuse("before-hello/hostSettings", on: unauthenticated()) { .hostSettings(id: $0, request: .change(.closeOnMerge(true))) }
        try await refuse("before-hello/pushRegistration", on: unauthenticated()) {
            .pushRegistration(id: $0, registration: RemotePushRegistration(id: "acme-phone", sendToken: "acme-send-token"))
        }
        try await refuse("before-hello/nativeThreadSubscribe", on: unauthenticated()) {
            .nativeThreadSubscribe(id: $0, agentIDs: [thread.agent.id])
        }
        try await refuse("before-hello/startThread", on: unauthenticated()) {
            .startThread(id: $0, thread: RemoteThreadStart(spaceID: space.id, cwd: space.path, initialPrompt: "hello"))
        }
        try await refuse("before-hello/fleetPeerAnswer", on: unauthenticated()) { .fleetPeerAnswer(id: $0, reply: .ok(id: $0)) }
        try await refuse("before-hello/undecodable", on: unauthenticated(), raw: Data("not a request\n".utf8))
        let local = try Wire(unixPath: app.hostSocket)
        try await refuse("before-hello/local-stateFetch", on: local) { .stateFetch(id: $0) }
    }

    private func helloRefusals() async throws {
        let token = app.server.clientTokenForTests()
        func hello(_ id: Int, token: String, version: Int) -> RemoteRequest {
            .hello(id: id, token: token, clientName: "acme-phone", protocolVersion: version, capabilities: Self.current)
        }
        try await refuse("hello/wrong-version", on: unauthenticated()) { hello($0, token: token, version: RemoteProtocol.version + 98) }
        try await refuse("hello/wrong-version-and-token", on: unauthenticated()) { hello($0, token: "wrong", version: RemoteProtocol.version + 98) }
        try await refuse("hello/wrong-version-local", on: Wire(unixPath: app.hostSocket)) { hello($0, token: "", version: RemoteProtocol.version + 98) }
        try await refuse("hello/wrong-token", on: unauthenticated()) { hello($0, token: "wrong", version: RemoteProtocol.version) }
        try await refuse("hello/again", on: connect(capabilities: Self.current)) { hello($0, token: token, version: RemoteProtocol.version) }
    }

    /// The host checks that it offers a capability and that this client listed it: a client that listed nothing, or everything else, is refused.
    private func capabilities() async throws {
        let lacking = { (capability: String) in Self.current.filter { $0 != capability } }
        let registration = RemotePushRegistration(id: "acme-phone", sendToken: "acme-send-token")
        let push = RemoteProtocol.pushNotificationsCapability
        let revisions = RemoteProtocol.nativeThreadRevisionsCapability
        let digest = RemoteProtocol.nativeFleetDigestCapability
        let id = thread.agent.id
        try await refuse("capability/push-register-none", on: connect(capabilities: Self.bare)) { .pushRegistration(id: $0, registration: registration) }
        try await refuse("capability/push-register-others", on: connect(capabilities: lacking(push))) { .pushRegistration(id: $0, registration: registration) }
        try await refuse("capability/push-unregister-none", on: connect(capabilities: Self.bare)) { .pushUnregister(id: $0, registrationID: "acme-phone") }
        try await refuse("capability/subscribe-none", on: connect(capabilities: Self.bare)) { .nativeThreadSubscribe(id: $0, agentIDs: [id]) }
        try await refuse("capability/subscribe-others", on: connect(capabilities: lacking(revisions))) { .nativeThreadSubscribe(id: $0, agentIDs: [id]) }
        try await refuse("capability/fleetDigest-none", on: connect(capabilities: Self.bare)) { .fleetDigest(id: $0, agentID: id, session: nil, revision: nil) }
        try await refuse("capability/fleetDigest-others", on: connect(capabilities: lacking(digest))) { .fleetDigest(id: $0, agentID: id, session: nil, revision: nil) }
    }

    /// The host checks its own offer, so an older client that lists nothing can still change an offered setting.
    /// An accepted change rewrites `host-preferences.json`, unlike a refusal.
    private func hostSettings() async throws {
        let client = try await connect(capabilities: Self.bare)
        let stored = { [app] in ["stored.closeOnMerge": try #require(app.hostSettings).worktreeCloseOnMerge] as [String: Any] }
        try await refuse("hostSettings/fetch", on: client, extra: stored) { .hostSettings(id: $0, request: .fetch) }
        // The host offers `hostSettings.closeOnMerge.v1` even though the client didn't list it.
        try await refuse("hostSettings/change-not-negotiated", on: client, extra: stored) { .hostSettings(id: $0, request: .change(.closeOnMerge(true))) }
        try await refuse("hostSettings/change-back", on: client, extra: stored) { .hostSettings(id: $0, request: .change(.closeOnMerge(false))) }
        // A share Settings does not offer is left as it is, and answered like any change.
        try await refuse("hostSettings/change-unoffered-share", on: client, extra: stored) { .hostSettings(id: $0, request: .change(.compactAtPercent(37))) }
        try await refuse("hostSettings/change-refused", on: client, extra: stored) { .hostSettings(id: $0, request: .change(.slashCommand(name: "", on: true))) }
        #expect(client.offered.contains(RemoteProtocol.hostSettingsCapability))
        #expect(!client.offered.contains(RemoteProtocol.fleetDispatchCapability))
        try await refuse("hostSettings/change-capability-not-offered", on: client) { .hostSettings(id: $0, request: .change(.fleetThreadCap(4))) }
    }

    /// `fleetIdentify`, `fleetPair` and `fleetPairDevice` are answered before `hello`, twelve to a connection.
    private func fleetRequestLimits() async throws {
        let makers: [(String, (Int) -> RemoteRequest)] = [
            ("fleetIdentify", { .fleetIdentify(id: $0) }),
            ("fleetPair", { .fleetPair(id: $0, code: "000000", from: FleetIntroduction(hostID: UUID(), name: "acme-peer", myTokenHash: "acme-hash", port: 1)) }),
            ("fleetPairDevice", { .fleetPairDevice(id: $0, code: "000000", device: FleetDeviceIntroduction(
                deviceID: UUID(), name: "acme-phone", kind: .iphone, tokenHash: "acme-hash")) }),
        ]
        for (name, make) in makers { try await limited("fleet-limit/\(name)") { _, id in make(id) } }
        // The count is the connection's, whatever mix it sends.
        try await limited("fleet-limit/mixed") { index, id in makers[index % makers.count].1(id) }
    }

    /// The limit's worth of requests are answered; the next is `busy`, and the connection closes. Each is recorded with its whole reply and
    /// what it left behind. Only the refused one probes the connection: a probe is itself a request before `hello`.
    private func limited(_ step: String, _ make: (Int, Int) -> RemoteRequest) async throws {
        let limit = FleetService.unauthenticatedRequestLimit
        let wire = try unauthenticated()
        for index in 0...limit {
            try await refuse("\(step)#\(index + 1)", on: wire, probing: index == limit) { make(index, $0) }
        }
        // The count is per connection: a new one is answered again.
        let fresh = try unauthenticated()
        try await refuse("\(step)/new-connection", on: fresh, probing: false) { make(0, $0) }
    }

    /// Requests only this Mac's own app may send, from a client over the network.
    private func localOnly() async throws {
        let client = try await connect(capabilities: Self.current)
        let root = app.dir.path
        try await refuse("local-only/drain", on: client) { .drain(id: $0) }
        try await refuse("local-only/hostUpdateGate", on: client) { .hostUpdateGate(id: $0, step: .reserve) }
        try await refuse("local-only/focusThread", on: client) { .focusThread(id: $0, agentID: thread.agent.id) }
        try await refuse("local-only/projectExecutors", on: client) { .projectExecutors(id: $0, update: .hosts([])) }
        try await refuse("local-only/startThread", on: client) {
            .startThread(id: $0, thread: RemoteThreadStart(spaceID: space.id, cwd: space.path, initialPrompt: "hello"))
        }
        try await refuse("local-only/spaceAction", on: client) { .spaceAction(id: $0, spaceID: space.id, action: .delete) }
        try await refuse("local-only/projectRequest", on: client) { .projectRequest(id: $0, request: .register(path: root + "/acme-lib", name: "acme-lib")) }
        try await refuse("local-only/changesWriteEnded", on: client) { .agentQuery(id: $0, agentID: thread.agent.id, query: .changesWriteEnded(span: UUID())) }
        try await refuse("local-only/changesWriteBegan", on: client) {
            .agentQuery(id: $0, agentID: thread.agent.id, query: .changesWriteBegan(span: UUID(), paths: [root + "/notes.txt"]))
        }
        try await refuse("local-only/automation-setRunPullRequest", on: client) {
            .automation(id: $0, automationID: automation.id,
                        request: .setRunPullRequest(agentID: thread.agent.id, url: "https://github.com/acme/web/pull/1"))
        }
        try await designRequests(from: client, root: root)
    }

    /// A device may rename, hide, reorder and remove the spaces its host shows it. A space it is not shown is refused as unknown, and
    /// the refusal changes nothing: the host's state and `state.json` are as they were, and no file is written.
    private func spaceLifecycle() async throws {
        let client = try await connect(capabilities: Self.current)
        try await refuse("space-lifecycle/unknown-space", on: client) { .spaceLifecycle(id: $0, spaceID: unknownSpace, action: .remove) }
        try await refuse("space-lifecycle/reserved-space", on: client) { .spaceLifecycle(id: $0, spaceID: reservedSpace.id, action: .remove) }
        try await refuse("space-lifecycle/reserved-space-rename", on: client) {
            .spaceLifecycle(id: $0, spaceID: reservedSpace.id, action: .rename(name: "taken over"))
        }
        try await refuse("space-lifecycle/move-before-reserved", on: client) {
            .spaceLifecycle(id: $0, spaceID: space.id, action: .move(before: reservedSpace.id))
        }
        try await refuse("space-lifecycle/move-before-unknown", on: client) {
            .spaceLifecycle(id: $0, spaceID: space.id, action: .move(before: unknownSpace))
        }
    }

    /// The Design tool is off until a client turns it on in the host's settings, as an iPhone does; then its import and catalog requests reach
    /// the local-only guards. The setting goes back as it was.
    private func designRequests(from client: Wire, root: String) async throws {
        try await refuse("local-only/design-enable", on: client) { .hostSettings(id: $0, request: .change(.designToolEnabled(true))) }
        var designs: Wire?
        for _ in 0..<100 where designs == nil {
            let candidate = try await connect(capabilities: Self.current)
            if candidate.offered.contains(RemoteProtocol.designsCapability) { designs = candidate } else { try await Task.sleep(for: .milliseconds(50)) }
        }
        let wire = try #require(designs, "the host to serve designs")
        try await refuse("local-only/design-mentionCatalog", on: wire) { .design(id: $0, request: .mentionCatalog) }
        try await refuse("local-only/design-importPrepare", on: wire) { .design(id: $0, request: .importPrepare(path: root + "/acme-import.zip")) }
        let preview = DesignImportPreview(file: "acme-import.zip", title: "acme import", boards: 1, pages: 1,
                                          origin: DesignImportOrigin(file: "acme-import.zip", title: "acme import", stamp: nil, importedAt: 1))
        try await refuse("local-only/design-importConfirm", on: wire) {
            .design(id: $0, request: .importConfirm(preview: preview, name: "acme import", skippingUnreadable: false))
        }
        try await refuse("local-only/design-importDiscard", on: wire) { .design(id: $0, request: .importDiscard(previewID: preview.id)) }
        try await refuse("local-only/design-disable", on: client) { .hostSettings(id: $0, request: .change(.designToolEnabled(false))) }
    }

    /// An id the host has no agent for, and the Project coordinator it keeps out of a client's state.
    private func otherAgents() async throws {
        let full = try await connect(capabilities: Self.current)
        let withoutProjects = try await connect(capabilities: Self.current.filter { $0 != RemoteProtocol.logicalProjectRuntimeCapability })
        let ghost = unknown, hidden = coordinator.agent.id
        try await refuse("agent/action-unknown", on: full) { .agentAction(id: $0, agentID: ghost, action: .rename(name: "ghost")) }
        try await refuse("agent/changes-unknown", on: full) { .agentQuery(id: $0, agentID: ghost, query: .changesOverview()) }
        try await refuse("agent/nativeThread-unknown", on: full) { .nativeThread(id: $0, agentID: ghost, request: .snapshot()) }
        try await refuse("agent/subscribe-unknown", on: full) { .nativeThreadSubscribe(id: $0, agentIDs: [ghost]) }
        try await refuse("agent/subscribe-coordinator", on: full) { .nativeThreadSubscribe(id: $0, agentIDs: [hidden]) }
        try await refuse("agent/subscribe-over-cap", on: full) { .nativeThreadSubscribe(id: $0, agentIDs: (0..<65).map { _ in thread.agent.id }) }
        try await refuse("agent/fleetDigest-unknown", on: full) { .fleetDigest(id: $0, agentID: ghost, session: nil, revision: nil) }
        try await refuse("agent/fleetDigest-coordinator", on: full) { .fleetDigest(id: $0, agentID: hidden, session: nil, revision: nil) }
        try await refuse("agent/nativeThread-coordinator", on: withoutProjects) { .nativeThread(id: $0, agentID: hidden, request: .snapshot()) }
        try await refuse("agent/attach-unknown-session", on: full) {
            .attach(id: $0, sessionID: SessionID(), cols: 80, rows: 24, viewportGeneration: 0)
        }
        try await refuse("agent/upload-unknown-session", on: full) { .upload(id: $0, action: .begin(sessionID: SessionID(), name: "notes.txt", size: 1)) }
        // The coordinator is not in this client's state, but its id is in the host's: today the host forwards the action.
        let stored = { [self] in ["state.json.coordinatorName": try persisted(hidden, "name")] }
        try await refuse("agent/action-invisible-coordinator", on: full, extra: stored) { .agentAction(id: $0, agentID: hidden, action: .rename(name: "taken over")) }
    }

    private func fleetPeerAnswers() async throws {
        let client = try await connect(capabilities: Self.current)
        try await refuse("peer/fleetPeerAnswer-not-a-peer", on: client) { .fleetPeerAnswer(id: $0, reply: .ok(id: $0)) }
    }

    /// A message for an agent from a process that is not the pi Shepherd started for it: this test process is not.
    private func extensionSocket() async throws {
        let wire = try Wire(unixPath: app.scratch.socketPath)
        let id = thread.agent.id, hidden = coordinator.agent.id, ghost = unknown
        let pane = thread.piPane.id
        let status = { [self] in ["state.json.status": try persisted(id, "status"), "state.json.name": try persisted(id, "name")] }
        for (step, message) in [
            ("setAgentStatus", ExtensionMessage.setAgentStatus(agentID: id, status: .working)),
            ("setAgentName", .setAgentName(agentID: id, name: "renamed by a bash tool")),
            ("setAgentSession", .setAgentSession(agentID: id, piSessionID: "acme-session")),
            ("notify", .notify(agentID: id, title: "acme", body: "from a bash tool")),
            ("helloAgent", .helloAgent(agentID: id)),
        ] {
            // Fire and forget: the request after it, on the same connection, is answered after it.
            try await refuseExtension("extension/\(step)", on: wire, sending: message, status: status) { .listPanes(id: $0, agentID: id) }
        }
        try await refuseExtension("extension/listPanes", on: wire, status: status) { .listPanes(id: $0, agentID: id) }
        try await refuseExtension("extension/openPane", on: wire, status: status) {
            .openPane(id: $0, agentID: id, axis: .vertical, cwd: nil, relativeTo: nil, command: "echo hello")
        }
        try await refuseExtension("extension/sendPaneInput", on: wire, status: status) {
            .sendPaneInput(id: $0, agentID: id, paneID: pane, text: "echo hello", submit: true)
        }
        try await refuseExtension("extension/listPanes-coordinator", on: wire, status: status) { .listPanes(id: $0, agentID: hidden) }
        try await refuseExtension("extension/listPanes-unknown", on: wire, status: status) { .listPanes(id: $0, agentID: ghost) }
    }

    /// Sends `message` (if any), then the request `make` builds; records the answer to the request.
    private func refuseExtension(_ step: String, on wire: Wire, sending message: ExtensionMessage? = nil, status: () throws -> [String: Any],
                                 _ make: (Int) -> ExtensionMessage) async throws {
        let before = try await snapshot()
        if let message { try wire.send(NDJSON.encode(message)) }
        let request = try NDJSON.encode(make(wire.nextID()))
        try wire.send(request)
        var result = fields(of: try json(request), prefix: "request")
        if let message { result.merge(fields(of: try json(NDJSON.encode(message)), prefix: "first")) { $1 } }
        result.merge(replyFields(try await awaitReply(wire))) { $1 }
        result.merge(try await aftermath(before)) { $1 }
        result.merge(try status()) { $1 }
        record(step, result)
    }
}

// MARK: - A refused settings change writes nothing

/// A refused settings change leaves `host-preferences.json` and the preferences domain unchanged.
@Suite("Refused settings change", .mainActorExclusive)
@MainActor
struct RefusedSettingsChangeTests {
    @Test(arguments: [RemoteProtocol.hostSettingsCapability, RemoteProtocol.hostSettingsCloseOnMergeCapability])
    func aChangeWithoutTheHostsOfferWritesNoPreferences(withheld: String) async throws {
        let app = try AppHarness()
        defer { app.stop() }
        app.server.advertisedCapabilities.removeAll { $0 == withheld }
        try await app.start()
        let port = try app.server.startRemoteListener(port: 0, tokenURL: app.dir.appendingPathComponent("remote-token"))
        let file = app.dir.appendingPathComponent("host-preferences.json")
        let before = try Data(contentsOf: file)
        let domain = { NSDictionary(dictionary: app.defaults.persistentDomain(forName: app.defaults.name) ?? [:]) }
        let defaultsBefore = domain()
        let client = try Wire(port: port)
        try client.send(NDJSON.encode(RemoteRequest.hello(id: client.nextID(), token: app.server.clientTokenForTests(), clientName: "acme-phone",
                                                        protocolVersion: RemoteProtocol.version, capabilities: [])))
        guard case .line(let hello) = await client.next(),
              case .helloOk(_, _, let offered, _, _) = try NDJSON.decode(RemoteReply.self, from: hello) else {
            Issue.record("expected helloOk")
            return
        }
        #expect(!offered.contains(withheld))

        let id = client.nextID()
        try client.send(NDJSON.encode(RemoteRequest.hostSettings(id: id, request: .change(.closeOnMerge(true)))))
        guard case .line(let reply) = await client.next(),
              case .error(let replyID, let code, let message) = try NDJSON.decode(RemoteReply.self, from: reply) else {
            Issue.record("expected a settings refusal")
            return
        }
        #expect(replyID == id)
        #expect(code == "unsupported")
        #expect(message == "The host does not take this request.")
        #expect(try Data(contentsOf: file) == before)
        #expect(domain().isEqual(defaultsBefore))
        #expect(app.hostSettings?.worktreeCloseOnMerge == false)
    }

    @Test func aChangeRefusedBeforeAnAuthenticatedHelloWritesNoPreferences() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        try await app.start()
        let port = try app.server.startRemoteListener(port: 0, tokenURL: app.dir.appendingPathComponent("remote-token"))
        let file = app.dir.appendingPathComponent("host-preferences.json")
        // Both are at least as old as the host's start (`ShepherdHost.serveSettings` writes the file; `AppSettings` its keys).
        let before = try Data(contentsOf: file)
        let domain = { NSDictionary(dictionary: app.defaults.persistentDomain(forName: app.defaults.name) ?? [:]) }
        let defaultsBefore = domain()

        func send(_ wire: Wire, _ request: RemoteRequest) async throws -> Wire.Frame {
            try wire.send(NDJSON.encode(request))
            return await wire.next()
        }
        let change = { (id: Int) in RemoteRequest.hostSettings(id: id, request: .change(.closeOnMerge(true))) }

        // No hello at all.
        let silent = try Wire(port: port)
        guard case .line(let refused) = try await send(silent, change(silent.nextID())),
              try #require(JSONSerialization.jsonObject(with: refused) as? [String: Any])["code"] as? String == "unauthenticated" else {
            Issue.record("a change before hello was not refused `unauthenticated`")
            return
        }

        // A hello with a token the host does not know, then the change on the same connection.
        let impostor = try Wire(port: port)
        guard case .line(let rejected) = try await send(impostor, .hello(id: impostor.nextID(), token: "wrong", clientName: "acme-phone",
                                                                         protocolVersion: RemoteProtocol.version, capabilities: [])),
              try #require(JSONSerialization.jsonObject(with: rejected) as? [String: Any])["code"] as? String == RemoteProtocol.sharedTokenRetiredCode else {
            Issue.record("a hello with an unknown token was not answered `shared_token_retired`")
            return
        }
        guard case .closed = await impostor.next() else {
            Issue.record("the connection stayed open after the token was rejected")
            return
        }
        // The host has closed it: the change goes nowhere.
        guard case .closed = try await send(impostor, change(impostor.nextID())) else {
            Issue.record("a change after a rejected hello was answered")
            return
        }

        // A request the host answers after these has been served after any write they would have made.
        let client = try Wire(port: port)
        guard case .line = try await send(client, .hello(id: client.nextID(), token: app.server.clientTokenForTests(), clientName: "acme-phone",
                                                         protocolVersion: RemoteProtocol.version, capabilities: [])) else {
            Issue.record("no helloOk")
            return
        }
        guard case .line = try await send(client, .hostSettings(id: client.nextID(), request: .fetch)) else {
            Issue.record("no hostSettings reply")
            return
        }
        #expect(try Data(contentsOf: file) == before)
        #expect(domain().isEqual(defaultsBefore))
        #expect(app.hostSettings?.worktreeCloseOnMerge == false)

        // The same change, authenticated, is applied: it writes the file and the key, so the comparisons above can fail.
        guard case .line = try await send(client, change(client.nextID())) else {
            Issue.record("no reply to the authenticated change")
            return
        }
        #expect(try Data(contentsOf: file) != before)
        #expect(!domain().isEqual(defaultsBefore))
    }
}

@Suite("Preferences temporary filter")
struct PreferencesTemporaryFilterTests {
    @Test func onlyTheAtomicWritesTemporaryBesideThePreferencesFileIsIgnored() {
        let root = "/private/tmp/acme"
        #expect(FileEvents.isPreferencesTemporary(root + "/host-preferences.json.sb-1a2b3c", under: root))
        #expect(!FileEvents.isPreferencesTemporary(root + "/cache.sb-old/x", under: root))
        #expect(!FileEvents.isPreferencesTemporary(root + "/other.json", under: root))
        #expect(!FileEvents.isPreferencesTemporary(root + "/cache/host-preferences.json.sb-1a2b3c", under: root))
    }
}
