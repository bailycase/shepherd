import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdApp

/// The New thread page's slash menu: the commands this Mac's pi has listed, filtered as a thread's
/// menu filters them, and none for another host.
@Suite("New thread slash commands")
struct NewThreadSlashCommandsTests {
    static let catalog = [
        NativeCommand(name: "review", description: "Review the diff", source: "prompt"),
        NativeCommand(name: "secret", description: "Switched off", source: "extension"),
        NativeCommand(name: "skill:search", description: "Search the web", source: "skill"),
        NativeCommand(name: "goal", description: "Set a goal", source: "extension"),
    ]
    static let local = NewThreadPlace(host: nil, space: SpaceID())

    @Test func aLocalPlaceListsTheCatalogLessWhatAThreadLeavesOut() {
        let all = NewThreadState.slashCommands(catalog: Self.catalog, hidden: [], skills: true, goals: true, place: Self.local)
        #expect(all.map(\.name) == ["review", "secret", "skill:search", "goal"])
        let filtered = NewThreadState.slashCommands(catalog: Self.catalog, hidden: ["secret"], skills: false, goals: false, place: Self.local)
        #expect(filtered.map(\.name) == ["review"])
    }

    @Test func anotherHostOrNoPlaceListsNothingFromThisMac() {
        let remote = NewThreadPlace(host: UUID(), space: SpaceID())
        #expect(NewThreadState.slashCommands(catalog: Self.catalog, hidden: [], skills: true, goals: true, place: remote).isEmpty)
        #expect(NewThreadState.slashCommands(catalog: Self.catalog, hidden: [], skills: true, goals: true, place: nil).isEmpty)
    }
}
