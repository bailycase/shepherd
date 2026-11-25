import Foundation
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// GXExpanded: a turn with its thinking and its work opened, and the changes card after Undo, drawn from the real producers
/// (`nativeTurnPresentation` over pi's messages, the thread's own rows).
extension ThreadPreviewTests {
    @Test func threadExpanded() async throws {
        let t = ActivityThreads.now - 140_000
        let messages = [
            ActivityThreads.user("u1", "Remove the visible speaker labels, and make tool rows show something useful, like a command or a path, instead of just “complete”.", at: t),
            ActivityThreads.assistant("a1", "I’ll finish removing the speaker labels and make tool rows show a useful command or path preview.",
                                      thinking: "The labels come from `ThreadSpeaker` in the desktop view. The tool rows read `status` and fall back to “complete”. I can derive a preview from the arguments instead.",
                                      seconds: 4, at: t + 1_000),
            ActivityThreads.tool("r1", "read", ["path": "DesktopNativeThreadView.swift"], output: "import SwiftUI", start: t + 5_000, end: t + 5_300),
            ActivityThreads.edit("e1", "DesktopNativeThreadView.swift", added: 58, removed: 41, at: t + 20_000),
            ActivityThreads.edit("e2", "ToolRowPreview.swift", added: 31, removed: 0, at: t + 40_000),
            ActivityThreads.tool("b1", "bash", ["command": "swift build"], output: "Build complete!", start: t + 50_000, end: t + 98_000),
            ActivityThreads.tool("b2", "bash", ["command": "swift test --filter NativePresentation"],
                                 output: "Test run with 1 test in 1 suite passed after 0.1 seconds.", start: t + 100_000, end: t + 132_000),
            ActivityThreads.assistant("a2", "The focused regression test and the Mac dev build pass. Slash commands and image drops are next.", at: t + 135_000),
        ]
        let turn = nativeTurnPresentation(Array(messages.dropFirst()), live: false)
        let size = CGSize(width: 1000, height: 640)
        try await Preview.render("thread-expanded", size: size) {
            VStack(alignment: .leading, spacing: AppLayout.turnItemSpacing) {
                UserTurn(bubbles: [UserTurn.Bubble(text: "Remove the visible speaker labels, and make tool rows show something useful, like a command or a path, instead of just “complete”.",
                                                   images: 0, caption: nil, pending: false)])
                ForEach(turn.items) { item in
                    switch item {
                    case .thinking(_, _, let blocks, let seconds, let live, _):
                        ThinkingRow(seconds: seconds, blocks: blocks, live: live, isExpanded: true) {}
                    case .prose(_, _, let prose):
                        Prose(prose: prose)
                    case .activity(_, let bursts):
                        ForEach(bursts) { burst in ActivityLineView(burst: burst, review: { _ in }, expanded: true) }
                    default:
                        EmptyView()
                    }
                }
                SHChangesCard(title: "Undid the agent’s edits to 7 files", added: 129, removed: 59, files: [], phase: .undone, onRedo: {})
                Spacer(minLength: 0)
            }
            .frame(width: 720, alignment: .leading)
            .padding(32)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color.sh.bgWindow)
        }
    }
}
