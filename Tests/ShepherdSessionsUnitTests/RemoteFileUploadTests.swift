import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions

/// A remote client's dropped file lands in a private directory, bounded and all-or-nothing.
@Suite("Remote file upload")
struct RemoteFileUploadTests {
    private func withDropDirectory(_ body: (URL) throws -> Void) throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir.appendingPathComponent("remote-drops"))
    }

    @Test func aCompleteUploadIsAPrivateFileNamedAfterItsID() throws {
        try withDropDirectory { drops in
            let upload = try RemoteFileUpload(directory: drops, sessionID: SessionID(), name: "shot.png", size: 3)
            try upload.append(Data([1, 2]))
            try upload.append(Data([3]))
            let path = try upload.finish()
            #expect(path == drops.appendingPathComponent("\(upload.id.uuidString)-shot.png").path)
            #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data([1, 2, 3]))
            #expect(try posixPermissions(URL(fileURLWithPath: path)) == 0o600)
            #expect(try posixPermissions(drops) == 0o700)
        }
    }

    @Test(arguments: ["", ".", "..", "../escape", "a/b", "new\nline", String(repeating: "n", count: 201)])
    func unsafeNamesAreRejected(name: String) throws {
        try withDropDirectory { drops in
            #expect(throws: RemoteCreateAgentError.self) {
                _ = try RemoteFileUpload(directory: drops, sessionID: SessionID(), name: name, size: 1)
            }
        }
    }

    @Test(arguments: [-1, RemoteProtocol.uploadMaxBytes + 1])
    func sizesOutsideTheLimitAreRejected(size: Int) throws {
        try withDropDirectory { drops in
            #expect(throws: RemoteCreateAgentError.self) {
                _ = try RemoteFileUpload(directory: drops, sessionID: SessionID(), name: "f", size: size)
            }
        }
    }

    @Test func chunksPastTheDeclaredSizeAreRejected() throws {
        try withDropDirectory { drops in
            let upload = try RemoteFileUpload(directory: drops, sessionID: SessionID(), name: "f", size: 1)
            #expect(throws: RemoteCreateAgentError.self) { try upload.append(Data([1, 2])) }
            #expect(throws: RemoteCreateAgentError.self) { try upload.append(Data()) }
        }
    }

    @Test func aChunkOverTheWireLimitIsRejected() throws {
        try withDropDirectory { drops in
            let size = RemoteProtocol.uploadChunkBytes + 1
            let upload = try RemoteFileUpload(directory: drops, sessionID: SessionID(), name: "f", size: size)
            #expect(throws: RemoteCreateAgentError.self) { try upload.append(Data(count: size)) }
        }
    }

    @Test func finishingEarlyFailsAndAnAbandonedUploadLeavesNoFile() throws {
        try withDropDirectory { drops in
            var upload: RemoteFileUpload? = try RemoteFileUpload(directory: drops, sessionID: SessionID(), name: "partial", size: 2)
            try upload?.append(Data([1]))
            #expect(throws: RemoteCreateAgentError.self) { _ = try upload?.finish() }
            upload = nil
            #expect(try FileManager.default.contentsOfDirectory(atPath: drops.path).isEmpty)
        }
    }

    @Test func dropsOlderThanADayArePrunedWhenAnUploadBegins() throws {
        try withDropDirectory { drops in
            try FileManager.default.createDirectory(at: drops, withIntermediateDirectories: true)
            let expired = drops.appendingPathComponent("expired")
            let recent = drops.appendingPathComponent("recent")
            try Data([1]).write(to: expired)
            try Data([1]).write(to: recent)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-90_000)], ofItemAtPath: expired.path)

            _ = try RemoteFileUpload(directory: drops, sessionID: SessionID(), name: "new", size: 0)
            #expect(!FileManager.default.fileExists(atPath: expired.path))
            #expect(FileManager.default.fileExists(atPath: recent.path))
        }
    }
}

/// The remote listener's shared secret and the extension socket's address.
@Suite("Server credentials and addresses")
struct ServerCredentialTests {
    @Test func theRemoteTokenIsGeneratedOnceAsOwnerOnlyHex() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("remote-token")

        let token = try SessionServer.loadOrCreateRemoteToken(at: url)
        #expect(token.count == 64)
        #expect(token.allSatisfy { $0.isHexDigit })
        #expect(try posixPermissions(url) == 0o600)
        #expect(try SessionServer.loadOrCreateRemoteToken(at: url) == token)
    }

    @Test func anExistingTokenIsReadTrimmedAndABlankOneIsReplaced() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("remote-token")
        try Data("  my-token \n".utf8).write(to: url)
        #expect(try SessionServer.loadOrCreateRemoteToken(at: url) == "my-token")

        try Data("\n".utf8).write(to: url)
        #expect(try SessionServer.loadOrCreateRemoteToken(at: url).count == 64)
    }

    @Test func socketPathsBeyondSunPathAreRejected() throws {
        let fits = "/tmp/" + String(repeating: "s", count: 90)
        #expect(throws: Never.self) { _ = try SessionServer.socketAddress(for: fits) }
        let tooLong = "/tmp/" + String(repeating: "s", count: 120)
        #expect(throws: SessionServerError.self) { _ = try SessionServer.socketAddress(for: tooLong) }
    }
}
