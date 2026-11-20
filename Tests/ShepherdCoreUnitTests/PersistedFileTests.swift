import Foundation
import Testing
import ShepherdCore

/// The `{version, value}` envelope is recognized by its `value` key, so an extra key never makes
/// it read as a bare file, where a missing field defaults (for hook settings, every hook back on).
@Suite("Persisted file envelope")
struct PersistedFileTests {
    struct Settings: Decodable, Equatable {
        var off: [String]
        init(from decoder: Decoder) throws {
            off = try decoder.container(keyedBy: Key.self).decodeIfPresent([String].self, forKey: .off) ?? []
        }
        enum Key: String, CodingKey { case off }
    }

    private func load(_ json: String) throws -> PersistedFile<Settings> {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("persisted-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("file.json")
        try Data(json.utf8).write(to: url)
        return PersistedFile<Settings>.load(from: url)
    }

    private func off(_ json: String) throws -> [String]? {
        if case .loaded(let value) = try load(json) { return value.off }
        return nil
    }

    @Test func bothShapesLoadAndAnEnvelopeToleratesExtraKeys() throws {
        #expect(try off(#"{"version":1,"off":["h"]}"#) == ["h"])
        #expect(try off(#"{"version":1,"value":{"off":["h"]}}"#) == ["h"])
        #expect(try off(#"{"version":1,"value":{"off":["h"]},"written":"later"}"#) == ["h"])
        #expect(try off(#"{"extra":1,"value":{"off":["h"]},"version":1}"#) == ["h"])
    }

    @Test func anEnvelopeShapedFileNeverDefaultsToAllOn() throws {
        for json in [
            #"{"value":{"off":["h"]}}"#, #"{"value":{"off":["h"]},"extra":1}"#, // no version
            #"{"version":2,"value":{"off":["h"]},"extra":1}"#, #"{"version":null,"value":{"off":["h"]}}"#,
            #"{"version":"1","value":{"off":["h"]}}"#, #"{"version":1,"value":null}"#, #"{"version":1,"value":"off"}"#,
        ] {
            guard case .damaged = try load(json) else { Issue.record("expected damage: \(json)"); continue }
        }
    }

    @Test func recoveryReadsTheEnvelopeTheSameWay() throws {
        let envelope = Data(#"{"version":1,"value":{"spaces":[]},"extra":1}"#.utf8)
        #expect((try PersistedFile<Settings>.jsonObject(in: envelope))["spaces"] != nil)
        #expect(throws: (any Error).self) { try PersistedFile<Settings>.jsonObject(in: Data(#"{"value":{"spaces":[]}}"#.utf8)) }
        #expect(throws: (any Error).self) { try PersistedFile<Settings>.jsonObject(in: Data(#"{"version":2,"value":{},"extra":1}"#.utf8)) }
    }
}
