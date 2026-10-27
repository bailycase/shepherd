import AppKit
import Testing
@testable import ShepherdApp

/// The Markdown source editor behind Settings ▸ Instructions and the subagent form.
@Suite("Instructions editor")
@MainActor
struct InstructionsEditorTests {
    /// Writing Tools' "compose" affordance for an empty view is a child window that outlived
    /// the editor and floated over every later Settings page; the editor opts out.
    @Test func writingToolsStayOff() {
        for (project, plain) in [(false, false), (true, false), (true, true)] {
            let view = InstructionsEditor.makeTextView(project: project, plain: plain)
            #expect(view.writingToolsBehavior == .none)
            #expect(!view.isRichText)
        }
    }
}
