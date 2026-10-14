import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp
@testable import ShepherdUI

/// Git sharing's controls in a real window with the real model, server and git behind them,
/// pressed the way VoiceOver presses (`ControlPress`; each scenario in its own process): the
/// toolbar chip opens Share with Git, Create commit & push shares into a bare repository; the
/// chip then opens the panel, whose Commit & push sends a board change; Open from Git clones the
/// design into Designs; a pull that needs a merge shows the dialog, whose Keep working locally
/// leaves the design as it was. Nothing is posted to the window.
@Suite("Design Git controls", .integrationTimeLimit)
struct DesignGitControlTests {
    @Test func theChipSharesTheDesignAndThePanelCommitsAndPushesAChange() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.shareThenCommit() }
        }
    }

    @Test func openFromGitClonesTheDesignIntoDesigns() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.openFromGit() }
        }
    }

    @Test func aPullThatNeedsAMergeShowsTheDialogAndKeepWorkingLocallyLeavesTheMergeWaiting() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.mergeDialog() }
        }
    }

    // MARK: Scenarios

    private struct Opened {
        let app: AppHarness
        let vm: ShepherdViewModel
        let window: OffscreenWindow
        let design: Design

        /// The toolbar over the design's canvas with the Git panel, and the sheets over both, as
        /// RootView arranges them.
        @MainActor func chrome() -> OffscreenWindow {
            OffscreenWindow(size: CGSize(width: 1500, height: 1000), dark: true,
                            VStack(spacing: 0) {
                                WorkspaceHeaderView(vm: vm)
                                Color.clear.overlay { DesignGitCanvasLayer(vm: vm, designID: design.id, part: .panel) }
                            }
                            .overlay { DesignGitSheetsOverlay(vm: vm) })
        }
    }

    /// The checkout design on screen, drawn by a live stub agent, with git knowing who commits.
    @MainActor
    private static func open() async throws -> Opened {
        AccessibilityNode.enable()
        let app = try AppHarness()
        app.settings.designToolEnabled = true
        let space = Fixture.space(path: app.dir.path)
        var drawer = try await app.liveAgent("Checkout", in: space, order: 0)
        let design = Design(name: "Checkout funnel dashboard", agentID: drawer.agent.id, createdAt: 1_000)
        drawer.agent.designID = design.id
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [drawer]))
        vm.designNetwork = .none
        _ = try await app.server.createDesign(design)
        try await DesignFixtures.draw(DesignFixtures.checkout, in: design.id, on: app.server, perRow: 3)
        try Self.setIdentity()
        vm.selectAgent(drawer.agent.id)
        let window = OffscreenWindow(size: CGSize(width: 1400, height: 900), dark: true, WorkspaceView(vm: vm))
        let screen = vm.designScreen(design.id)
        try await eventuallyOnMain("the canvas to draw", timeout: .seconds(60)) {
            window.layout()
            return screen.isDrawn && !screen.visibleBoards.isEmpty
        }
        return Opened(app: app, vm: vm, window: window, design: design)
    }

    /// Git's identity, in the scratch global config the test isolation made.
    private static func setIdentity() throws {
        let config = try #require(ProcessInfo.processInfo.environment["GIT_CONFIG_GLOBAL"])
        try git(["config", "--file", config, "user.name", "Baily"], in: URL(fileURLWithPath: NSTemporaryDirectory()))
        try git(["config", "--file", config, "user.email", "baily@example.com"], in: URL(fileURLWithPath: NSTemporaryDirectory()))
    }

    private static func emptyRemote() throws -> URL {
        let dir = try makeScratchDirectory("remote").appendingPathComponent("checkout-design.git", isDirectory: true)
        try git(["init", "-q", "--bare", "-b", "main", dir.path], in: dir.deletingLastPathComponent())
        return dir
    }

    /// Types into the focused field, as the input system inserts it: no key events.
    @MainActor
    private static func type(_ text: String, into window: OffscreenWindow) throws {
        let editor = try #require((window.window.firstResponder as? NSTextView).flatMap { $0.isFieldEditor || $0.isEditable ? $0 : nil })
        editor.insertText(text, replacementRange: NSRange(location: (editor.string as NSString).length, length: 0))
    }

    @MainActor
    static func shareThenCommit() async throws {
        let o = try await open()
        defer { o.app.stop(); o.window.close() }
        let chrome = o.chrome()
        defer { chrome.close() }
        let remote = try emptyRemote()

        // Share with Git: the chip says it, at least 24pt tall, and opens the sheet.
        try await eventuallyOnMain("the chip") { chrome.controls().contains { ($0.label ?? "").hasPrefix("Share with Git") } }
        let chip = try #require(chrome.controls().first { ($0.label ?? "").hasPrefix("Share with Git") })
        #expect(chip.frame.height >= 24)
        try chrome.press(try #require(chip.label))
        try await eventuallyOnMain("the share sheet") { o.vm.designGitShare != nil }
        let sheet = try #require(o.vm.designGitShare)
        #expect(sheet.message == "Add checkout funnel dashboard design")
        // Without a URL the primary is disabled.
        #expect(chrome.controls().first { $0.label == "Create commit & push" }?.isEnabled == false)
        sheet.repository = remote.path
        sheet.message = "Add checkout funnel design"
        try await eventuallyOnMain("the primary to enable") { chrome.controls().first { $0.label == "Create commit & push" }?.isEnabled == true }
        try chrome.press("Create commit & push")
        try await eventuallyOnMain("the sheet to close after the push", timeout: .seconds(60)) { o.vm.designGitShare == nil }
        #expect(try git(["log", "-1", "--format=%s", "main"], in: remote).trimmingCharacters(in: .whitespacesAndNewlines) == "Add checkout funnel design")

        // The chip now reads the branch; a board change makes it "1 change".
        try await eventuallyOnMain("the chip to read up to date") { chrome.controls().contains { ($0.label ?? "").hasPrefix("main · Up to date") } }
        let a = try DesignPath.validate("A.dc.html")
        let source = try await o.app.server.designBoard(o.design.id, path: a).source
        _ = try await o.app.server.writeDesignBoard(o.design.id, path: a, source: source.replacingOccurrences(of: "</x-dc>", with: "<!-- counts --></x-dc>"),
                                                    baseRevision: nil)
        try await eventuallyOnMain("the chip to count the change", timeout: .seconds(30)) {
            chrome.controls().contains { ($0.label ?? "").hasPrefix("main · 1 change") }
        }

        // The panel: the change listed, Commit & push disabled until there's a message.
        try chrome.press(try #require(chrome.controls().first { ($0.label ?? "").hasPrefix("main · 1 change") }?.label))
        try await eventuallyOnMain("the panel") { chrome.element("Git changes for this design") != nil }
        try await eventuallyOnMain("the changed file") { chrome.elements().contains { $0.label?.contains("A.dc.html") == true } }
        let state = o.vm.designGit(o.design.id)
        // Commit waits for a message; written, it enables.
        #expect(chrome.controls().first { $0.label == "Commit & push" }?.isEnabled == false)
        state.message = "Show absolute counts in the checkout funnel"
        try await eventuallyOnMain("Commit & push to enable") { chrome.controls().first { $0.label == "Commit & push" }?.isEnabled == true }
        try chrome.press("Commit & push")
        try await eventuallyOnMain("the commit to reach the remote", timeout: .seconds(60)) {
            (try? git(["log", "-1", "--format=%s", "main"], in: remote).trimmingCharacters(in: .whitespacesAndNewlines))
                == "Show absolute counts in the checkout funnel"
        }
        try await eventuallyOnMain("the chip to read up to date again", timeout: .seconds(30)) {
            chrome.controls().contains { ($0.label ?? "").hasPrefix("main · Up to date") }
        }
        // Close Git changes puts the panel away.
        try chrome.press("Close Git changes")
        try await eventuallyOnMain("the panel to close") { !state.panelOpen }
    }

    @MainActor
    static func openFromGit() async throws {
        let o = try await open()
        defer { o.app.stop(); o.window.close() }
        let remote = try emptyRemote()
        _ = try await o.app.server.shareDesignWithGit(o.design.id, url: remote.path, message: "Add checkout funnel design")

        // The Designs page's Open from Git opens the sheet.
        let page = OffscreenWindow(size: CGSize(width: 1300, height: 900), dark: true,
                                   DesignsDestination(vm: o.vm).overlay { DesignGitSheetsOverlay(vm: o.vm) })
        defer { page.close() }
        try page.press("Open from Git")
        try await eventuallyOnMain("the open sheet") { o.vm.designGitOpen != nil }
        let model = try #require(o.vm.designGitOpen)
        #expect(page.controls().first { $0.label == "Clone & open" }?.isEnabled == false, "nothing to clone yet")
        model.repository = "/nowhere/at/all.git"
        try await eventuallyOnMain("Clone & open to enable") { page.controls().first { $0.label == "Clone & open" }?.isEnabled == true }
        try page.press("Clone & open")
        try await eventuallyOnMain("the error box", timeout: .seconds(60)) { model.error != nil }
        #expect(model.error?.title == "Repository unavailable")
        try await eventuallyOnMain("Retry clone") { page.controls().contains { $0.label == "Retry clone" } }

        model.repository = remote.path
        try page.press("Retry clone")
        try await eventuallyOnMain("the clone to open", timeout: .seconds(60)) { o.vm.designGitOpen == nil }
        #expect(o.vm.state.designs.count == 2)
        let opened = try #require(o.vm.state.designs.first { $0.id != o.design.id })
        #expect(opened.name == "Checkout funnel dashboard" && opened.agentID == nil)
        #expect(o.vm.designGit(opened.id).openedNotice?.hasPrefix("4 boards") == true)
    }

    @MainActor
    static func mergeDialog() async throws {
        let o = try await open()
        defer { o.app.stop(); o.window.close() }
        let chrome = o.chrome()
        defer { chrome.close() }
        let remote = try emptyRemote()
        _ = try await o.app.server.shareDesignWithGit(o.design.id, url: remote.path, message: "Add")
        // Someone else pushes a change to the phone board; this Mac commits its own.
        let other = try makeScratchDirectory("other")
        try git(["clone", "-q", remote.path, other.appendingPathComponent("c").path], in: other)
        let clone = other.appendingPathComponent("c")
        let phone = try DesignPath.validate("A-phone.dc.html")
        let base = try await o.app.server.designBoard(o.design.id, path: phone).source
        try Data(base.replacingOccurrences(of: "</x-dc>", with: "<!-- Sam --></x-dc>").utf8).write(to: clone.appendingPathComponent("project/A-phone.dc.html"))
        try git(["commit", "-qam", "Clarify phone step labels"], in: clone)
        try git(["push", "-q", "origin", "HEAD:main"], in: clone)
        let mine = base.replacingOccurrences(of: "</x-dc>", with: "<!-- me --></x-dc>")
        _ = try await o.app.server.writeDesignBoard(o.design.id, path: phone, source: mine, baseRevision: nil)
        _ = try await o.app.server.commitDesign(o.design.id, message: "Show absolute counts in the checkout funnel", push: false)

        // The panel's Pull (after its fetch) answers the merge: the dialog, and Pull paused on the canvas.
        o.vm.refreshDesignGit(o.design.id, fetch: true)
        try await eventuallyOnMain("the chip", timeout: .seconds(30)) { chrome.controls().contains { ($0.label ?? "").hasPrefix("main · ") } }
        o.vm.pullDesignGit(o.design.id)
        try await eventuallyOnMain("the merge dialog", timeout: .seconds(60)) {
            if let error = o.vm.remoteActionError { Issue.record("pull failed: \(error)"); return true }
            return o.vm.designGitMergeDialog == o.design.id
        }
        try await eventuallyOnMain("the dialog's buttons") { chrome.controls().contains { $0.label == "Keep working locally" } }
        #expect(chrome.elements().contains { $0.label == "Pull needs a merge" })
        #expect(chrome.controls().contains { $0.label == "Resolve with agent" })
        // Keep working locally closes the dialog (the board's close): the merge waits, the chip says Pull paused.
        try chrome.press("Keep working locally")
        try await eventuallyOnMain("the dialog to close") { o.vm.designGitMergeDialog == nil }
        #expect(o.vm.designGit(o.design.id).state?.merge?.phase == .conflict)
        try await eventuallyOnMain("the chip to say the pull is paused") { chrome.controls().contains { ($0.label ?? "").hasPrefix("main · Pull paused") } }
        #expect(try await o.app.server.designBoard(o.design.id, path: phone).source == mine, "Shepherd has not changed your design files")
        // The chip opens the dialog again; Drop merge lets the merge go, both commits kept.
        try chrome.press(try #require(chrome.controls().first { ($0.label ?? "").hasPrefix("main · Pull paused") }?.label))
        try await eventuallyOnMain("the dialog again") { o.vm.designGitMergeDialog == o.design.id }
        try await eventuallyOnMain("Drop merge") { chrome.controls().contains { $0.label == "Drop merge" } }
        try chrome.press("Drop merge")
        try await eventuallyOnMain("the merge to go", timeout: .seconds(30)) { o.vm.designGit(o.design.id).state?.merge == nil }
        #expect(try await o.app.server.designBoard(o.design.id, path: phone).source == mine)
    }
}
