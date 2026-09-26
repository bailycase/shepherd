import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI
import SwiftUI
@testable import ShepherdApp

/// Realistic large fixtures for the long-list measurements (`ListPerformanceReport`,
/// `ListPerformanceTests`): a fleet's sidebar, a busy palette, a big diff, a long thread, a long
/// subagent transcript, a crowd of subagents, and a deep directory.
@MainActor
enum ListFixtures {
    // MARK: Sidebar

    /// `agents` agents spread over `spaces` spaces, in every status.
    static func fleet(in dir: URL, spaces: Int = 40, agents: Int = 300) -> ShepherdState {
        let spaceList = (0..<spaces).map { index in
            Fixture.space(String(format: "project-%02d", index), path: dir.appendingPathComponent("p\(index)").path)
        }
        let fixtures = (0..<agents).map { index in
            let status: AgentStatus = index % 7 == 0 ? .blocked : index % 5 == 0 ? .working : index % 3 == 0 ? .done : .idle
            return Fixture.agent("Fix part \(index) of the login flow", in: spaceList[index % spaces], order: index / spaces, status: status)
        }
        return Fixture.state(spaces: spaceList, agents: fixtures)
    }

    // MARK: Palette

    /// `count` items: 30 commands, then agents. The query "fix" matches every agent.
    static func paletteItems(_ count: Int = 1000) -> [PaletteItem] {
        let commands = (0..<30).map { index in
            PaletteItem(id: "c\(index)", kind: .action("c\(index)"), section: .commands, title: "Command \(index)",
                        shortcut: index < 9 ? "⇧⌘\(index + 1)" : nil, icon: "bolt")
        }
        let agents = (0..<(count - 30)).map { index in
            PaletteItem(id: "a\(index)", kind: .action("a\(index)"), section: .agents, title: "Fix part \(index) of the login flow",
                        subtitle: "in project-\(index % 40) · running", icon: "circle")
        }
        return commands + agents
    }

    // MARK: Review

    /// A modified file of `lines` lines, alternating added and unchanged so no run folds.
    static func diffFile(_ name: String, lines: Int) -> DiffFile {
        let diffLines = (0..<lines).map { index in
            DiffLine(kind: index.isMultiple(of: 2) ? .added : .context,
                     text: "let value\(index) = compute(\(index), from: source[\(index)]) // keeps the line long enough to truncate",
                     oldLine: index.isMultiple(of: 2) ? nil : index, newLine: index + 1, id: index)
        }
        return DiffFile(oldPath: name, newPath: name, displayPath: name, isNew: false, isDeleted: false, isRenamed: false, isBinary: false,
                        hunks: [DiffHunk(header: "@@ -1,\(lines) +1,\(lines) @@", lines: diffLines)])
    }

    /// Source lines dense with tokens for each grammar, so highlighting colors most of a line.
    private static let swiftSource = [
        "    func refresh(_ agent: AgentID, force: Bool = false) async throws -> [NativeThreadMessage] {",
        "        guard let store = stores[agent], !store.isLoading || force else { return [] } // nothing to do",
        "        let snapshot = try await client.request(.snapshot(agentID: agent, since: store.revision, limit: 250))",
        "        store.apply(snapshot, animated: snapshot.revision > store.revision + 1, reason: \"refresh \\(agent)\")",
        "        return snapshot.messages.filter { $0.role == \"assistant\" && !$0.blocks.isEmpty }",
        "    }",
        "    private static let defaultTimeout: Duration = .seconds(30) // generous: a cold pi takes a while",
        "    @MainActor var visibleRows: [SidebarRow] { rows.filter { !collapsed.contains($0.spaceID) }.prefix(400).map(\\.self) }",
    ]
    private static let typeScriptSource = [
        "export async function sendPaneRequest(socket: Socket, request: PaneRequest, timeoutMs = 30_000): Promise<PaneReply> {",
        "  const id = `${process.env.SHEPHERD_AGENT_ID ?? \"unknown\"}-${Date.now()}-${Math.random().toString(36).slice(2)}`;",
        "  if (!socket.writable) throw new Error(\"socket closed before the request \" + request.kind + \" was sent\");",
        "  const reply = await waitFor<PaneReply>(socket, (line) => JSON.parse(line).id === id, { timeoutMs, unref: true });",
        "  return reply.ok ? { ...reply, panes: reply.panes.map((pane) => ({ ...pane, focused: pane.id === request.target })) } : reply;",
        "}",
        "// keeps the extension inert without its environment: no socket, no timers, nothing that holds pi open",
        "const enabled: boolean = typeof process.env.SHEPHERD_SOCKET === \"string\" && process.env.SHEPHERD_EXT_PANES === \"1\";",
    ]
    private static let goSource = [
        "func (r *Repository) ListAgents(ctx context.Context, spaceID string, limit int32) ([]domain.Agent, error) {",
        "\trows, err := r.q.ListAgentsBySpace(ctx, db.ListAgentsBySpaceParams{SpaceID: spaceID, Limit: limit, Offset: 0})",
        "\tif err != nil {",
        "\t\treturn nil, fmt.Errorf(\"list agents in space %q (limit %d): %w\", spaceID, limit, err)",
        "\t}",
        "\tagents := make([]domain.Agent, 0, len(rows)) // one allocation for the whole page",
        "\tfor _, row := range rows { agents = append(agents, domain.Agent{ID: row.ID, Name: row.Name, Status: row.Status}) }",
        "\treturn agents, nil",
    ]

    /// Lines of `source` cycled from `offset`, numbered from `start`: runs of context, removals,
    /// and additions short enough that nothing folds, as in a real edit.
    private static func mixedHunk(_ source: [String], start: Int, count: Int, id: inout Int) -> DiffHunk {
        let pattern: [DiffLine.Kind] = [.context, .context, .context, .removed, .removed, .added, .added, .added, .added,
                                        .context, .context, .added, .added, .added, .added, .added, .added, .removed, .context, .context]
        var old = start, new = start
        var lines: [DiffLine] = []
        for index in 0..<count {
            let kind = pattern[index % pattern.count]
            let text = source[(index + start) % source.count]
            lines.append(DiffLine(kind: kind, text: text, oldLine: kind == .added ? nil : old, newLine: kind == .removed ? nil : new, id: id))
            id += 1
            if kind != .added { old += 1 }
            if kind != .removed { new += 1 }
        }
        return DiffHunk(header: "@@ -\(start),\(count) +\(start),\(count) @@ func context\(start)()", lines: lines)
    }

    /// A big, realistic review: 40 changed Swift, TypeScript, and Go files of three mixed hunks
    /// each, a new 3,000-line Swift file, and a file of very long lines (a minified bundle).
    static func realisticReview() -> [DiffFile] {
        let sources: [(ext: String, lines: [String])] = [("swift", swiftSource), ("ts", typeScriptSource), ("go", goSource)]
        var files: [DiffFile] = []
        for index in 0..<38 {
            let source = sources[index % sources.count]
            var id = 0
            let hunks = [10, 120, 400].map { mixedHunk(source.lines, start: $0 + index, count: 40, id: &id) }
            let path = "Sources/Feature\(index % 7)/Component\(index).\(source.ext)"
            files.append(DiffFile(oldPath: path, newPath: path, displayPath: path, isNew: false, isDeleted: false, isRenamed: false,
                                  isBinary: false, hunks: hunks))
        }
        let big = (0..<3000).map { DiffLine(kind: .added, text: swiftSource[$0 % swiftSource.count], oldLine: nil, newLine: $0 + 1, id: $0) }
        files.insert(DiffFile(oldPath: nil, newPath: "Sources/Generated/Catalog.swift", displayPath: "Sources/Generated/Catalog.swift",
                              isNew: true, isDeleted: false, isRenamed: false, isBinary: false,
                              hunks: [DiffHunk(header: "@@ -0,0 +1,3000 @@", lines: big)]), at: 5)
        let long = typeScriptSource.joined(separator: " ")
        var id = 0
        files.insert(DiffFile(oldPath: "web/dist/bundle.js", newPath: "web/dist/bundle.js", displayPath: "web/dist/bundle.js",
                              isNew: false, isDeleted: false, isRenamed: false, isBinary: false,
                              hunks: [mixedHunk([long, long + long], start: 1, count: 60, id: &id)]), at: 12)
        return files
    }

    /// Six inline comments over the realistic review's first files.
    static func realisticComments(_ files: [DiffFile]) -> [ReviewComment] {
        [0, 1, 2, 3, 4, 6].map { index in
            let file = files[index]
            let line = file.hunks[0].lines[5]
            return ReviewComment(fileID: file.id, lineID: line.id, filePath: file.displayPath, lineNumber: line.newLine ?? line.oldLine ?? 0,
                                 marker: line.kind.reviewMarker, content: line.text,
                                 text: "This allocates on every call; hoist it out of the loop and reuse the buffer across refreshes.")
        }
    }

    static func reviewModel(_ files: [DiffFile]) -> ReviewPaneModel {
        let session = ReviewSession(agentID: AgentID(), paneID: PaneID(), cwd: "/tmp/repo", reference: nil, files: files)
        return ReviewPaneModel(session: session, actions: ReviewActions(setPullRequest: { _ in }, requestChanges: {}, commit: {}, close: {}))
    }

    // MARK: Thread

    static let answer = Array(repeating: "Answer paragraph with enough words to wrap a line or two in the column, like a real reply.",
                              count: 3).joined(separator: "\n\n")

    static func message(_ id: String, _ role: String, _ text: String) -> NativeThreadMessage {
        NativeThreadMessage(entryID: id, role: role, blocks: [NativeThreadBlock(kind: .text, text: text)], truncated: false)
    }

    /// `turns` user turns, each answered.
    static func conversation(turns: Int, prefix: String = "m") -> [NativeThreadMessage] {
        (0..<(turns * 2)).map { index in
            index.isMultiple(of: 2) ? message("\(prefix)\(index)", "user", "Question \(index / 2)")
                : message("\(prefix)\(index)", "assistant", "Turn \(index / 2). " + answer)
        }
    }

    static func threadSnapshot(turns: Int, running: Bool = false, revision: UInt64 = 1,
                               provisional: [NativeThreadMessage] = []) -> NativeThreadSnapshot {
        NativeThreadSnapshot(piSessionID: "s", generation: "g", revision: revision, running: running,
                             supportedActions: ["send", "abort", "subagents"], dialogsSupported: true, dialogs: [],
                             messages: conversation(turns: turns), provisional: provisional, clipped: false)
    }

    // MARK: Subagents

    static func run(_ index: Int, state: String = "running") -> ChildRun {
        ChildRun(runID: "run-\(index)", label: "worker \(index)", state: state, startedAt: 1_000 + Double(index), role: "worker \(index)",
                 turns: 3 + index % 9, tokens: 40_000, lastActivity: ChildActivity(tool: "edit", preview: "Sources/File\(index).swift", at: 1_000),
                 task: "Restyle part \(index) of the thread.")
    }

    // MARK: Directories

    static func directories(_ count: Int = 2000) -> [String] {
        (0..<count).map { String(format: "module-%04d", $0) }
    }
}
