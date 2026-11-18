import Foundation
import ShepherdProtocol
import ShepherdSessions
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp
@testable import ShepherdUI

/// The changes card's file viewer (OutsideFileE) from the real producers: a scratch repository whose README a commit
/// changed, read through `FileViewerLoader.disk` and `GitDiff.fileChange` into `FileViewerState`, drawn by `SHFileViewer`
/// in File and in Diff.
@Suite("File viewer previews", .mainActorExclusive,
       .enabled(if: Preview.enabled && !Preview.liveModel, "set SHEPHERD_PREVIEW_DIR (without SHEPHERD_LIVE_MODEL) to render previews"))
@MainActor
struct FileViewerPreviewTests {
    static let before = """
        # toolkit

        Skills and checks loaded into every coding agent.

        ## Usage

        | Skill | When |
        | --- | --- |
        | /skill:debug | a bug, reproduced first |
        | /skill:plan | a design decision before code |
        | /skill:ship | branch, commit and PR |

        ## Growth loop

        Run correct when something went wrong.

        ## Skills

        - debug
        - plan
        - correct
        - ship

        """

    static let after = """
        # toolkit

        Skills and checks loaded into every coding agent.

        ## Usage

        | Skill | When |
        | --- | --- |
        | /skill:debug | a bug, reproduced first |
        | /skill:plan | a design decision before code |
        | /skill:retro | look back at a thread, or a week of threads |
        | /skill:ship | branch, commit and PR |

        ## Growth loop

        Run retro after a long run, or once a week.
        It reports at most three items and changes nothing;
        approved fixes go through correct.
        Its log lives in LOG.md.

        ## Skills

        - debug
        - plan
        - correct
        - retro
        - ship

        """

    @Test(arguments: [SHFileViewer.Mode.file, .diff])
    func readme(_ mode: SHFileViewer.Mode) async throws {
        let repo = try makeScratchRepo(files: ["README.md": Self.before, "skills/retro/SKILL.md": "# Retro\n"])
        defer { try? FileManager.default.removeItem(at: repo) }
        let readme = repo.appendingPathComponent("README.md").path
        try Self.after.write(toFile: readme, atomically: true, encoding: .utf8)
        _ = try git(["commit", "-qam", "Add the retro skill"], in: repo)
        let state = FileViewerState(paths: [repo.appendingPathComponent("skills/retro/SKILL.md").path, readme], index: 1,
                                    loader: FileViewerLoader(read: FileViewerLoader.disk, diff: { path in
                                        await Task.detached { GitDiff.fileChange(path: path) }.value
                                            .map { .ready($0.file, source: FileViewerLoader.source($0)) } ?? .none("No diff to show.")
                                    }))
        defer { state.close() }
        state.mode = mode
        try await eventuallyOnMain("the README and its diff") {
            if case .loading = state.content { return false }
            return state.stat != nil
        }
        try await Preview.renderMatrix("file-viewer-\(mode == .file ? "file" : "diff")", size: CGSize(width: 1440, height: 900),
                                       scales: [1]) {
            Sheet(state: state)
        }
    }

    /// The sheet as `FileViewerOverlay` draws it, reading the state in its own body.
    struct Sheet: View {
        let state: FileViewerState

        var body: some View {
            ZStack {
                Color.sh.bgWindow
                SHFileViewer(directory: "~/Developer/toolkit/", name: "README.md", stat: state.stat, position: state.position,
                             mode: .constant(state.mode), content: state.content, source: state.source,
                             previous: { state.previous() }, next: nil, openInEditor: {}, close: {})
            }
        }
    }
}
