import Testing
@testable import ShepherdSessions

/// What an extension adds in Shepherd and what it can't show: pi's RPC mode draws none of the
/// terminal UI, so shortcuts, flags and renderers don't show while tools, commands and hooks work.
@Suite("Extension support in Shepherd")
struct PiExtensionSupportTests {
    @Test func toolsCommandsHooksAndProvidersWork() {
        let support = PiExtensionSupport.make([PiExtensionInventory(path: "/h/a.ts", providers: ["acme"], tools: ["acme_search"],
                                                                     commands: ["acme-usage"], events: ["session_start", "tool_call"])],
                                              scanned: [])
        #expect(support.providers == ["acme"])
        #expect(support.adds == ["/acme-usage", "acme_search tool", "2 event hooks"])
        #expect(support.notShown.isEmpty && support.level == .works)
    }

    @Test func terminalOnlyRegistrationsAndCallsMakeItPartly() {
        let support = PiExtensionSupport.make([PiExtensionInventory(path: "/h/a/index.ts", shortcuts: ["ctrl+x"], flags: ["fast"], renderers: 2),
                                               PiExtensionInventory(path: "/h/a/more.ts", shortcuts: ["ctrl+x"])],
                                              scanned: ["footer or header"])
        #expect(support.notShown == ["shortcut ctrl+x", "--fast flag", "custom message display"])
        #expect(support.mayNotShow == ["footer or header"])
        #expect(support.level == .partly)
        #expect(PiExtensionSupport.make([PiExtensionInventory(path: "/h/b.ts")], scanned: ["status line"]).level == .partly)
    }
}
