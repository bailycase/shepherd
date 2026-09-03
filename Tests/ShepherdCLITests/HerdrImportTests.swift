import Foundation
import ShepherdCore
import Testing

@testable import shepherd_cli

@Suite struct HerdrImportTests {
    let herdrJSON = """
    {
      "version": 3,
      "workspaces": [
        {
          "id": "w1",
          "custom_name": null,
          "identity_cwd": "/tmp/proj",
          "tabs": [
            {
              "panes": {
                "1": {
                  "cwd": "/tmp/proj",
                  "agent_session": {
                    "source": "herdr:pi",
                    "agent": "pi",
                    "kind": "path",
                    "value": "/tmp/sessions/2026-08-21T05-01-57-917Z_abc123.jsonl"
                  }
                },
                "2": { "cwd": "/tmp/proj" }
              }
            }
          ]
        }
      ]
    }
    """

    @Test func sessionIDParsing() {
        #expect(HerdrImport.sessionID(fromPath: "/a/2026-08-21T05-01-57-917Z_abc123.jsonl") == "abc123")
        #expect(HerdrImport.sessionID(fromPath: "/a/notasession.txt") == nil)
    }

    @Test func mergeCreatesSpaceShellAndAgent() throws {
        let herdr = try JSONDecoder().decode(HerdrSession.self, from: Data(herdrJSON.utf8))
        var state = ShepherdState()
        let summary = HerdrImport.merge(herdr, into: &state) { _ in "My task" }

        #expect(summary.spacesAdded == 1)
        #expect(summary.agentsAdded == 1)
        #expect(state.spaces.count == 1)
        #expect(state.spaces[0].path == "/tmp/proj")
        // One shell workspace + one agent tab.
        #expect(state.tabs.count == 2)
        #expect(state.agents.count == 1)
        #expect(state.agents[0].piSessionID == "abc123")
        #expect(state.agents[0].name == "My task")
        #expect(state.agents[0].nameIsFinal)
        try state.validate()
    }

    @Test func mergeIsIdempotent() throws {
        let herdr = try JSONDecoder().decode(HerdrSession.self, from: Data(herdrJSON.utf8))
        var state = ShepherdState()
        _ = HerdrImport.merge(herdr, into: &state) { _ in nil }
        let second = HerdrImport.merge(herdr, into: &state) { _ in nil }

        #expect(second.spacesAdded == 0)
        #expect(second.agentsAdded == 0)
        #expect(second.agentsSkipped == 1)
        #expect(state.agents.count == 1)
        try state.validate()
    }
}
