import Foundation
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp

/// Git sharing in the boards' window (GitDesignPublish … GitDesignMergeReview), from the real
/// server and real git against a bare repository on disk: the chip before and after sharing,
/// the share sheet, the panel with a board changed, an incoming commit, the merge dialog and
/// Pull paused, and the Designs page with Open from Git.
extension DesignPreviewTests {
    @Test(arguments: ["share", "changes", "incoming", "conflict", "running", "ready", "paused"])
    func designGit(_ state: String) async throws {
        let (workspace, checkout, agent) = try await designWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        let server = workspace.server
        let config = try #require(ProcessInfo.processInfo.environment["GIT_CONFIG_GLOBAL"])
        _ = try? git(["config", "--file", config, "user.name", "Baily"], in: workspace.dir)
        _ = try? git(["config", "--file", config, "user.email", "baily@example.com"], in: workspace.dir)
        vm.selectSidebarRow(.design(checkout.id))
        let screen = vm.designScreen(checkout.id)
        await screen.refresh()

        let remote = try makeScratchDirectory("remote").appendingPathComponent("checkout-design.git")
        _ = try git(["init", "-q", "--bare", "-b", "main", remote.path], in: remote.deletingLastPathComponent())
        let a = try DesignPath.validate("A.dc.html")
        let phone = try DesignPath.validate("A-phone.dc.html")
        let git = vm.designGit(checkout.id)

        if state == "share" {
            vm.openDesignGitShare(checkout.id)
            vm.designGitShare?.repository = "git@github.com:acme/checkout-design.git"
        } else {
            _ = try await server.shareDesignWithGit(checkout.id, url: remote.path, message: "Add checkout funnel design")
            let base = try await server.designBoard(checkout.id, path: phone).source
            switch state {
            case "changes":
                let source = try await server.designBoard(checkout.id, path: a).source
                _ = try await server.writeDesignBoard(checkout.id, path: a, source: source.replacingOccurrences(of: ">Step 1</div>", with: ">Checkout started · 12,904</div>"),
                                                      baseRevision: nil)
                _ = try await server.writeDesignBoard(checkout.id, path: phone, source: base.replacingOccurrences(of: ">Step 1</div>", with: ">Checkout · 12,904</div>"),
                                                      baseRevision: nil)
                git.message = "Show absolute counts in the checkout funnel"
            default:
                // Sam pushes a change to the phone board from another clone.
                let other = try makeScratchDirectory("other")
                _ = try ShepherdTestSupport.git(["clone", "-q", remote.path, other.appendingPathComponent("c").path], in: other)
                let clone = other.appendingPathComponent("c")
                try Data(base.replacingOccurrences(of: ">Step 1</div>", with: ">Checkout</div>").utf8)
                    .write(to: clone.appendingPathComponent("project/A-phone.dc.html"))
                _ = try ShepherdTestSupport.git(["-c", "user.name=Sam Nguyen", "-c", "user.email=sam@example.com",
                                                 "commit", "-qam", "Clarify phone step labels"], in: clone)
                _ = try ShepherdTestSupport.git(["push", "-q", "origin", "HEAD:main"], in: clone)
                if state != "incoming" {
                    _ = try await server.writeDesignBoard(checkout.id, path: phone, source: base.replacingOccurrences(of: ">Step 1</div>", with: ">Checkout started · 12,904</div>"),
                                                          baseRevision: nil)
                    // "tools:1" in the subject reaches the merge brief: the stub's turn then holds on a tool, so
                    // the running state is what the capture shows.
                    let subject = state == "running" ? "Show absolute counts in the checkout funnel tools:1"
                        : "Show absolute counts in the checkout funnel"
                    _ = try await server.commitDesign(checkout.id, message: subject, push: false)
                    guard case .needsMerge = try await server.pullDesign(checkout.id) else { Issue.record("no merge"); return }
                }
            }
        }
        if state != "share" {
            let fetched = try await server.designGitState(checkout.id, fetch: true)
            git.set(fetched)
        }
        switch state {
        case "changes", "incoming":
            vm.pressDesignGitChip(checkout.id)
            if state == "changes" { vm.selectDesignGitFile(checkout.id, path: "project/A.dc.html") }
        case "conflict":
            vm.designGitMergeDialog = checkout.id
        case "paused":
            // Keep working locally: the dialog closed, the merge waits; the chip and canvas say so.
            break
        case "running":
            await server.setDesignMergeTimeoutForTests(600)
            try await server.resolveDesignMergeWithAgent(checkout.id)
            git.set(try await server.designGitState(checkout.id))
        case "ready":
            let folder = try #require(server.designs.folder(for: checkout.id))
            let copy = folder.appendingPathComponent(DesignGit.mergeCopyName)
            guard let merge = try await server.designGitState(checkout.id)?.merge else { Issue.record("no merge"); return }
            _ = try DesignGit.prepareMergeCopy(folder, merge: merge)
            // Both kept, as the agent would leave it: Sam's label with this Mac's count.
            try Data(try await server.designBoard(checkout.id, path: phone).source
                .replacingOccurrences(of: ">Checkout started · 12,904</div>", with: ">Checkout · 12,904</div>").utf8)
                .write(to: copy.appendingPathComponent("project/A-phone.dc.html"))
            await server.markDesignMergeReadyForTests(checkout.id)
            git.set(try await server.designGitState(checkout.id))
            vm.pressDesignGitChip(checkout.id)
            vm.selectDesignGitFile(checkout.id, path: "project/A-phone.dc.html")
        default: break
        }
        try await Preview.renderMatrix("app-window-design-git-\(state)", size: Self.windowSizeForJump,
                                       scales: state == "changes" ? [1, 1.3] : [1], ready: {
            screen.isDrawn && (state != "changes" || git.preview != nil)
                && (state == "share" || git.state != nil)
                && (state != "running" || (vm.server.rpcThread(forAgent: agent.id)?.piBusy == true && git.state?.merge?.phase == .running))
        }) {
            RootView(vm: vm)
        }
    }

    @Test func designGitOpened() async throws {
        let (workspace, checkout, _) = try await designWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        let server = workspace.server
        let config = try #require(ProcessInfo.processInfo.environment["GIT_CONFIG_GLOBAL"])
        _ = try? git(["config", "--file", config, "user.name", "Baily"], in: workspace.dir)
        _ = try? git(["config", "--file", config, "user.email", "baily@example.com"], in: workspace.dir)
        let remote = try makeScratchDirectory("remote").appendingPathComponent("checkout-design.git")
        _ = try git(["init", "-q", "--bare", "-b", "main", remote.path], in: remote.deletingLastPathComponent())
        _ = try await server.shareDesignWithGit(checkout.id, url: remote.path, message: "Add checkout funnel design")
        // Open from Git, as the coworker presses it: the toast, and a chat whose agent hasn't started.
        vm.openDesignGitOpen()
        let model = try #require(vm.designGitOpen)
        model.repository = remote.path
        vm.runDesignGitOpen(model)
        try await eventuallyOnMain("the clone to open", timeout: .seconds(60)) {
            vm.designGitOpen == nil && vm.state.designs.count == 3
        }
        let opened = try #require(vm.state.designs.first { $0.id != checkout.id && $0.name == checkout.name })
        let screen = vm.designScreen(opened.id)
        try await eventuallyOnMain("the opened design's agent", timeout: .seconds(60)) { vm.design(opened.id)?.agentID != nil }
        await screen.refresh()
        try await Preview.renderMatrix("app-window-design-git-opened", size: Self.windowSizeForJump, scales: [1], ready: {
            screen.isDrawn && vm.designGit(opened.id).state != nil && vm.designGit(opened.id).openedNotice != nil
        }) {
            RootView(vm: vm)
        }
    }

    @Test func designsPageOpenFromGit() async throws {
        let (workspace, _, _) = try await designWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        await vm.loadDesignThumbnails()
        vm.openDesignGitOpen()
        vm.designGitOpen?.repository = "git@github.com:acme/checkout-design.git"
        try await Preview.renderMatrix("page-designs-open-from-git", size: Self.windowSizeForJump, scales: [1], ready: {
            vm.state.designs.allSatisfy { vm.designRendering.thumbnails.image($0.id) != nil }
        }) {
            DesignsDestination(vm: vm).overlay { DesignGitSheetsOverlay(vm: vm) }
        }
    }
}
