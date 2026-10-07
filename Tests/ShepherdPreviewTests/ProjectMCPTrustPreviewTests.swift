import Foundation
import SwiftUI
import Testing
import ShepherdProtocol
import ShepherdTestSupport
import ShepherdUI
@testable import ShepherdApp

@Suite("Project MCP approval previews", .mainActorExclusive)
@MainActor
struct ProjectMCPTrustPreviewTests {
    @Test func everyApprovalAndCredentialStateRendersFromProjectRequests() async throws {
        let world = try await ProjectsPreviewWorld(detail: true)
        defer { world.stop() }
        let row = try #require(world.vm.projects.rows.first { $0.host.id == "local" })
        var trusted: Bool? = false
        var signed: [String] = []
        var failure: String?
        let model = ProjectsModel { host, request in
            if case .mcp(_, _, .credentials) = request {
                return .mcp(.init(signedIn: signed, message: failure, projectTrusted: trusted))
            }
            return try await world.local.server.projects.request(request, state: world.local.server.state)
        }
        world.vm.madeProjects = model
        world.vm.settingsSection = .projects; world.vm.showSettings = true
        await model.load([row.host])
        await model.open(row)
        await model.navigate(.category(.mcp))
        try await model.saveMCP([.init(name: "issues", json: ["url": .string("https://issues.example.invalid/mcp"), "exposure": .string("deferred")])], replacing: Set(model.mcp.entries.map(\.name)))
        func render(_ name: String, narrow: Bool = false, query: String = "") async throws {
            let size = CGSize(width: narrow ? 740 : 1040, height: 900)
            try await Preview.renderMatrix("project-mcp-trust-" + name, size: size) {
                ProjectMCPSettings(model: model, initiallyExpanded: "issues", initialQuery: query).padding(NW.Space.xxl)
                    .frame(width: size.width, height: size.height).background(Color.nw.bgWindow)
            }
            if ["blocked-credentials-saved", "approved-credentials-saved"].contains(name) {
                try await Preview.renderMatrix("project-mcp-trust-projects-page-" + name, size: CGSize(width: 1440, height: 1000)) {
                    SettingsView(vm: world.vm).frame(width: 1440, height: 1000)
                }
            }
        }
        try await render("blocked-no-credentials")
        signed = ["issues"]; await model.refreshMCPCredentials()
        try await render("blocked-credentials-saved")
        try await render("blocked-narrow", narrow: true)
        try await render("filtered", query: "no-match")
        model.draft += " "
        try await render("unsaved")
        await model.navigate(.file(try #require(model.selectedFile))); await model.discard()
        let project = try #require(model.selected)
        try await Preview.renderMatrix("project-mcp-trust-confirmation", size: CGSize(width: 600, height: 500)) {
            ProjectMCPTrustConfirmation(model: model, project: project) {}
        }
        let displayPath = model.selected?.project.displayPath, hostName = model.selected?.host.name
        model.selected?.project.displayPath = "~/code/" + String(repeating: "long-project-folder/", count: 8)
        model.selected?.host.name = "Remote development host with a long display name"
        let longProject = try #require(model.selected)
        try await Preview.renderMatrix("project-mcp-trust-confirmation-long", size: CGSize(width: 600, height: 800)) {
            ProjectMCPTrustConfirmation(model: model, project: longProject) {}
        }
        model.selected?.project.displayPath = displayPath ?? ""; model.selected?.host.name = hostName ?? ""
        model.mcpTrustSaving = true
        try await Preview.renderMatrix("project-mcp-trust-saving", size: CGSize(width: 600, height: 500)) {
            ProjectMCPTrustConfirmation(model: model, project: project) {}
        }
        model.mcpTrustSaving = false
        model.mcpTrustError = "Project approval couldn't be saved. Try again."
        try await Preview.renderMatrix("project-mcp-trust-save-failure", size: CGSize(width: 600, height: 550)) {
            ProjectMCPTrustConfirmation(model: model, project: project) {}
        }
        model.mcpTrustError = nil
        trusted = true; await model.refreshMCPCredentials()
        try await render("approved-credentials-saved")
        signed = []; await model.refreshMCPCredentials()
        try await render("approved-no-credentials")
        await model.setMCPEnabled("issues", false)
        try await render("approved-server-disabled")
        await model.setMCPEnabled("issues", true)
        model.mcpTrustChecking = true
        try await render("checking")
        model.mcpTrustChecking = false
        trusted = nil; failure = "Couldn't check project approval. Check again before starting a new thread."
        await model.refreshMCPCredentials()
        try await render("check-failure")
        failure = nil; await model.refreshMCPCredentials()
        model.selected?.host.supportsProjectTrust = false
        try await render("old-host")
        model.selected?.host.unavailable = "Host offline. Reconnect in Settings > Remote to edit its projects."
        try await render("offline")
        model.selected?.host.unavailable = nil; model.selected?.host.supportsProjectTrust = true
        trusted = false; await model.refreshMCPCredentials()
        try await model.removeMCP("issues")
        try await render("empty")
        try await model.saveMCP([.init(name: String(repeating: "project-tools-", count: 6), json: ["url": .string("https://issues.example.invalid/" + String(repeating: "long-path/", count: 16))])])
        try await render("long")
        model.draft = "{ invalid JSON"
        try await render("invalid-config")
        let shared = try #require(model.selectedFiles.first { $0.path == ".mcp.json" })
        await model.navigate(.file(shared)); await model.discard()
        try await model.saveMCP([.init(name: "issues", json: ["url": .string("https://issues.example.invalid/mcp")])])
        try await render("shared-config")
    }
}
