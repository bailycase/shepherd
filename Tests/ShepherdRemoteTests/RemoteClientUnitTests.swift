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

    @Test func pasteFallsBackToInputForLegacyHost() async throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        #expect(listener >= 0)
        defer { close(listener) }

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
        let port = UInt16(bigEndian: address.sin_port)

        let received = Task.detached { () throws -> Data in
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { throw RemoteHostClientError.disconnected }
            defer { close(fd) }

            _ = try readLine(fd)
            try writeLine(fd, #"{"type":"helloOk","id":1,"protocolVersion":1}"#)
            _ = try readLine(fd)
            let state = try NDJSON.encode(RemoteReply.state(id: 2, state: ShepherdState()))
            try writeAll(fd, state)

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
