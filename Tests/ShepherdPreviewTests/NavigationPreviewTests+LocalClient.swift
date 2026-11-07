import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp

/// The app as the background host's client (`SHEPHERD_BACKGROUND_HOST=1`): its own workspace is
/// empty, and the host on this Mac shows as a host, through its local socket.
extension PreviewTests {
    @Test func localClientWorkspace() async throws {
        let workspace = try PreviewWorkspace()
        let host = try ScratchServer(dir: try makeScratchDirectory("host"))
        defer { workspace.stop(); host.stop() }
        host.server.serveThreads(ThreadHosting(defaults: {
            ThreadHosting.Defaults(model: "stub/model-a", thinking: .medium, serviceTier: .standard,
                                   worktreeBaseMode: .head, worktreeFetchBeforeCreate: false)
        }, launch: { AgentLaunchSettings() }, shell: { SessionCommand(argv: ["/bin/sh"], env: [:]) }))
        let space = Space(name: "acme-web", path: host.dir.path)
        let names = ["Fix the checkout total rounding", "Upgrade the payments SDK", "Write release notes for 2.4"]
        let records = names.enumerated().map { index, name -> (Agent, ShepherdCore.Tab) in
            let id = AgentID()
            let pane = LeafPane(cwd: host.dir.path, agentID: id)
            let tab = ShepherdCore.Tab(spaceID: space.id, order: index, layout: .leaf(pane))
            return (Agent(id: id, name: name, spaceID: space.id, tabID: tab.id, paneID: pane.id,
                          status: index == 0 ? .working : .done, nameIsFinal: true), tab)
        }
        try await host.server.putState(ShepherdState(spaces: [space], tabs: records.map(\.1), agents: records.map(\.0)))
        let socket = host.dir.appendingPathComponent("h.sock").path
        let tokenURL = host.dir.appendingPathComponent("remote-token")
        try host.server.startLocalListener(path: socket, tokenURL: tokenURL)
        let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let vm = workspace.vm
        let connection = vm.remoteHosts.addLocalHost(name: "demo-mac", socket: socket, token: token)
        try await eventuallyOnMain("the host on this Mac to connect", timeout: .seconds(30)) {
            connection.phase == .connected && connection.state == host.server.state
        }
        vm.openNewThread()
        try await Preview.render("local-client-workspace", size: CGSize(width: 1280, height: 760)) {
            RootView(vm: vm)
        }
    }
}
