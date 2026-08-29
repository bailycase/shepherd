import Foundation
import Testing
@testable import ShepherdCore

@Suite("Legacy state JSON")
struct LegacyJSONTests {
    @Test func removedModelKeysDecodeAndDisappearOnWrite() throws {
        let legacy = """
        {
          "spaces": [
            {
              "id": "space-1",
              "name": "legacy",
              "path": "/tmp/legacy",
              "gitBranch": "main",
              "colorHex": "#7D8FB3",
              "lastActiveTabID": "tab-1"
            }
          ],
          "tabs": [
            {
              "id": "tab-1",
              "spaceID": "space-1",
              "name": "old tab title",
              "order": 0,
              "layout": {
                "type": "leaf",
                "pane": {
                  "id": "pane-1",
                  "cwd": "/tmp/legacy",
                  "agentID": "agent-1"
                }
              }
            }
          ],
          "agents": [
            {
              "id": "agent-1",
              "name": "worker",
              "spaceID": "space-1",
              "tabID": "tab-1",
              "paneID": "pane-1",
              "status": "idle",
              "model": null,
              "thinkingLevel": "medium",
              "sessionMode": "tui",
              "piSessionID": "conversation-1"
            }
          ],
          "subagents": []
        }
        """

        let state = try JSONDecoder().decode(ShepherdState.self, from: Data(legacy.utf8))
        #expect(state.spaces == [Space(id: SpaceID(rawValue: "space-1"), name: "legacy", path: "/tmp/legacy")])
        #expect(state.tabs == [Tab(
            id: TabID(rawValue: "tab-1"),
            spaceID: SpaceID(rawValue: "space-1"),
            order: 0,
            layout: .leaf(LeafPane(
                id: PaneID(rawValue: "pane-1"),
                cwd: "/tmp/legacy",
                agentID: AgentID(rawValue: "agent-1")
            ))
        )])
        #expect(state.agents.first?.nameIsFinal == true)
        #expect(state.agents.first?.effectivePiSessionID == "conversation-1")
        // Pre-worktree files carry no branch or path; the agent is not a worktree.
        #expect(state.agents.first?.worktreeBranch == nil)
        #expect(state.agents.first?.worktreePath == nil)

        let encodedObject = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any]
        )
        let encodedSpace = try #require(
            (encodedObject["spaces"] as? [[String: Any]])?.first
        )
        let encodedTab = try #require(
            (encodedObject["tabs"] as? [[String: Any]])?.first
        )
        let encodedAgent = try #require(
            (encodedObject["agents"] as? [[String: Any]])?.first
        )
        #expect(encodedSpace["gitBranch"] == nil)
        #expect(encodedSpace["colorHex"] == nil)
        #expect(encodedSpace["lastActiveTabID"] == nil)
        #expect(encodedTab["name"] == nil)
        #expect(encodedAgent["sessionMode"] == nil)
    }

    /// A worktree agent's branch survives the encode/decode round trip.
    @Test func worktreeBranchRoundTrips() throws {
        let agent = Agent(
            name: "calm-stone-3831",
            spaceID: SpaceID(rawValue: "space-1"),
            tabID: TabID(rawValue: "tab-1"),
            nameIsFinal: true,
            worktreeBranch: "worktree/calm-stone-3831",
            worktreePath: "/tmp/calm-stone-3831"
        )
        let decoded = try JSONDecoder().decode(Agent.self, from: JSONEncoder().encode(agent))
        #expect(decoded == agent)
        #expect(decoded.worktreeBranch == "worktree/calm-stone-3831")
        #expect(decoded.worktreePath == "/tmp/calm-stone-3831")
    }
}
