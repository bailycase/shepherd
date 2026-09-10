import Darwin
import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdRemote

@Suite("Remote client module")
struct RemoteClientUnitTests {
    @Test func connectToNothingFails() async {
        let client = RemoteHostClient()
        await #expect(throws: RemoteHostClientError.self) {
            _ = try await client.connect(host: "127.0.0.1", port: 1, token: "x", clientName: "test")
        }
    }

    @Test func requestsAfterDisconnectFail() async {
        let client = RemoteHostClient()
        await #expect(throws: RemoteHostClientError.self) {
            try await client.attach(sessionID: .init(), cols: 80, rows: 24)
        }
    }

    @Test func concurrentUploadsRejectWithoutInterruptingTheFirstTransfer() async throws {
        let (listener, port) = try makeListener()
        defer { close(listener) }
        let began = AsyncStream<Void>.makeStream()
        let proceed = AsyncStream<Void>.makeStream()
        let bytes = Data([1, 2, 3])
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let received = Task.detached { () throws -> Data in
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { throw RemoteHostClientError.disconnected }
            defer { close(fd) }
            _ = try readLine(fd)
            try writeAll(fd, NDJSON.encode(RemoteReply.helloOk(id: 1, protocolVersion: RemoteProtocol.version, capabilities: [RemoteProtocol.uploadCapability, RemoteProtocol.worktreeActionsCapability])))
            _ = try readLine(fd)
            try writeAll(fd, NDJSON.encode(RemoteReply.state(id: 2, state: ShepherdState())))
            guard case .upload(let id, .begin) = try NDJSON.decode(RemoteRequest.self, from: readLine(fd)) else {
                throw RemoteHostClientError.disconnected
            }
            began.continuation.yield(())
            var permission = proceed.stream.makeAsyncIterator()
            _ = await permission.next()
            let uploadID = UUID()
            try writeAll(fd, NDJSON.encode(RemoteReply.uploadResult(id: id, result: .ready(uploadID: uploadID))))
            var received = Data()
            while true {
                switch try NDJSON.decode(RemoteRequest.self, from: readLine(fd)) {
                case .upload(let id, .chunk(_, let data)):
                    received.append(data)
                    try writeAll(fd, NDJSON.encode(RemoteReply.ok(id: id)))
                case .upload(let id, .finish):
                    try writeAll(fd, NDJSON.encode(RemoteReply.uploadResult(id: id, result: .complete(path: "/host/drop"))))
                    // Closing after reading the action leaves its outcome unknown.
                    _ = try readLine(fd)
                    return received
                default: throw RemoteHostClientError.disconnected
                }
            }
        }
        let client = RemoteHostClient()
        _ = try await client.connect(host: "127.0.0.1", port: port, token: "x", clientName: "test")
        defer { client.disconnect(); proceed.continuation.finish() }
        let first = Task { try await client.upload(file: file, sessionID: SessionID()) }
        var started = began.stream.makeAsyncIterator()
        _ = await started.next()
        do {
            _ = try await client.upload(file: file, sessionID: SessionID())
            Issue.record("Concurrent transfer was accepted")
        } catch RemoteHostClientError.rejected(let code, _) { #expect(code == "upload_busy") }
        proceed.continuation.yield(())
        #expect(try await first.value == "/host/drop")
        do {
            _ = try await client.agentQuery(agentID: AgentID(), query: .deleteWorktree(operationID: UUID(), confirmedWarning: nil, fingerprint: "fingerprint"))
            Issue.record("Expected a lost reply")
        } catch RemoteHostClientError.disconnected {
            // Not a rejection: the host received this action before disconnecting.
        }
        #expect(try await received.value == bytes)
        do {
            _ = try await client.agentQuery(agentID: AgentID(), query: .worktreeStatus(operationID: UUID()))
            Issue.record("Disconnected request was accepted")
        } catch RemoteHostClientError.rejected(let code, _) { #expect(code == "not_sent") }
    }

    @Test func pasteFallsBackToInputForLegacyHost() async throws {
        let (listener, port) = try makeListener()
        defer { close(listener) }

        let received = Task.detached { () throws -> Data in
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { throw RemoteHostClientError.disconnected }
            defer { close(fd) }

            _ = try readLine(fd)
            try writeLine(fd, #"{"type":"helloOk","id":1,"protocolVersion":1}"#)
            _ = try readLine(fd)
            let state = try NDJSON.encode(RemoteReply.state(id: 2, state: ShepherdState()))
            try writeAll(fd, state)

            guard case .listModels(let modelsID) = try NDJSON.decode(RemoteRequest.self, from: readLine(fd)) else {
                throw RemoteHostClientError.rejected(code: "test", message: "expected legacy model defaults")
            }
            try writeAll(fd, NDJSON.encode(RemoteReply.models(id: modelsID, models: ["legacy/model"], defaultModel: "legacy/model")))
            guard case .createAgent(let createID, _, _, let model, _, _, let branch, _, _) = try NDJSON.decode(RemoteRequest.self, from: readLine(fd)), model == "legacy/model", branch == nil else {
                throw RemoteHostClientError.rejected(code: "test", message: "expected ordinary legacy creation")
            }
            try writeAll(fd, NDJSON.encode(RemoteReply.agentCreated(id: createID, agentID: AgentID())))
            let line = try readLine(fd)
            guard case .input(_, let data) = try NDJSON.decode(RemoteRequest.self, from: line) else {
                throw RemoteHostClientError.rejected(code: "test", message: "expected input fallback")
            }
            return data
        }

        let client = RemoteHostClient()
        _ = try await client.connect(host: "127.0.0.1", port: port, token: "x", clientName: "test")
        #expect(client.capabilities.isEmpty)
        await #expect(throws: RemoteHostClientError.self) {
            try await client.openPane(agentID: AgentID(), relativeTo: PaneID(), axis: .vertical)
        }
        for action in [RemoteAgentAction.rename(name: "title"), .deleteKeepingWorktree, .reorder(target: AgentID())] {
            do {
                try await client.agentAction(agentID: AgentID(), action: action)
                Issue.record("Legacy host must reject agent actions before sending anything")
            } catch RemoteHostClientError.rejected(let code, _) {
                #expect(code == "update_required")
            }
        }
        for query in [RemoteAgentQuery.children, .review(pullRequest: false), .worktreeInfo, .worktreeStatus(operationID: UUID()), .worktreeSetup(action: .check), .worktreeCommitCount(base: "main"), .worktreeDescription(base: "main", title: "feature")] {
            do {
                _ = try await client.agentQuery(agentID: AgentID(), query: query)
                Issue.record("Legacy host must reject queries before sending")
            } catch RemoteHostClientError.rejected(let code, _) { #expect(code == "update_required") }
        }
        await #expect(throws: RemoteHostClientError.self) {
            _ = try await client.upload(file: URL(fileURLWithPath: "/must-not-read"), sessionID: SessionID())
        }
        await #expect(throws: RemoteHostClientError.self) {
            _ = try await client.creationOptions(spaceID: SpaceID(), cwd: "/must-not-probe", fetchFirst: false)
        }
        let defaults = try await client.creationOptions(spaceID: SpaceID(), cwd: nil, fetchFirst: nil)
        #expect(defaults.model == "legacy/model")
        #expect(defaults.thinking == .medium)
        _ = try await client.createAgent(spaceID: SpaceID(), cwd: nil, model: defaults.model, thinking: defaults.thinking, initialPrompt: nil)
        try await client.paste(sessionID: SessionID(), text: "one\ntwo", submit: true)
        #expect(try await received.value == RemoteProtocol.composedInput(text: "one\ntwo", submit: true))
        client.disconnect()
    }
}

private func readLine(_ fd: Int32) throws -> Data {
    var data = Data()
    var byte: UInt8 = 0
    while true {
        let count = Darwin.read(fd, &byte, 1)
        guard count == 1 else { throw RemoteHostClientError.disconnected }
        if byte == 0x0A { return data }
        data.append(byte)
    }
}

private func writeLine(_ fd: Int32, _ text: String) throws {
    try writeAll(fd, Data((text + "\n").utf8))
}

private func writeAll(_ fd: Int32, _ data: Data) throws {
    var offset = 0
    while offset < data.count {
        let count = data.withUnsafeBytes { raw in
            Darwin.write(fd, raw.baseAddress!.advanced(by: offset), data.count - offset)
        }
        guard count > 0 else { throw RemoteHostClientError.disconnected }
        offset += count
    }
}

private func makeListener() throws -> (Int32, UInt16) {
    let listener = socket(AF_INET, SOCK_STREAM, 0)
    guard listener >= 0 else { throw RemoteHostClientError.disconnected }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
    address.sin_port = 0
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    #expect(bound == 0)
    #expect(listen(listener, 1) == 0)
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            _ = getsockname(listener, $0, &length)
        }
    }
    return (listener, UInt16(bigEndian: address.sin_port))
}
