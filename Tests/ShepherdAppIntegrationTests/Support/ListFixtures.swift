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
