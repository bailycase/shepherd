import Foundation
import ShepherdCore
import ShepherdProtocol

/// One screen the harness can render: `FIXTURE_SCREEN=<name>`. The hosts it serves, and where
/// the app goes once they are connected. Each track lists its screens in its own file
/// (`Fixtures/<Track>Fixtures.swift`); `FixtureCatalog.all` gathers them.
struct FixtureScreen {
    var name: String
    var hosts: [FixtureHostData] = FixtureData.hosts()
    /// Opened in order through `MobileNavigator.open` once every online host is connected.
    var routes: [MobileRoute] = []
    /// Shown modally after the routes.
    var presented: MobileRoute? = nil
    /// The iPhone tab to show.
    var tab: MobileNavigator.Tab = .home
    /// Anything else to set up before the screenshot (a draft, an expanded row).
    var prepare: (@MainActor (MobileApp) async -> Void)? = nil
}

/// A host the harness serves: its state, each agent's thread, and answers for anything else.
struct FixtureHostData {
    static let token = "fixture-only"

    var id: UUID
    var name: String
    var state: ShepherdState
    var threads: [AgentID: NativeThreadSnapshot] = [:]
    /// Offline hosts refuse connections, so the app shows them unreachable.
    var online = true
    var models: [String] = ["anthropic/claude-opus", "anthropic/claude-sonnet", "openai/gpt-5"]
    /// The models `listModels` says take no thinking level; nil answers as an older host does.
    var withoutThinking: [String]? = nil
    /// Answers a request before the default handler (agent queries, transcripts, …); nil
    /// falls through.
    var reply: (@Sendable (RemoteRequest) -> RemoteReply?)? = nil
}

/// Fixed ids and builders every track's fixtures share, so screens agree with each other.
enum FixtureData {
    static let studio = UUID(uuidString: "5E0A0000-0000-4000-8000-000000000001")!
    static let buildBox = UUID(uuidString: "5E0A0000-0000-4000-8000-000000000002")!
    static let laptop = UUID(uuidString: "5E0A0000-0000-4000-8000-000000000003")!

    static let shepherdSpace = Space(id: SpaceID(rawValue: "space-shepherd"), name: "Shepherd", path: "/Users/dev/Shepherd")
    static let horizonSpace = Space(id: SpaceID(rawValue: "space-horizon"), name: "horizon", path: "/Users/dev/horizon")

    static let preview = AgentID(rawValue: "agent-preview")
    static let extensions = AgentID(rawValue: "agent-extensions")
    static let deletion = AgentID(rawValue: "agent-deletion")
    static let dock = AgentID(rawValue: "agent-dock")
    static let buffer = AgentID(rawValue: "agent-buffer")
    static let nightly = AgentID(rawValue: "agent-nightly")

    static func ref(_ agent: AgentID, on host: UUID = studio) -> AgentRef { AgentRef(host: host, agent: agent) }

    /// Two hosts online (this Mac and a build box) and one laptop offline.
    static func hosts() -> [FixtureHostData] {
        [
            FixtureHostData(id: studio, name: "Studio", state: ShepherdState(spaces: [shepherdSpace, horizonSpace], agents: [
                agent(preview, "Investigate SwiftUI live preview", .idle),
                agent(extensions, "Plan shepherd extensions", .working),
                agent(dock, "Dock review pane", .blocked),
                agent(deletion, "Fix remote subagent deletion", .done, space: horizonSpace),
            ], automations: [Automation(name: "Merge PR #24 after CI", prompt: "watch CI", cwd: "/Users/dev/Shepherd", enabled: false)]),
            threads: [preview: thread(), extensions: runningThread(), dock: questionThread()]),
            FixtureHostData(id: buildBox, name: "build-01", state: ShepherdState(spaces: [shepherdSpace], agents: [
                agent(buffer, "Fix terminal output buffer", .idle),
            ]), threads: [buffer: thread()]),
            FixtureHostData(id: laptop, name: "MacBook Air", state: ShepherdState(), online: false),
        ]
    }

    static func agent(_ id: AgentID, _ name: String, _ status: AgentStatus, space: Space = shepherdSpace) -> Agent {
        Agent(id: id, name: name, spaceID: space.id, tabID: TabID(rawValue: "tab-" + id.rawValue), status: status, nameIsFinal: true)
    }

    /// 2:41 PM on a fixed day, in milliseconds.
    static let start: Double = 1_758_570_060_000

    static func user(_ id: String, _ text: String, at offset: Double = 0) -> NativeThreadMessage {
        NativeThreadMessage(entryID: id, role: "user", blocks: [NativeThreadBlock(kind: .text, text: text)], timestamp: start + offset)
    }

    static func assistant(_ id: String, _ text: String, thinking: String? = nil, seconds: Double? = nil, at offset: Double = 0,
                          status: String? = nil) -> NativeThreadMessage {
        var blocks: [NativeThreadBlock] = []
        if let thinking { blocks.append(NativeThreadBlock(kind: .thinking, text: thinking)) }
        if !text.isEmpty { blocks.append(NativeThreadBlock(kind: .text, text: text)) }
        return NativeThreadMessage(entryID: id, role: "assistant", blocks: blocks, status: status, timestamp: start + offset,
                                   thinkingSeconds: seconds)
    }

    static func tool(_ id: String, _ name: String, args: String, output: String = "", error: Bool = false, status: String = "complete",
                     at offset: Double = 0) -> NativeThreadMessage {
        NativeThreadMessage(entryID: id, role: "toolResult", blocks: output.isEmpty ? [] : [NativeThreadBlock(kind: .text, text: output)],
                            toolName: name, toolCallID: "call-" + id, argumentsText: args, status: status, isError: error,
                            timestamp: start + offset, startedAt: start + offset - 2_000)
    }

    static func snapshot(_ messages: [NativeThreadMessage], running: Bool = false, dialogs: [NativeThreadDialog] = [],
                         subagents: [NativeSubagent]? = nil) -> NativeThreadSnapshot {
        NativeThreadSnapshot(piSessionID: "fixture-session", generation: "fixture-generation", revision: 1, running: running,
                             model: "anthropic/claude-opus", thinking: "medium",
                             supportedActions: ["send", "abort", "answer", "queue", "subagents"], dialogsSupported: true,
                             dialogs: dialogs, messages: messages, provisional: [], clipped: false, runtime: "rpc",
                             subagents: subagents)
    }

    /// The MobileThread board: a finished turn with thinking, edits, a test run and the changes card.
    static func thread() -> NativeThreadSnapshot {
        snapshot([
            user("m1", "Remove the visible speaker labels, and make tool rows show something useful instead of just \"complete\"."),
            assistant("m2", "I'll finish removing the speaker labels and make tool rows show a useful command or path preview.",
                      thinking: "The labels live in two views; the tool rows need a preview line.", seconds: 4, at: 4_000),
            tool("m3", "read", args: #"{"path":"Sources/ShepherdApp/DesktopNativeThreadView.swift"}"#, output: "import SwiftUI", at: 20_000),
            tool("m4", "edit", args: #"{"path":"Sources/ShepherdApp/DesktopNativeThreadView.swift","oldText":"a\nb\nc","newText":"x"}"#,
                 output: "Edited", at: 60_000),
            tool("m5", "edit", args: #"{"path":"App/iOS/ThreadView.swift","oldText":"a\nb\nc\nd","newText":""}"#, output: "Edited", at: 70_000),
            tool("m6", "bash", args: #"{"command":"swift test --filter ThreadRows"}"#,
                 output: "✔ Test run with 1 test in 1 suite passed after 0.2 seconds.", at: 150_000),
            assistant("m7", "Removed the visible speaker labels and the desktop gutter. User-message fills still distinguish the conversation.\n\nFocused regression test and Mac Dev build passed.",
                      at: 192_000),
        ])
    }

    /// A turn still running: a live command, started a couple of minutes before launch so its
    /// clock reads like the board's.
    static func runningThread() -> NativeThreadSnapshot {
        let started = Date().timeIntervalSince1970 * 1000 - start - 130_000
        return snapshot([
            user("r1", "Plan the shepherd extensions and build the first one.", at: started),
            assistant("r2", "Reading the extension points first.", at: started + 3_000),
            tool("r3", "bash", args: #"{"command":"swift build"}"#, output: "Compiling ShepherdCore\nCompiling ShepherdProtocol",
                 status: "running", at: started + 9_000),
        ], running: true)
    }

    /// A question waiting on the user.
    static func questionThread() -> NativeThreadSnapshot {
        snapshot([
            user("q1", "Dock the review pane beside the thread."),
            assistant("q2", "Two layouts work. Which should I build?", at: 5_000),
        ], running: true, dialogs: [NativeThreadDialog(id: "d1", kind: .select, title: "Where should review dock?",
                                                       options: ["Beside the thread", "Over the thread", "In its own window"])])
    }
}

/// Every screen, by track. A track edits only its own file's list.
enum FixtureCatalog {
    static var all: [FixtureScreen] {
        home + thread + newThread + subagents + review + commit + search + settings + automations + windows + terminal
    }

    static func screen(named name: String) -> FixtureScreen? {
        all.first { $0.name == name }
    }
}
