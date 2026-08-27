import Foundation
import Testing
import ShepherdCore
@testable import ShepherdProtocol

@Suite("Remote wire protocol")
struct RemoteProtocolTests {
    @Test func requestsRoundTrip() throws {
        let requests: [RemoteRequest] = [
            .hello(id: 1, token: "deadbeef", clientName: "macbook", protocolVersion: 1),
            .hello(id: 2, token: "", clientName: "Baily's MacBook \"Pro\"", protocolVersion: 99),
            .stateFetch(id: 3),
            .attach(id: 4, sessionID: SessionID(), cols: 120, rows: 40, viewportGeneration: 2),
            .detach(sessionID: SessionID()),
            .input(sessionID: SessionID(), data: Data([0x1B, 0x5B, 0x41])),
            .resize(sessionID: SessionID(), cols: 80, rows: 24, viewportGeneration: 3),
            .paste(id: 12, sessionID: SessionID(), text: "multi\nline \"prompt\"", submit: true),
            .paste(id: 13, sessionID: SessionID(), text: "", submit: false),
            .openPane(id: 14, agentID: AgentID(), axis: .vertical, relativeTo: PaneID()),
            .closePane(id: 15, agentID: AgentID(), paneID: PaneID()),
            .resizePaneSplit(
                id: 16,
                agentID: AgentID(),
                split: .split(
                    axis: .vertical,
                    ratio: 0.5,
                    first: .leaf(LeafPane(cwd: "/tmp")),
                    second: .leaf(LeafPane(cwd: "/tmp"))
                ),
                ratio: 0.7
            ),
            .listDir(id: 8, path: ""),
            .listModels(id: 10),
            .listDir(id: 9, path: "/Users/demo/Developer"),
            .addSpace(id: 5, path: "/Users/demo/Developer/project"),
            .createAgent(
                id: 6,
                spaceID: SpaceID(),
                cwd: "/tmp/checkout",
                model: "anthropic/claude-4",
                thinking: .high,
                initialPrompt: "fix the \"thing\"\nplease"
            ),
            .createAgent(id: 7, spaceID: SpaceID(), cwd: nil, model: nil, thinking: nil, initialPrompt: nil),
        ]
        for request in requests {
            let line = try NDJSON.encode(request)
            #expect(line.last == 0x0A)
            let decoded = try NDJSON.decode(RemoteRequest.self, from: line.dropLast())
            #expect(decoded == request)
        }
    }

    @Test func repliesRoundTrip() throws {
        let space = Space(name: "demo", path: "/tmp/demo")
        let pane = LeafPane(cwd: "/tmp/demo")
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        let agent = Agent(name: "pi-1", spaceID: space.id, tabID: tab.id, paneID: pane.id)
        let state = ShepherdState(spaces: [space], tabs: [tab], agents: [agent])

        let replies: [RemoteReply] = [
            .helloOk(id: 1, protocolVersion: 1, capabilities: RemoteProtocol.capabilities),
            .ok(id: 12),
            .paneOpened(id: 14, paneID: PaneID()),
            .error(id: 2, code: "unauthorized", message: "bad token"),
            .state(id: 3, state: state),
            .state(id: 4, state: ShepherdState()),
            .stateChanged(state: state),
            .attached(id: 5, attachment: RemoteAttachment(sessionID: SessionID(), cols: 80, rows: 24, viewportGeneration: 2)),
            .output(sessionID: SessionID(), data: Data("screen bytes \u{1B}[31m".utf8)),
            .sessionExited(sessionID: SessionID(), code: 0),
            .sessionExited(sessionID: SessionID(), code: nil),
            .dirListing(id: 8, path: "/Users/demo", parent: "/Users", dirs: ["Developer", "Documents"]),
            .dirListing(id: 9, path: "/", parent: nil, dirs: []),
            .models(id: 10, models: ["anthropic/claude-4", "openai/gpt-5"], defaultModel: "anthropic/claude-4"),
            .models(id: 11, models: [], defaultModel: nil),
            .spaceAdded(id: 6, spaceID: SpaceID()),
            .agentCreated(id: 7, agentID: AgentID()),
        ]
        for reply in replies {
            let line = try NDJSON.encode(reply)
            #expect(line.last == 0x0A)
            let decoded = try NDJSON.decode(RemoteReply.self, from: line.dropLast())
            #expect(decoded == reply)
        }
    }

    @Test func composedInputIsOneBracketedPasteAndOptionalReturn() {
        #expect(
            RemoteProtocol.composedInput(text: "one\ntwo", submit: true)
                == Data("\u{1B}[200~one\ntwo\u{1B}[201~\r".utf8)
        )
        #expect(
            RemoteProtocol.composedInput(text: "draft", submit: false)
                == Data("\u{1B}[200~draft\u{1B}[201~".utf8)
        )
    }

    @Test func legacyHelloWithoutCapabilitiesStillDecodes() throws {
        let wire = Data(#"{"type":"helloOk","id":1,"protocolVersion":1}"#.utf8)
        #expect(
            try NDJSON.decode(RemoteReply.self, from: wire)
                == .helloOk(id: 1, protocolVersion: 1, capabilities: [])
        )
    }

    /// The `type` discriminator is the wire contract: a host must be able to
    /// reject unknown request kinds cleanly rather than misdecoding them.
    @Test func unknownKindFailsToDecode() {
        let wire = Data(#"{"type":"launchMissiles","id":1}"#.utf8)
        #expect(throws: (any Error).self) {
            try NDJSON.decode(RemoteRequest.self, from: wire)
        }
    }
}
