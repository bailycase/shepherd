import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdRemote

/// The iPhone's Shepherd location in Files: identifiers that survive a round trip, names Files can hold, and where a
/// phone's edit goes when the Mac's file moved on.
@Suite("Files location")
struct FilesLocationTests {
    static let host = UUID(uuidString: "6F1C2B9A-0000-4000-8000-000000000001")!
    static let agent = AgentID(rawValue: "0b4e7c2a-1111-4222-8333-444455556666")

    @Test(arguments: [
        FilesLocation.root,
        .host(host),
        .thread(host: host, agent: agent),
        .entry(host: host, agent: agent, path: "README.md"),
        .entry(host: host, agent: agent, path: "Sources/App Intents/Open: thread.swift"),
    ])
    func identifiersRoundTrip(_ location: FilesLocation) {
        #expect(FilesLocation(identifier: location.identifier) == location)
    }

    @Test func refusesIdentifiersItDidNotMake() {
        for identifier in ["", "h/not-a-uuid", "t/\(Self.host.uuidString)", "t/\(Self.host.uuidString)/", "f/\(Self.host.uuidString)/a/",
                           "x/\(Self.host.uuidString)", "NSFileProviderRootContainerItemIdentifier"] {
            #expect(FilesLocation(identifier: identifier) == nil, "\(identifier)")
        }
    }

    @Test func parentsWalkUpToTheRoot() {
        let file = FilesLocation.entry(host: Self.host, agent: Self.agent, path: "Sources/App/Main.swift")
        #expect(file.parent == .entry(host: Self.host, agent: Self.agent, path: "Sources/App"))
        #expect(FilesLocation.entry(host: Self.host, agent: Self.agent, path: "README.md").parent == .thread(host: Self.host, agent: Self.agent))
        #expect(FilesLocation.thread(host: Self.host, agent: Self.agent).parent == .host(Self.host))
        #expect(FilesLocation.host(Self.host).parent == .root)
        #expect(FilesLocation.thread(host: Self.host, agent: Self.agent).child("docs") == .entry(host: Self.host, agent: Self.agent, path: "docs"))
        #expect(FilesLocation.host(Self.host).child("docs") == nil)
    }

    @Test func siblingNamesAreFileNamesAndNeverRepeat() {
        #expect(FilesNames.unique(["Fix login", "fix login", "API / auth", "  ", "Fix login"])
                == ["Fix login", "fix login 2", "API - auth", "Untitled", "Fix login 3"])
    }

    @Test func aConflictCopyTakesAFreeNameBesideTheFile() {
        #expect(FilesNames.conflictCopy(of: "README.md", device: "iPhone", taken: ["README.md"]) == "README (iPhone).md")
        #expect(FilesNames.conflictCopy(of: "README.md", device: "iPhone", taken: ["readme (iphone).md"]) == "README (iPhone 2).md")
        #expect(FilesNames.conflictCopy(of: "Makefile", device: "iPad", taken: []) == "Makefile (iPad)")
    }

    @Test func threadsMovedToAnotherMacAreNotShown() {
        var moved = FleetTests.agent("gone", .idle)
        moved.movedTo = MovedTo(hostID: UUID(), hostName: "Studio", at: 0, moveID: UUID())
        let shown = FilesNames.threads([FleetTests.agent("web", .idle), moved, FleetTests.agent("web", .working)])
        #expect(shown.map(\.name) == ["Web", "Web 2"])
    }

    @Test func aFileVersionMovesWithItsSizeOrTime() {
        let entry = ThreadFileEntry(name: "a.md", kind: .file, size: 9, modified: 1_700_000_000.5)
        var later = entry
        later.modified = 1_700_000_001
        var grown = entry
        grown.size = 10
        #expect(entry.filesVersion != later.filesVersion)
        #expect(entry.filesVersion != grown.filesVersion)
        #expect(entry.filesVersion == ThreadFileEntry(name: "a.md", kind: .file, size: 9, modified: 1_700_000_000.5).filesVersion)
    }
}
