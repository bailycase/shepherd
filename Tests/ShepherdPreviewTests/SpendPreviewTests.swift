import AppKit
import Foundation
import ShepherdCore
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp

/// Spend on the sidebar's rows and the Fleet page's header: real derivations over agents that carry the spend pi reported.
extension PreviewTests {
    private static let spendZone = TimeZone.current.identifier
    private static let spendDay = SpendDay.key(Date(), zone: spendZone)

    private func spendWorkspace() async throws -> (PreviewWorkspace, [Agent]) {
        let workspace = try PreviewWorkspace()
        let space = Space(name: "acme-web", path: workspace.dir.path)
        let rows: [(String, AgentStatus, AgentSpend?)] = [
            ("Speed up checkout CI", .working, AgentSpend(tokens: 3_100_000, cost: 4.2, day: Self.spendDay, zone: Self.spendZone, today: [
                ModelSpend(model: "anthropic/claude-sonnet-4", tokens: 2_400_000, cost: 3.1), ModelSpend(model: "openai/gpt-5-mini", tokens: 400_000, cost: 0.3)])),
            ("Fix flaky payment test", .working, AgentSpend(tokens: 12_400, cost: nil, day: Self.spendDay, zone: Self.spendZone, today: [
                ModelSpend(model: "acme-subscription/pro", tokens: 12_400, cost: nil)])),
            ("Migrate orders to Postgres 17", .done, AgentSpend(tokens: 640_000, cost: 8.9, day: Self.spendDay, zone: Self.spendZone, today: [
                ModelSpend(model: "anthropic/claude-opus-4", tokens: 640_000, cost: 8.9)])),
            ("Rename the settings page", .idle, nil),
        ]
        var agents: [Agent] = []
        var tabs: [ShepherdCore.Tab] = []
        for (index, row) in rows.enumerated() {
            var (agent, tab) = try await workspace.agent(row.0, in: space, order: index, status: row.1)
            agent.spend = row.2
            agent.lastActiveAt = Date().timeIntervalSince1970 * 1000 - Double(index) * 60_000
            agents.append(agent)
            tabs.append(tab)
        }
        try await workspace.seed(ShepherdState(spaces: [space], tabs: tabs, agents: agents))
        return (workspace, agents)
    }

    /// Each thread says what it spent on its second line, when it is known: "est. $4.20 · 3.1M tok", tokens alone for a model with
    /// no cost, nothing for a thread pi hasn't reported on.
    @Test func sidebarRowsSaySpend() async throws {
        let (workspace, _) = try await spendWorkspace()
        defer { workspace.stop() }
        let lists = workspace.vm.sidebarLists
        let subtitles = (lists.working + lists.done + lists.recents).compactMap(\.subtitle?.text)
        #expect(subtitles.sorted() == ["12.4k tok", "est. $4.20 · 3.1M tok", "est. $8.90 · 640k tok"])
        try await Preview.renderMatrix("sidebar-spend", size: CGSize(width: 232, height: 420)) {
            SidebarView(vm: workspace.vm).shDensity(.standard)
        }
    }

    /// The Fleet page's header: what the threads this Mac sees spent today, and each model's part.
    @Test func fleetPageSpendToday() async throws {
        let (workspace, _) = try await spendWorkspace()
        defer { workspace.stop() }
        let spend = try #require(workspace.vm.spendToday.summary)
        #expect(spend.rows.map(\.name) == ["claude-opus-4", "claude-sonnet-4", "gpt-5-mini", "pro"])
        let page = FleetPagePreviewTests.page()
        try await Preview.renderMatrix("fleet-spend-page", size: CGSize(width: 1208, height: 900)) {
            FleetPageContent(page: page, actions: FleetPagePreviewTests.noActions, spend: spend).frame(width: 1208, height: 900)
        }
    }
}
