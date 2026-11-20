import AppKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp

@Suite("Remote thread mounting", .mainActorExclusive)
@MainActor
struct RemoteThreadMountTests {
    @Test func maximizingARemoteTerminalKeepsTheThreadAndItsImageDraftMounted() async throws {
        let local = try AppHarness(), remote = try RemoteHostHarness()
        defer { local.stop(); remote.stop() }
        let space = Fixture.space(path: remote.host.dir.path)
        let agent = Fixture.agent("remote", in: space, auxiliary: 1)
        try await remote.host.start(with: Fixture.state(spaces: [space], agents: [agent]))
        let vm = try await local.start()
        let connection = try await remote.connect(local.remoteHosts)
        let ref = RemoteAgentRef(hostID: connection.id, agentID: agent.agent.id)
        vm.selectRemoteAgent(hostID: ref.hostID, agentID: ref.agentID)
        let input = vm.remoteThreadStores.input(for: ref)
        input.attachments.add([("draft.png", ImageAttachment(name: "draft.png", image: NativeImage(mimeType: "image/png", data: Data([1]))))])
        let store = vm.remoteThreadStores.store(for: ref)
        store.draft = "Unsent draft"
        let window = OffscreenWindow(size: CGSize(width: 900, height: 700), RemoteAgentPane(vm: vm, ref: ref))
        defer { window.close() }
        func scroll(_ view: NSView) -> NSScrollView? {
            if let found = view as? NSScrollView { return found }
            return view.subviews.lazy.compactMap(scroll).first
        }
        var original: NSScrollView?
        try await eventuallyOnMain("remote transcript scroll view to mount") {
            window.layout()
            original = scroll(window.host)
            return original != nil
        }
        let key = TerminalPanelKey(host: ref.hostID, tab: agent.tab.id)
        vm.terminalPanels.update(key) { $0.shown = true; $0.maximized = true }
        window.layout()
        #expect(scroll(window.host) === original)
        vm.terminalPanels.update(key) { $0.maximized = false }
        window.layout()
        #expect(scroll(window.host) === original)
        #expect(store.draft == "Unsent draft")
        #expect(vm.remoteThreadStores.input(for: ref) === input)
        #expect(input.attachments.items.map(\.name) == ["draft.png"])
    }
}
