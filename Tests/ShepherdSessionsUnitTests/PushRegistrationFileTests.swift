import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestKit

@Suite("Push registration file")
struct PushRegistrationFileTests {
    private static let saved = RemotePushRegistration(id: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA", sendToken: String(repeating: "a", count: 64))
    private static let new = RemotePushRegistration(id: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB", sendToken: String(repeating: "b", count: 64))

    @Test(arguments: ["{\"truncated\":", "{}", "[null]", "{\"version\":2,\"value\":[]}",
                      "[{\"id\":\"not-a-uuid\",\"sendToken\":\"not-a-token\"}]", String(repeating: " ", count: 32_769)])
    func damageRefusesBothMutationsAndPreservesBytes(_ json: String) throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("push-registrations.json")
        let damaged = Data(json.utf8)
        try damaged.write(to: path)
        let store = PushNotifications(file: path, queue: DispatchQueue(label: "test.push"))
        #expect(throws: PushNotifications.Failure.self) { try store.register(Self.new) }
        #expect(try Data(contentsOf: path) == damaged)
        #expect(throws: PushNotifications.Failure.self) { try store.unregister(Self.saved.id) }
        #expect(try Data(contentsOf: path) == damaged)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [path.lastPathComponent])
    }

    @Test func aHealthyFileRewrittenAsUTF16IsDamagedNotRewritten() throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("push-registrations.json")
        try PushNotifications(file: path, queue: DispatchQueue(label: "test.push")).register(Self.saved)
        let utf16 = try #require(String(decoding: Data(contentsOf: path), as: UTF8.self).data(using: .utf16))
        try utf16.write(to: path)
        let store = PushNotifications(file: path, queue: DispatchQueue(label: "test.push"))
        #expect(throws: PushNotifications.Failure.self) { try store.register(Self.new) }
        #expect(throws: PushNotifications.Failure.self) { try store.unregister(Self.saved.id) }
        #expect(try Data(contentsOf: path) == utf16)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [path.lastPathComponent])
    }

    @Test func unreadableEntryIsNotMissingButMovingItAllowsRegistration() throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("push-registrations.json")
        let absent = directory.appendingPathComponent("absent.json")
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: absent)
        let store = PushNotifications(file: path, queue: DispatchQueue(label: "test.push"))
        #expect(throws: PushNotifications.Failure.self) { try store.register(Self.new) }
        #expect(throws: PushNotifications.Failure.self) { try store.unregister(Self.saved.id) }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: path.path) == absent.path)
        let moved = directory.appendingPathComponent("moved.json")
        try FileManager.default.moveItem(at: path, to: moved)
        try store.register(Self.new)
        #expect(try JSONDecoder().decode([RemotePushRegistration].self, from: Data(contentsOf: path)) == [Self.new])
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: moved.path) == absent.path)
    }

    @Test func liveStoreRefusesNewDamageAndUsesRestoredEnvelopeWithoutReplayingRefusedEdit() throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("push-registrations.json")
        let store = PushNotifications(file: path, queue: DispatchQueue(label: "test.push"))
        try store.register(Self.saved)
        let original = try Data(contentsOf: path)
        let damaged = Data("[null]".utf8)
        try damaged.write(to: path)
        #expect(throws: PushNotifications.Failure.self) { try store.unregister(Self.saved.id) }
        #expect(try Data(contentsOf: path) == damaged)
        try (Data("{\"version\":1,\"value\":".utf8) + original + Data("}".utf8)).write(to: path)
        try store.register(Self.new)
        let restored = try JSONDecoder().decode([RemotePushRegistration].self, from: Data(contentsOf: path))
        #expect(Set(restored) == [Self.saved, Self.new])
    }
}
