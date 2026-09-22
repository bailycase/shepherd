import Foundation
import ShepherdCore
import Testing
@testable import shepherd_cli

@Suite("herdr import")
struct HerdrImportTests {
    /// One workspace with a pi pane, a plain shell pane, and a non-pi agent pane, plus fields
    /// Shepherd doesn't read.
    static let herdrJSON = """
    {
      "version": 3,
      "workspaces": [{
        "id": "w1", "custom_name": null, "identity_cwd": "/tmp/proj",
        "tabs": [{
          "layout": "ignored",
          "panes": {
            "1": {"cwd": "/tmp/proj/sub", "agent_session": {"source": "herdr:pi", "agent": "pi", "kind": "path",
                  "value": "/tmp/sessions/2026-08-21T05-01-57-917Z_abc123.jsonl"}},
            "2": {"cwd": "/tmp/proj"},
            "3": {"cwd": "/tmp/proj", "agent_session": {"agent": "claude", "kind": "path", "value": "/x/y_z.jsonl"}},
            "4": {"cwd": "/tmp/proj", "agent_session": {"agent": "pi", "kind": "id", "value": "abc"}}
          }
        }]
      }]
    }
    """

    static func herdr(_ json: String = herdrJSON) throws -> HerdrSession {
        try JSONDecoder().decode(HerdrSession.self, from: Data(json.utf8))
    }

    static func workspace(name: String? = nil, cwd: String, sessions: [String]) -> String {
        let panes = sessions.enumerated().map { i, id in
            #""\#(i)": {"cwd": "\#(cwd)", "agent_session": {"agent": "pi", "kind": "path", "value": "/s/t_\#(id).jsonl"}}"#
        }.joined(separator: ",")
        let custom = name.map { "\"\($0)\"" } ?? "null"
        return #"{"workspaces": [{"custom_name": \#(custom), "identity_cwd": "\#(cwd)", "tabs": [{"panes": {\#(panes)}}]}]}"#
    }

    @Test(arguments: [
        ("/a/2026-08-21T05-01-57-917Z_abc123.jsonl", "abc123"),
        ("/a/prefix_with_underscores_id9.jsonl", "id9"),
        ("/a/notasession.txt", nil),
        ("/a/plain.jsonl", nil),
        ("/a/trailing_.jsonl", nil),
    ] as [(String, String?)])
    func sessionIDIsTheSuffixAfterTheLastUnderscore(path: String, id: String?) {
        #expect(HerdrImport.sessionID(fromPath: path) == id)
    }

    @Test func mergeAddsASpaceAndAnAgentForEachPiSession() throws {
        var state = ShepherdState()
        let summary = HerdrImport.merge(try Self.herdr(), into: &state) { _ in "My task" }
        #expect(summary.spacesAdded == 1 && summary.agentsAdded == 1 && summary.agentsSkipped == 0)
        #expect(state.spaces.map(\.path) == ["/tmp/proj"] && state.spaces[0].name == "proj")
        let agent = try #require(state.agents.first)
        #expect(state.agents.count == 1)
        #expect(agent.piSessionID == "abc123" && agent.name == "My task" && agent.nameIsFinal)
        #expect(agent.spaceID == state.spaces[0].id)
        try state.validate()
    }

    @Test func spacesGetNoLayoutOfTheirOwn() throws {
        var state = ShepherdState()
        _ = HerdrImport.merge(try Self.herdr(), into: &state) { _ in nil }
        #expect(state.tabs.count == state.agents.count)
        let tab = try #require(state.tabs.first)
        let leaf = tab.layout.firstLeaf
        #expect(tab.layout.leaves.count == 1 && leaf.agentID == state.agents[0].id && leaf.cwd == "/tmp/proj/sub")
        #expect(state.agents[0].tabID == tab.id && state.agents[0].paneID == leaf.id)
    }

    @Test func mergingTwiceAddsNothingNew() throws {
        let herdr = try Self.herdr()
        var state = ShepherdState()
        _ = HerdrImport.merge(herdr, into: &state) { _ in nil }
        let before = state
        let second = HerdrImport.merge(herdr, into: &state) { _ in nil }
        #expect(second.spacesAdded == 0 && second.agentsAdded == 0 && second.agentsSkipped == 1)
        #expect(state == before)
        try state.validate()
    }

    @Test func anExistingSpaceAndAgentAreReusedBySessionAndPath() throws {
        let space = Space(name: "mine", path: "/tmp/proj")
        let pane = LeafPane(cwd: "/tmp/proj")
        let tab = Tab(spaceID: space.id, order: 4, layout: .leaf(pane))
        let existing = Agent(name: "already here", spaceID: space.id, tabID: tab.id, paneID: pane.id, piSessionID: "abc123")
        var state = ShepherdState(spaces: [space], tabs: [tab], agents: [existing])
        let summary = HerdrImport.merge(try Self.herdr(Self.workspace(cwd: "/tmp/proj", sessions: ["abc123", "new1"])), into: &state) { _ in nil }
        #expect(summary.spacesAdded == 0 && summary.agentsAdded == 1 && summary.agentsSkipped == 1)
        #expect(state.spaces == [space])
        #expect(state.tabs.last?.order == 5, "imported tabs order after existing ones")
        try state.validate()
    }

    @Test func anImportedAgentWithoutANameGetsAFallbackTitle() throws {
        var state = ShepherdState()
        _ = HerdrImport.merge(try Self.herdr(), into: &state) { _ in nil }
        #expect(state.agents.first?.name == "Imported from herdr")
    }

    @Test func aCustomWorkspaceNameNamesTheSpace() throws {
        var state = ShepherdState()
        _ = HerdrImport.merge(try Self.herdr(Self.workspace(name: "Client work", cwd: "/tmp/x", sessions: ["s1"])), into: &state) { _ in nil }
        #expect(state.spaces.first?.name == "Client work")
    }

    @Test func aTildePathExpandsToHome() throws {
        var state = ShepherdState()
        _ = HerdrImport.merge(try Self.herdr(Self.workspace(cwd: "~/proj", sessions: [])), into: &state) { _ in nil }
        #expect(state.spaces.first?.path == NSHomeDirectory() + "/proj")
    }

    @Test func theNameResolverReceivesTheSessionFilePath() throws {
        var state = ShepherdState()
        var asked: [String] = []
        _ = HerdrImport.merge(try Self.herdr(), into: &state) { asked.append($0); return nil }
        #expect(asked == ["/tmp/sessions/2026-08-21T05-01-57-917Z_abc123.jsonl"])
    }
}

/// `firstUserMessage` reads a pi session JSONL; each case writes one tiny scratch file.
@Suite("herdr import agent names")
struct HerdrAgentNameTests {
    private func name(from lines: [String]) throws -> String? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("herdr-\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return HerdrImport.firstUserMessage(inSessionFile: url)
    }

    @Test func theFirstUserMessageNamesTheAgent() throws {
        #expect(try name(from: [
            #"{"type":"session","id":"abc"}"#,
            #"{"type":"message","message":{"role":"assistant","content":"hello"}}"#,
            #"{"type":"message","message":{"role":"user","content":[{"type":"text","text":"Fix the\nflaky test"}]}}"#,
            #"{"type":"message","message":{"role":"user","content":"later"}}"#,
        ]) == "Fix the flaky test")
    }

    @Test func plainStringContentIsAccepted() throws {
        #expect(try name(from: [#"{"type":"message","message":{"role":"user","content":"  Ship it  "}}"#]) == "Ship it")
    }

    @Test func longMessagesAreTruncatedTo60Characters() throws {
        let long = String(repeating: "a", count: 80)
        #expect(try name(from: [#"{"type":"message","message":{"role":"user","content":"\#(long)"}}"#])
            == String(repeating: "a", count: 60) + "…")
    }

    @Test func aBlankFirstUserMessageGivesNoName() throws {
        #expect(try name(from: [#"{"type":"message","message":{"role":"user","content":"   "}}"#]) == nil)
    }

    @Test func malformedLinesAreSkipped() throws {
        #expect(try name(from: ["not json", #"{"type":"message","message":{"role":"user","content":"ok"}}"#]) == "ok")
    }

    @Test func aMissingFileGivesNoName() {
        #expect(HerdrImport.firstUserMessage(inSessionFile: URL(fileURLWithPath: "/nonexistent/\(UUID()).jsonl")) == nil)
    }
}
