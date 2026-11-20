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
        let worktrees = StoredHostPreferences.Worktrees()
        let worktreesEncoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(worktrees)) as? [String: Any])
        #expect(Set(Mirror(reflecting: worktrees).children.compactMap(\.label)) == Set(worktreesEncoded.keys), "a Worktrees field the file does not carry")
        let experiments = StoredHostPreferences.Experiments()
        let experimentsEncoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(experiments)) as? [String: Any])
        #expect(Set(Mirror(reflecting: experiments).children.compactMap(\.label)) == Set(experimentsEncoded.keys), "an Experiments field the file does not carry")
        var fleet = StoredHostPreferences.Fleet()
        fleet.autoDispatch = true // nil is left out of the file
        let fleetEncoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(fleet)) as? [String: Any])
        #expect(Set(Mirror(reflecting: fleet).children.compactMap(\.label)) == Set(fleetEncoded.keys), "a Fleet field the file does not carry")
        let groups = Mirror(reflecting: StoredHostPreferences()).children.compactMap(\.label)
        #expect(Set(groups) == ["version", "agents", "worktrees", "fleet", "experiments"], "a group with no check above")
        #expect(try StoredHostPreferences.decode(Data("{}".utf8)) == StoredHostPreferences())
    }

    @Test func aFileThatLacksAFieldReadsItAsItsDefault() throws {
        let older = #"{"version":1,"agents":{"defaultThinking":"high","futureField":1}}"#
        let read = try StoredHostPreferences.decode(Data(older.utf8))
        #expect(read.agents.defaultThinking == .high)
        #expect(read.agents.codemode && read.agents.defaultModel.isEmpty && read.agents.compactAtPercent == nil)
    }

    @Test func aFileFromBeforeWorktreesMovedReadsThemAsDefaults() throws {
        let read = try StoredHostPreferences.decode(Data(#"{"version":1,"agents":{"codemode":false}}"#.utf8))
        #expect(read.worktrees == StoredHostPreferences.Worktrees() && !read.agents.codemode)
        let partial = try StoredHostPreferences.decode(Data(#"{"worktrees":{"closeOnMerge":true}}"#.utf8)).worktrees
        #expect(partial.closeOnMerge && partial.baseMode == .fresh && partial.fetchBeforeCreate && partial.generatePRDescription && partial.deleteAction == .ask)
    }

    @Test func aFileFromBeforeExperimentsMovedReadsThemAsDefaults() throws {
        let read = try StoredHostPreferences.decode(Data(#"{"version":1,"worktrees":{"closeOnMerge":true}}"#.utf8))
        #expect(read.experiments == StoredHostPreferences.Experiments() && read.worktrees.closeOnMerge)
        let partial = try StoredHostPreferences.decode(Data(#"{"experiments":{"designTool":true}}"#.utf8)).experiments
        #expect(partial.designTool && !partial.goals && !partial.projects && !partial.computerUse)
    }

    @Test func aFileFromBeforeFleetMovedReadsItAsDefaults() throws {
        let read = try StoredHostPreferences.decode(Data(#"{"version":1,"worktrees":{"closeOnMerge":true}}"#.utf8))
        #expect(read.fleet == StoredHostPreferences.Fleet() && read.worktrees.closeOnMerge)
        #expect(read.fleet.threadCap == HostSettings.fleetThreadCapDefault && read.fleet.batteryCountsHalf && read.fleet.autoDispatch == nil)
        let partial = try StoredHostPreferences.decode(Data(#"{"fleet":{"threadsCanSend":true,"weights":{"fleet.weight.x":"prefer"}}}"#.utf8)).fleet
        #expect(partial.threadsCanSend && partial.weights == ["fleet.weight.x": .prefer] && partial.threadCap == HostSettings.fleetThreadCapDefault
                && partial.uncommitted == .sendThem && partial.snapshotExcludes.isEmpty && partial.checkIgnores.isEmpty)
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

    /// A damaged file whose old keys were all at their defaults: nothing differs from the defaults, and the file is still repaired.
    @Test func aDamagedFileIsRepairedEvenWhenNothingChanged() throws {
        let url = try file()
        try Data("not json".utf8).write(to: url)
        let store = HostSettingsStore(file: url)
        store.update { $0 = StoredHostPreferences() }
        #expect(try StoredHostPreferences.decode(Data(contentsOf: url)) == StoredHostPreferences())
    }

    /// A write that fails is not remembered as done: the next update tries again, changed or not.
    @Test func aFailedWriteIsRetriedAtTheNextUpdate() throws {
        let folder = try makeScratchDirectory("hps")
        let url = folder.appendingPathComponent("later").appendingPathComponent("host-preferences.json")
        let store = HostSettingsStore(file: url)
        store.update { $0.agents.codemode = false } // the folder is not there: the write fails
        #expect(!FileManager.default.fileExists(atPath: url.path))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        store.update { _ in }
        #expect(try StoredHostPreferences.decode(Data(contentsOf: url)).agents.codemode == false)
    }
}
