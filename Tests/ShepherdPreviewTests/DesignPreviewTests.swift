import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// The Design tool (Settings ▸ Experiments ▸ Design tool): the Designs page (NavDesigns), New
/// design (DZStart), and a design's canvas beside its chat (DZCanvas), with the sidebar's
/// Designs destination and design rows. Boards are real fixture boards rendered off screen by
/// the renderer and drawn from their snapshots: a capture can't draw a live web view.
@Suite("Design previews", .serialized, .mainActorExclusive, .enabled(if: Preview.enabled && !Preview.liveModel, "set SHEPHERD_PREVIEW_DIR (without SHEPHERD_LIVE_MODEL) to render previews"))
@MainActor
struct DesignPreviewTests {
    /// The main column beside a docked sidebar in the boards' 1440×900 window.
    private static let pageSize = CGSize(width: 1440 - AppLayout.sidebarDefaultWidth, height: 848)
    private static let windowSize = CGSize(width: 1440, height: 900)

    /// A workspace with the Design tool on, two projects, a plain thread, and two designs: the
    /// checkout funnel (three directions and a phone) drawn by a live stub agent, and a phone-first
    /// onboarding design.
    private func designWorkspace() async throws -> (workspace: PreviewWorkspace, checkout: Design, agent: Agent) {
        let workspace = try PreviewWorkspace()
        workspace.settings.designToolEnabled = true
        let vm = workspace.vm
        vm.designNetwork = .none
        vm.designLiveCap = 0
        let web = Space(name: "acme-web", path: workspace.dir.path)
        let app = Space(name: "shepherd", path: workspace.dir.path)
        let (thread, threadTab) = try await workspace.agent("Fix the login redirect", in: web, order: 0, status: .working)
        var (agent, tab) = try await workspace.agent("Checkout funnel dashboard", in: web, order: 1, live: true)
        let checkout = Design(name: "Checkout funnel dashboard", spaceID: web.id, agentID: agent.id, createdAt: 1_000)
        agent.designID = checkout.id
        try await workspace.seed(ShepherdState(spaces: [web, app], tabs: [threadTab, tab], agents: [thread, agent]))
        _ = try await workspace.server.createDesign(checkout)
        try await DesignFixtures.draw(DesignFixtures.checkout, in: checkout.id, on: workspace.server, perRow: 3)
        let onboarding = Design(name: "Onboarding", spaceID: app.id, createdAt: 2_000)
        _ = try await workspace.server.createDesign(onboarding)
        let phone = [DesignFixtures.Board(path: "A-phone.dc.html", title: "A · phone", width: 390, height: 844, accent: "#be123c")]
        try await DesignFixtures.draw(phone, in: onboarding.id, on: workspace.server)
        let server = workspace.server
        try await eventuallyOnMain("the designs to load") { vm.state.designs.count == 2 && vm.state == server.state }
        return (workspace, checkout, agent)
    }

    @Test func designsPage() async throws {
        let (workspace, _, _) = try await designWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        await vm.loadDesignThumbnails()
        try await Preview.render("page-designs", size: Self.pageSize, ready: {
            vm.state.designs.allSatisfy { vm.designRendering.thumbnails.image($0.id) != nil }
        }) {
            DesignsDestination(vm: vm)
        }
    }

    @Test func newDesign() async throws {
        let (workspace, _, _) = try await designWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        vm.openNewDesign()
        #expect(vm.shownDestination == .newDesign)
        try await Preview.render("app-window-new-design", size: Self.windowSize) {
            RootView(vm: vm)
        }
    }

    /// The canvas at its fitted zoom beside the design agent's chat, the first board selected.
    @Test func designScreen() async throws {
        let (workspace, checkout, agent) = try await designWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        vm.selectSidebarRow(.design(checkout.id))
        #expect(vm.selectedAgentID == agent.id)
        #expect(vm.selectedSidebarRow == .design(checkout.id))
        let screen = vm.designScreen(checkout.id)
        screen.select("A.dc.html")
        try await Preview.render("app-window-design", size: Self.windowSize, ready: { screen.isDrawn }) {
            RootView(vm: vm)
        }
    }

    /// The Designs destination selected on its page, with design rows in Recents.
    @Test func appWindowDesigns() async throws {
        let (workspace, _, _) = try await designWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        vm.openDestination(.designs)
        await vm.loadDesignThumbnails()
        try await Preview.render("app-window-designs", size: Self.windowSize, ready: {
            vm.state.designs.allSatisfy { vm.designRendering.thumbnails.image($0.id) != nil }
        }) {
            RootView(vm: vm)
        }
    }

    /// New thread with the Design tool on: "Start a design" is the last suggestion card.
    @Test func newThreadStartADesign() async throws {
        let (workspace, _, _) = try await designWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        vm.openNewThread()
        try await Preview.render("page-new-thread-design", size: Self.pageSize) {
            NewThreadPage(vm: vm, chrome: PageHeaderChrome())
        }
    }
}
