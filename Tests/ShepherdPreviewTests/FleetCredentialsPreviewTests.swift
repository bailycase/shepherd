import AppKit
import Foundation
import ShepherdUI
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp

/// What slice 2c changes on screen, in light and dark: the Sign-in page and an MCP server's sign-in
/// once Fleet is on (the sign-ins are the same on every Mac). Fixture data only: see `PreviewTests`.
@Suite("Fleet credentials previews", .serialized, .mainActorExclusive, .enabled(if: Preview.enabled && !Preview.liveModel, "set SHEPHERD_PREVIEW_DIR (without SHEPHERD_LIVE_MODEL)"))
@MainActor
struct FleetCredentialsPreviewTests {
    @Test func signInPageInAFleet() async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        workspace.vm.settingsSection = .piSignIn
        workspace.vm.showSettings = true
        try await Preview.renderMatrix("fleet-sign-in", size: CGSize(width: 1180, height: 900), ready: { true }) {
            RootView(vm: workspace.vm)
        }
    }

    @Test func anMCPServersSignInIsSharedAcrossTheFleet() async throws {
        let row = MCPServerRowModel(name: "linear", kind: .remote, endpoint: "https://mcp.linear.app/mcp", status: .connected,
                                    signIn: .account("Signed in"), tools: 21)
        let detail = MCPServerDetailModel(
            signIn: .signedIn(account: nil, scopes: [], note: "OAuth · kept fresh by pi · shared across the fleet"),
            toolNames: ["list_issues", "create_issue", "update_issue", "get_issue"], toolCount: 21, direct: false,
            searchCost: "~200 tok", directCost: "~3,900 tok", transport: "Streamable HTTP",
            hosts: [.init(name: "This Mac", detail: "connected", mark: .done)])
        try await Preview.renderMatrix("fleet-mcp-sign-in", size: CGSize(width: 820, height: 330)) {
            VStack(spacing: 0) {
                MCPServerRow(row, open: true, first: true, actions: .init(toggle: { _ in }, open: {}, signIn: {}))
                MCPServerDetail(detail, actions: .none)
            }
            .frame(width: 820, height: 330, alignment: .top)
            .background(Color.sh.bgWindow)
        }
    }
}
