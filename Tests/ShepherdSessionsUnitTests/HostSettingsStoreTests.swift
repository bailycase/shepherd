import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdTestKit
import Testing
@testable import ShepherdSessions

/// The host's stored preferences: every field has a default a file may leave out, and the store keeps one file.
@Suite("Host settings store")
struct HostSettingsStoreTests {
    private func file() throws -> URL { try makeScratchDirectory("hps").appendingPathComponent("host-preferences.json") }

    /// Mirror lists each stored field; a field added without a default does not build (`Agents()`), and one that is not
    /// encoded would not survive the file.
    @Test func everyFieldHasADefaultAndIsInTheFile() throws {
        var agents = StoredHostPreferences.Agents()
        agents.compactAtPercent = 60 // nil is left out of the file
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(agents)) as? [String: Any])
        let fields = Mirror(reflecting: agents).children.compactMap(\.label)
        #expect(Set(fields) == Set(encoded.keys), "a stored field the file does not carry")
        #expect(try StoredHostPreferences.decode(Data("{}".utf8)) == StoredHostPreferences())
    }

    @Test func aFileThatLacksAFieldReadsItAsItsDefault() throws {
        let older = #"{"version":1,"agents":{"defaultThinking":"high","futureField":1}}"#
        let read = try StoredHostPreferences.decode(Data(older.utf8))
        #expect(read.agents.defaultThinking == .high)
        #expect(read.agents.codemode && read.agents.defaultModel.isEmpty && read.agents.compactAtPercent == nil)
    }

    @Test func aChangeIsKeptInTheFileAndAReopenedStoreReadsIt() throws {
        let url = try file()
        let store = HostSettingsStore(file: url)
        #expect(store.preferences == StoredHostPreferences(), "no file is the defaults")
        store.update { $0.agents.defaultModel = "acme/model-a"; $0.agents.compactAtPercent = 80 }
        let reopened = HostSettingsStore(file: url).preferences
        #expect(reopened.agents.defaultModel == "acme/model-a" && reopened.agents.compactAtPercent == 80)
        store.update { $0.agents.compactAtPercent = nil }
        #expect(HostSettingsStore(file: url).preferences.agents.compactAtPercent == nil)
    }

    @Test func aFileThatCannotBeReadStartsFromDefaultsAndIsWrittenOver() throws {
        let url = try file()
        try Data(#"{"agents":{"codemode":"yes"}}"#.utf8).write(to: url)
        let store = HostSettingsStore(file: url)
        #expect(store.preferences == StoredHostPreferences())
        store.update { $0.agents.codemode = false }
        #expect(HostSettingsStore(file: url).preferences.agents.codemode == false)
    }
}
