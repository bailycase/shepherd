import Darwin
import Foundation
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// The refusal corpus (C-AUTH): for each request family, the reply and the observable state after a request the host must refuse.
/// It characterizes what the host does today, against `Tests/Fixtures/c-auth.json`, and weakens no check to see one.
@Suite("Refusal corpus", .mainActorExclusive)
@MainActor
struct RefusalCorpusTests {
    @Test func refusalCorpusMatchesGolden() async {
        // A child process of its own: "no process started" counts the children of this process, which no other test may spawn.
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.checkingRefusals() }
        }
        expectScenarioCompleted(result)
    }

    private static func checkingRefusals() async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/c-auth.json")
        let directory = ValidationEvidence.directory
        let golden = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
        let seed = try #require(golden["seed"] as? [String: String])
        let corpus = try await Corpus(seed: seed)
        defer { corpus.stop() }
        try await corpus.run()
        let observed = corpus.observations.map { ["step": $0.step, "fields": $0.fields] as [String: Any] }
        if let directory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["observations": observed], options: [.sortedKeys, .prettyPrinted])
                .write(to: directory.appendingPathComponent("observed.json"), options: .atomic)
        }

        let expected = try #require(golden["observations"] as? [[String: Any]])
        func display(_ value: Any?) -> String {
            guard let value, let json = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]) else {
                return "<missing>"
            }
            return String(decoding: json, as: UTF8.self)
        }
        var before: [String] = [], after: [String] = []
        for index in 0..<max(expected.count, observed.count) {
            let old = expected.indices.contains(index) ? expected[index] : nil
            let new = observed.indices.contains(index) ? observed[index] : nil
            let step = (new?["step"] ?? old?["step"]) as? String ?? "<missing step \(index)>"
            if (old?["step"] as? String) != (new?["step"] as? String) {
                before.append("observation \(index) = \(display(old?["step"]))")
                after.append("observation \(index) = \(display(new?["step"]))")
                continue
            }
            let oldFields = old?["fields"] as? [String: Any] ?? [:], newFields = new?["fields"] as? [String: Any] ?? [:]
            for field in Set(oldFields.keys).union(newFields.keys).sorted() where display(oldFields[field]) != display(newFields[field]) {
                before.append("\(step).\(field) = \(display(oldFields[field]))")
                after.append("\(step).\(field) = \(display(newFields[field]))")
            }
        }
        if !before.isEmpty {
            let expected = before.joined(separator: "\n"), actual = after.joined(separator: "\n")
            try? ValidationEvidence.record(in: directory, step: "compare-golden", status: "failed", expected: expected, actual: actual,
                                           evidence: directory == nil ? [] : ["mac/observed.json"])
            try #require(before.isEmpty, "Expected: \(expected)\nActual:   \(actual)")
        }
        let completed = "refusal corpus matched the golden"
        for step in ["compare-golden", "complete"] {
            try ValidationEvidence.record(in: directory, step: step, status: "passed", expected: completed, actual: completed)
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

// MARK: - The corpus

@MainActor
private final class Corpus {
    let app: AppHarness
    let port: UInt16
    let space: Space
    let thread: AgentFixture
    let coordinator: AgentFixture
    let unknown = AgentID()
    var observations: [(step: String, fields: [String: Any])] = []
    private var observer: Wire!
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
        var owner = Fixture.agent(seed["coordinator"]!, in: reserved)
        owner.agent.coordinatorFor = ProjectID()
        coordinator = owner
        // The host's fleet starts with the app's host services: named, and with no Bonjour or iCloud.
        app.server.configureFleet(name: seed["fleetName"]!, advertises: false)
        try await app.start(with: Fixture.state(spaces: [space, reserved], agents: [thread, owner]))
        port = try app.server.startRemoteListener(port: 0, tokenURL: app.dir.appendingPathComponent("remote-token"))
        app.scratch.useRealPeerCheck()
        for (id, label) in [(thread.agent.id.rawValue, "<thread>"), (coordinator.agent.id.rawValue, "<coordinator>"),
                            (unknown.rawValue, "<unknown agent>"), (space.id.rawValue, "<space>")] {
            labels[id.lowercased()] = label
        }
        observer = try await connect(capabilities: Self.bare, name: "observer")
    }

    func stop() {
        observer = nil
        app.stop()
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

    /// `value` as one entry per path (`a.b[0].c`), normalized; a list of plain values is one entry.
    private func flatten(_ value: Any, _ path: String, into fields: inout [String: Any]) {
        switch value {
        case let object as [String: Any]:
            // Sorted, so IDs are numbered in the same order every run.
            for key in object.keys.sorted() { flatten(object[key]!, path.isEmpty ? key : "\(path).\(key)", into: &fields) }
        case let array as [Any]:
            if array.allSatisfy({ !($0 is [String: Any] || $0 is [Any]) }) {
                fields[path] = array.map { ($0 as? String).map(normalize) ?? $0 }
            } else {
                for (index, member) in array.enumerated() { flatten(member, "\(path)[\(index)]", into: &fields) }
            }
        case let text as String: fields[path] = normalize(text)
        case is NSNull: fields[path] = "null"
        default: fields[path] = value
        }
    }

    /// `object` flattened under `prefix`, without the top-level members in `leaving` (a secret).
    private func fields(of object: [String: Any]?, prefix: String, leaving: Set<String> = []) -> [String: Any] {
        guard let object else { return [prefix: "<none>"] }
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

    private struct Snapshot {
        var state: String?
        var stored: Data
        var files: [String: Int]
        var children: Set<Int32>
    }

    private func snapshot() async throws -> Snapshot {
        let (_, reply) = try await exchange(observer, .stateFetch(id: observer.nextID()))
        var state: String?
        if case .object(let object) = reply, let value = object["state"] {
            state = String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
        }
        var files: [String: Int] = [:]
        let root = app.dir.resolvingSymlinksInPath()
        for path in (try? FileManager.default.subpathsOfDirectory(atPath: root.path)) ?? [] {
            let attributes = try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(path).path)
            guard attributes?[.type] as? FileAttributeType == .typeRegular else { continue }
            files["/" + path] = (attributes?[.size] as? Int) ?? 0
        }
        return Snapshot(state: state, stored: (try? Data(contentsOf: app.scratch.stateURL)) ?? Data(), files: files, children: Self.children())
    }

    private static func children() -> Set<Int32> {
        var pids = [Int32](repeating: 0, count: 256)
        let count = proc_listchildpids(getpid(), &pids, Int32(pids.count * MemoryLayout<Int32>.size))
        return Set(pids.prefix(max(0, Int(count))).filter { $0 > 0 })
    }

    /// What a refusal left behind, from the reply, the stored file, a second client's `stateFetch`, the files under the scratch root and
    /// the processes this one started.
    private func aftermath(_ before: Snapshot) async throws -> [String: Any] {
        let after = try await snapshot()
        let changed = Set(before.files.keys).union(after.files.keys).filter { before.files[$0] != after.files[$0] }
        return [
            "stateFetch.unchanged": before.state == after.state,
            "state.json.unchanged": before.stored == after.stored,
            "files.changed": changed.sorted().map(normalize),
            "processes.started": after.children.subtracting(before.children).count,
        ]
    }

    private func record(_ step: String, _ fields: [String: Any]) {
        observations.append((step, fields))
    }

    /// Sends a request on `wire` and records the reply, whether `wire` still answers, and what the request left behind.
    private func refuse(_ step: String, on wire: Wire, extra: () -> [String: Any] = { [:] }, _ make: (Int) -> RemoteRequest) async throws {
        try await refuse(step, on: wire, raw: NDJSON.encode(make(wire.nextID())), extra: extra)
    }

    private func refuse(_ step: String, on wire: Wire, raw: Data, extra: () -> [String: Any] = { [:] }) async throws {
        let before = try await snapshot()
        let (sent, reply) = try await exchange(wire, raw: raw)
        var result = fields(of: sent, prefix: "request", leaving: ["token", "sendToken"])
        result.merge(replyFields(reply)) { $1 }
        result["connection.after"] = try await probe(wire)
        result.merge(try await aftermath(before)) { $1 }
        result.merge(extra()) { $1 }
        record(step, result)
    }

    /// The settings a host settings reply carries are the whole list: only the two this corpus changes are recorded.
    private func replyFields(_ reply: Reply) -> [String: Any] {
        switch reply {
        case .object(var object):
            if let settings = object["settings"] as? [String: Any] {
                object["settings"] = settings.filter { ["closeOnMerge", "compactAtPercent"].contains($0.key) }
            }
            return fields(of: object, prefix: "reply")
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

    /// The host has no offered-and-negotiated check for `hostSettings`: this records what it takes and refuses from a client that listed nothing.
    private func hostSettings() async throws {
        let client = try await connect(capabilities: Self.bare)
        let stored = { [app] in ["stored.closeOnMerge": app.settings.worktreeCloseOnMerge] as [String: Any] }
        try await refuse("hostSettings/fetch", on: client, extra: stored) { .hostSettings(id: $0, request: .fetch) }
        // `closeOnMerge` needs `hostSettings.closeOnMerge.v1`, which this client never listed: the host still applies it.
        try await refuse("hostSettings/change-not-negotiated", on: client, extra: stored) { .hostSettings(id: $0, request: .change(.closeOnMerge(true))) }
        try await refuse("hostSettings/change-back", on: client, extra: stored) { .hostSettings(id: $0, request: .change(.closeOnMerge(false))) }
        // A share Settings does not offer is left as it is, and answered like any change.
        try await refuse("hostSettings/change-unoffered-share", on: client, extra: stored) { .hostSettings(id: $0, request: .change(.compactAtPercent(37))) }
        try await refuse("hostSettings/change-refused", on: client, extra: stored) { .hostSettings(id: $0, request: .change(.slashCommand(name: "", on: true))) }
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

    /// The limit's worth of requests are answered; the next is `busy`, and the connection closes. Records the first, the last allowed and
    /// the refused one, and what each of the others answered.
    private func limited(_ step: String, _ make: (Int, Int) -> RemoteRequest) async throws {
        let limit = FleetService.unauthenticatedRequestLimit
        let wire = try unauthenticated()
        let before = try await snapshot()
        var answers: [String] = []
        for index in 0..<limit {
            let (sent, reply) = try await exchange(wire, make(index, wire.nextID()))
            answers.append("\(sent["type"] as? String ?? "?") > \(reply.summary)")
            if index == 0 || index == limit - 1, case .object(let object) = reply {
                record("\(step)#\(index + 1)", fields(of: sent, prefix: "request").merging(fields(of: object, prefix: "reply")) { $1 })
            }
        }
        try await refuse("\(step)#\(limit + 1)", on: wire) { make(limit, $0) }
        // The count is per connection: a new one is answered again.
        let fresh = try unauthenticated()
        let (_, again) = try await exchange(fresh, make(0, fresh.nextID()))
        var summary: [String: Any] = ["limit": limit, "answers": answers, "new connection": again.summary]
        summary.merge(try await aftermath(before)) { $1 }
        record("\(step)/summary", summary)
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
        let stored = { [app, hidden] in ["stored.coordinatorName": app.server.state.agents.first { $0.id == hidden }?.name ?? "<none>"] as [String: Any] }
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
        let status = { [app, id] in
            ["stored.status": app.server.state.agents.first { $0.id == id }?.status.rawValue ?? "<none>",
             "stored.name": app.server.state.agents.first { $0.id == id }?.name ?? "<none>"] as [String: Any]
        }
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
    private func refuseExtension(_ step: String, on wire: Wire, sending message: ExtensionMessage? = nil, status: () -> [String: Any],
                                 _ make: (Int) -> ExtensionMessage) async throws {
        let before = try await snapshot()
        if let message { try wire.send(NDJSON.encode(message)) }
        let request = try NDJSON.encode(make(wire.nextID()))
        try wire.send(request)
        var result = fields(of: try json(request), prefix: "request")
        if let message { result.merge(fields(of: try json(NDJSON.encode(message)), prefix: "first")) { $1 } }
        result.merge(replyFields(try await awaitReply(wire))) { $1 }
        result.merge(try await aftermath(before)) { $1 }
        result.merge(status()) { $1 }
        record(step, result)
    }
}

private extension Corpus.Reply {
    var summary: String {
        switch self {
        case .object(let object): [object["type"] as? String, object["code"] as? String].compactMap { $0 }.joined(separator: " > ")
        case .closed: "<closed>"
        case .timeout: "<no reply>"
        }
    }
}
