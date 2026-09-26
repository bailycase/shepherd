import Darwin
import Foundation
import ShepherdCore
import ShepherdProtocol

/// A Shepherd host for screenshots, inside the fixture app: a real TCP listener on 127.0.0.1
/// speaking the remote protocol, so the app connects through `MobileHosts` and
/// `RemoteHostClient` exactly as it would to a Mac. It serves fixed data and changes nothing:
/// every request that would change the host is refused and reported as a mutation.
///
/// Compiled only by run-simulator.sh, never into the shipped app.
final class FixtureHost: @unchecked Sendable {
    let data: FixtureHostData
    private(set) var port: UInt16 = 0
    private var listener: Int32 = -1
    private let lock = NSLock()
    private var seen: [String] = []
    /// The connections being served, for `push`.
    private var connections: Set<Int32> = []
    /// One frame at a time on a connection: a reply and a push never interleave.
    private let writing = NSLock()

    private static let registry = NSLock()
    nonisolated(unsafe) private static var started: [UUID: FixtureHost] = [:]

    /// The running host with this id, for a screen that changes what a host says after it shows.
    static func running(_ id: UUID) -> FixtureHost? { registry.withLock { started[id] } }

    init(_ data: FixtureHostData) {
        self.data = data
    }

    /// Request kinds this host received, in order.
    var requests: [String] { lock.withLock { seen } }

    /// Binds an ephemeral port. An offline host binds and closes one, so connecting is refused.
    func start() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw FixtureError("socket failed") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else { throw FixtureError("bind failed") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        port = UInt16(bigEndian: address.sin_port)
        Self.registry.withLock { Self.started[data.id] = self }
        guard data.online else {
            close(fd)
            return
        }
        listener = fd
        Thread.detachNewThread { [self] in
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                var one: Int32 = 1
                _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                Thread.detachNewThread { [self] in serve(client) }
            }
        }
    }

    /// Pushes a new state to every connected client, as a host does after it changes.
    func push(_ state: ShepherdState) {
        guard let encoded = try? NDJSON.encode(RemoteReply.stateChanged(state: state)) else { return }
        for fd in lock.withLock({ connections }) { _ = write(fd, encoded) }
    }

    private func serve(_ fd: Int32) {
        lock.withLock { _ = connections.insert(fd) }
        defer {
            lock.withLock { _ = connections.remove(fd) }
            close(fd)
        }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { return }
            buffer.append(contentsOf: chunk[0..<count])
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let request = try? NDJSON.decode(RemoteRequest.self, from: Data(line)) else { continue }
                for reply in answer(request) {
                    guard let encoded = try? NDJSON.encode(reply), write(fd, encoded) else { return }
                    // A refused hello is a final reply, as on a real host.
                    if case .error(_, RemoteProtocol.unauthorizedCode, _) = reply { return }
                }
            }
        }
    }

    private func write(_ fd: Int32, _ data: Data) -> Bool {
        writing.withLock { data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard written > 0 else { return false }
                offset += written
            }
            return true
        } }
    }

    private func note(_ kind: String) {
        lock.withLock { seen.append(kind) }
    }

    private func mutation(_ kind: String) {
        note(kind)
        print("FIXTURE MUTATION \(data.name) \(kind)")
        fflush(stdout)
    }

    private func answer(_ request: RemoteRequest) -> [RemoteReply] {
        // Mutations are refused before a screen's own answers, so no fixture can let one through.
        if let refusal = refuse(request) { return refusal }
        if let reply = data.reply?(request) {
            note(Self.kind(request))
            return [reply]
        }
        switch request {
        case .hello(let id, let token, _, _, _):
            note("hello")
            guard token == FixtureHostData.token, !data.refusesToken else {
                return [.error(id: id, code: RemoteProtocol.unauthorizedCode, message: "bad token")]
            }
            // A host serves designs only with its Design tool on: here, only with fixture designs.
            let offered = data.capabilities ?? RemoteProtocol.capabilities.filter {
                $0 != RemoteProtocol.designsCapability || data.designs != nil
            }
            return [.helloOk(id: id, protocolVersion: RemoteProtocol.version, capabilities: offered)]
        case .stateFetch(let id):
            note("stateFetch")
            return [.state(id: id, state: data.state)]
        case .nativeThread(let id, let agentID, let command):
            guard case .snapshot(_, _, let after) = command else {
                note("nativeThread." + Self.kind(command))
                return [.nativeThread(id: id, result: .failure(code: "fixture", message: "No fixture answer for this request."))]
            }
            note("nativeThread.snapshot")
            guard let snapshot = data.threads[agentID] else {
                return [.nativeThread(id: id, result: .failure(code: "agent_not_found", message: "No thread in this fixture."))]
            }
            if after == snapshot.revision {
                return [.nativeThread(id: id, result: .unchanged(piSessionID: snapshot.piSessionID, generation: snapshot.generation,
                                                                  revision: snapshot.revision))]
            }
            return [.nativeThread(id: id, result: .snapshot(value: snapshot))]
        case .listModels(let id):
            note("listModels")
            return [.models(id: id, models: data.models, defaultModel: data.models.first, withoutThinking: data.withoutThinking,
                            thinkingLevels: data.thinkingLevels)]
        case .hostSettings(let id, .fetch) where data.hostSettings != nil:
            note("hostSettings.fetch")
            return [.hostSettings(id: id, settings: data.hostSettings!)]
        case .instructions(let id, .fetch) where data.instructions != nil:
            note("instructions.fetch")
            return [.instructions(id: id, snapshot: data.instructions!)]
        case .suggestions(let id, .fetch) where data.suggestions != nil:
            note("suggestions.fetch")
            return [.suggestions(id: id, snapshot: data.suggestions!)]
        case .skills(let id, .fetch) where data.skills != nil:
            note("skills.fetch")
            return [.skills(id: id, result: .skills(data.skills!))]
        case .skills(let id, .lookUp) where data.repoSkills != nil:
            note("skills.lookUp")
            return [.skills(id: id, result: .repo(data.repoSkills!))]
        case .design(let id, let request) where data.designs != nil:
            note("design." + Self.kind(request))
            switch data.designs!.answer(request) {
            case .success(let result): return [.design(id: id, result: result)]
            case .failure(let error): return [.error(id: id, code: "fixture", message: error.description)]
            }
        case .design(let id, _):
            note(Self.kind(request))
            return [.error(id: id, code: RemoteDesignCode.off, message: "The Design tool is off on this host.")]
        case .listDir(let id, _), .creationOptions(let id, _, _, _), .agentQuery(let id, _, _), .automation(let id, _, _),
             .instructions(let id, _), .suggestions(let id, _), .hostSettings(let id, _), .skills(let id, _):
            note(Self.kind(request))
            return [.error(id: id, code: "fixture", message: "No fixture answer for this request.")]
        default:
            return []
        }
    }

    /// The refusal for a request that would change the host, reported as a mutation; nil for a read.
    private func refuse(_ request: RemoteRequest) -> [RemoteReply]? {
        let refused = "The fixture host changes nothing."
        switch request {
        case .nativeThread(let id, _, let command):
            switch command {
            case .snapshot, .subagentTranscript: return nil
            default:
                mutation("nativeThread." + Self.kind(command))
                return [.nativeThread(id: id, result: .failure(code: "fixture", message: refused))]
            }
        case .attach(let id, _, _, _, _), .paste(let id, _, _, _), .openPane(let id, _, _, _), .closePane(let id, _, _),
             .resizePaneSplit(let id, _, _, _), .addSpace(let id, _), .createAgent(let id, _, _, _, _, _, _, _, _, _),
             .agentAction(let id, _, _), .upload(let id, _):
            mutation(Self.kind(request))
            return [.error(id: id, code: "fixture", message: refused)]
        case .automation(let id, _, let command):
            // Reading an automation's runs is the one automation request that changes nothing.
            if command == .runs { return nil }
            mutation("automation." + String(describing: command).prefix { $0 != "(" })
            return [.error(id: id, code: "fixture", message: refused)]
        case .instructions(let id, let command):
            // Reading the host's instructions changes nothing; a save or a restore writes them.
            if command == .fetch { return nil }
            mutation("instructions." + String(describing: command).prefix { $0 != "(" })
            return [.error(id: id, code: "fixture", message: refused)]
        case .suggestions(let id, let command):
            // Reading the host's suggestions changes nothing; every other request writes.
            if command == .fetch { return nil }
            mutation("suggestions." + String(describing: command).prefix { $0 != "(" })
            return [.error(id: id, code: "fixture", message: refused)]
        case .hostSettings(let id, let command):
            // Reading the host's settings changes nothing; a change writes them.
            if command == .fetch { return nil }
            mutation("hostSettings.change")
            return [.error(id: id, code: "fixture", message: refused)]
        case .skills(let id, let command):
            // Reading the host's skills or looking up a repository changes nothing.
            switch command {
            case .fetch, .lookUp: return nil
            default:
                mutation("skills." + String(describing: command).prefix { $0 != "(" })
                return [.error(id: id, code: "fixture", message: refused)]
            }
        case .detach, .input, .resize:
            mutation(Self.kind(request))
            return []
        case .agentQuery(let id, _, .commit):
            // Commit from review changes the host's repository.
            mutation("agentQuery.commit")
            return [.error(id: id, code: "fixture", message: refused)]
        case .design(let id, let request):
            // Reading designs changes nothing; a comment, a tweak, a move or a new design writes.
            guard request.writes else { return nil }
            mutation("design." + Self.kind(request))
            return [.error(id: id, code: "fixture", message: refused)]
        case .agentQuery(let id, _, .changesUndoTurn), .agentQuery(let id, _, .changesRedoTurn):
            // Undo and Redo change the agent's working tree.
            mutation("agentQuery.changesUndoTurn")
            return [.error(id: id, code: "fixture", message: refused)]
        case .hello, .stateFetch, .listModels, .listDir, .creationOptions, .agentQuery:
            return nil
        }
    }

    static func kind(_ request: RemoteRequest) -> String {
        String(describing: request).prefix { $0 != "(" }.description
    }

    static func kind(_ request: RemoteDesignRequest) -> String {
        String(describing: request).prefix { $0 != "(" }.description
    }

    static func kind(_ command: NativeThreadRequest) -> String {
        String(describing: command).prefix { $0 != "(" }.description
    }
}

struct FixtureError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
