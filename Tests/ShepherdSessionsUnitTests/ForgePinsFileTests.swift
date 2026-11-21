import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdTestKit
@testable import ShepherdSessions

/// `forge-pins.json`: a missing file is no pins; a damaged one is never read as none and never
/// changed, while the rest of Issues & PRs works without pins.
@Suite("Forge pins file")
struct ForgePinsFileTests {
    private static let issue = ForgeItemRef(kind: .issue, repo: "acme/web", number: 12)
    private static let other = ForgeItemRef(kind: .pullRequest, repo: ForgeFixtures.repo, number: 31)

    /// What a pre-damage build's writer wrote for one pin (`JSONEncoder` on `PinsFile`, unchanged
    /// since `c7cde3c9a`); the same bytes as the c-state golden's `forge-pins` row.
    private static let writtenByNightly = #"{"pins":[{"pinnedAt":12,"ref":{"kind":"issue","number":12,"repo":"acme/web"},"title":"Fix the sample"}]}"#

    private static let damage: [(String, Data)] = [
        ("not UTF-8", Data([0xFF, 0xFE, 0x00, 0x7B])),
        ("not JSON", Data(#"{"truncated":"#.utf8)),
        ("empty", Data()),
        ("an array", Data("[]".utf8)),
        ("no pins key", Data("{}".utf8)),
        ("pins null", Data(#"{"pins":null}"#.utf8)),
        ("pins an object", Data(#"{"pins":{}}"#.utf8)),
        ("a null pin", Data(#"{"pins":[null]}"#.utf8)),
        ("a null ref", Data(#"{"pins":[{"ref":null,"title":"t"}]}"#.utf8)),
        ("no ref", Data(#"{"pins":[{"title":"t"}]}"#.utf8)),
        ("a ref without its number", Data(#"{"pins":[{"ref":{"kind":"issue","repo":"acme/web"}}]}"#.utf8)),
        ("an unknown kind", Data(#"{"pins":[{"ref":{"kind":"discussion","repo":"acme/web","number":1}}]}"#.utf8)),
        ("an envelope of another version", Data(#"{"version":2,"value":{"pins":[]}}"#.utf8)),
    ]

    private struct Fixture {
        let directory: URL
        let url: URL
        let service: ForgeService
        let seen = Locked<[ForgeCommand]>([])

        init() throws {
            directory = try makeScratchDirectory("forge-pins")
            url = directory.appendingPathComponent("forge-pins.json")
            let seen = seen
            service = ForgeService(pinsURL: url, runner: { command in
                seen.withValue { $0.append(command) }
                let (output, status, errors) = ForgeFixtures.answer(command.arguments)
                return ForgeOutput(output: Data(output.utf8), errors: errors, status: status)
            })
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
        var siblings: [String] { ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted() }
    }

    @Test func aMissingFileIsNoPinsAndPinningCreatesIt() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        #expect(try fixture.service.loadPins().isEmpty)
        _ = try fixture.service.setPinned(Self.issue, title: "t", pinned: true)
        #expect(try fixture.service.loadPins().map(\.ref) == [Self.issue])
    }

    @Test(arguments: damage)
    func damageIsNeverNoPinsAndRefusesEveryChange(_ kind: String, _ bytes: Data) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try bytes.write(to: fixture.url)
        #expect(throws: ForgeService.PinsDamaged.self, "\(kind)") { try fixture.service.loadPins() }
        #expect(throws: ForgeService.PinsDamaged.self) { try fixture.service.setPinned(Self.issue, title: "t", pinned: true) }
        #expect(throws: ForgeService.PinsDamaged.self) { try fixture.service.setPinned(Self.issue, title: "", pinned: false) }
        // Over the wire, pinning and unpinning say why and leave the bytes alone.
        for pinned in [true, false] {
            let result = await fixture.service.answer(.setPinned(ref: Self.issue, title: "t", pinned: pinned), context: ForgeContext())
            guard case .failure(let error) = result else { Issue.record("\(kind): a change was accepted"); return }
            #expect(error.message.contains(fixture.url.path) && error.message.contains("move or delete"))
        }
        #expect(try Data(contentsOf: fixture.url) == bytes)
        #expect(fixture.siblings == ["forge-pins.json"])
    }

    @Test func aDirectoryOrADanglingLinkIsDamageToo() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.url, withIntermediateDirectories: false)
        #expect(throws: ForgeService.PinsDamaged.self) { try fixture.service.setPinned(Self.issue, title: "t", pinned: true) }
        try FileManager.default.removeItem(at: fixture.url)
        try FileManager.default.createSymbolicLink(at: fixture.url, withDestinationURL: fixture.directory.appendingPathComponent("absent.json"))
        #expect(throws: ForgeService.PinsDamaged.self) { try fixture.service.setPinned(Self.issue, title: "t", pinned: true) }
        #expect(fixture.siblings == ["forge-pins.json"])
    }

    @Test func theSidebarAndEverythingElseWorkWithoutPins() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("{broken".utf8).write(to: fixture.url)
        let context = ForgeServiceTests.context
        guard case .sidebar(let sidebar) = try ForgeServiceTests.value(await fixture.service.answer(.sidebar, context: context)) else {
            Issue.record("no sidebar"); return
        }
        #expect(sidebar.pins.isEmpty && sidebar.needsYou == 3)
        #expect(sidebar.pinsProblem?.contains(fixture.url.path) == true)
        guard case .list(let list) = try ForgeServiceTests.value(
            await fixture.service.answer(.list(kind: .pullRequest, repo: ForgeFixtures.repo, sections: nil), context: context)) else {
            Issue.record("no list"); return
        }
        #expect(list.section(.authored)?.pullRequests.map(\.ref.number) == [31, 30])
        guard case .pullRequest(let detail) = try ForgeServiceTests.value(
            await fixture.service.answer(.pullRequest(ref: Self.other), context: context)) else {
            Issue.record("no pull request"); return
        }
        #expect(detail.summary.ref == Self.other)
        guard case .issue(let issue) = try ForgeServiceTests.value(
            await fixture.service.answer(.issue(ref: ForgeItemRef(kind: .issue, repo: ForgeFixtures.repo, number: 34)), context: context)) else {
            Issue.record("no issue"); return
        }
        #expect(issue.summary.ref.number == 34)
        #expect(try Data(contentsOf: fixture.url) == Data("{broken".utf8))
    }

    @Test(arguments: ["delete", "repair"])
    func fixingTheFileClearsTheProblemWithoutARestart(_ fix: String) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("[null]".utf8).write(to: fixture.url)
        func problem() async throws -> String? {
            guard case .sidebar(let sidebar) = try ForgeServiceTests.value(await fixture.service.answer(.sidebar, context: ForgeServiceTests.context)) else {
                return "no sidebar"
            }
            return sidebar.pinsProblem
        }
        #expect(try await problem() != nil)
        if fix == "delete" {
            try FileManager.default.removeItem(at: fixture.url)
        } else {
            try Data(Self.writtenByNightly.utf8).write(to: fixture.url)
        }
        #expect(try await problem() == nil)
        _ = try fixture.service.setPinned(Self.other, title: "t", pinned: true)
        #expect(try fixture.service.loadPins().map(\.ref) == (fix == "delete" ? [Self.other] : [Self.other, Self.issue]))
    }

    @Test func whatNightlysWriterProducesLoadsAndTheFormatIsUnchanged() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data(Self.writtenByNightly.utf8).write(to: fixture.url)
        let pins = try fixture.service.loadPins()
        #expect(pins.map(\.ref) == [Self.issue] && pins.map(\.title) == ["Fix the sample"])
        #expect(pins.map(\.pinnedAt) == [Date(timeIntervalSinceReferenceDate: 12)])
        // This build's own write reads back as the same JSON an older build reads.
        _ = try fixture.service.setPinned(Self.other, title: "Add \"refund\" events", pinned: true)
        let written = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.url)) as? [String: Any])
        #expect(Set(written.keys) == ["pins"])
        let rows = try #require(written["pins"] as? [[String: Any]])
        #expect(rows.count == 2 && rows.allSatisfy { Set($0.keys) == ["ref", "title", "pinnedAt"] })
        #expect(rows[1]["title"] as? String == "Fix the sample" && rows[1]["pinnedAt"] as? Double == 12)
        #expect(try JSONDecoder().decode([String: [ForgePin]].self, from: Data(contentsOf: fixture.url))["pins"]?.map(\.ref) == [Self.other, Self.issue])
    }

    @Test func fieldsANewerBuildAddsAreTolerated() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data(#"{"pins":[{"ref":{"kind":"issue","number":12,"repo":"acme/web"},"extra":true}],"later":1}"#.utf8).write(to: fixture.url)
        #expect(try fixture.service.loadPins().map(\.ref) == [Self.issue])
    }
}
