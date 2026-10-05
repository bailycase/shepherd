import AppKit
import Foundation
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp
@testable import ShepherdSessions

@Suite("Codemode nested activity controls", .integrationTimeLimit)
struct CodemodeControlTests {
    @Test func restoredCallsOpenTheirOwnOutputAndKeepTheScriptSeparate() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.pressCalls() }
        }
    }

    @Test func theFullOutputControlOpensTheNestedCallNotItsParent() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.pressFullOutput() }
        }
    }

    @MainActor
    private static func pressFullOutput() async throws {
        AccessibilityNode.enable()
        var message = try CodemodeFixture.message()
        message.details = .object(["calls": .array([.object([
            "id": .string("script/1"), "output": .string(String(repeating: "line\n", count: 30))])])])
        let rows = RPCThreadState.projectHistory([message])
        let burst = try #require(nativeActivityBursts(rows.map(NativeActivityCall.init)).first { $0.calls.contains { $0.id == "script/1" } })
        let window = OffscreenWindow(size: CGSize(width: 760, height: 720), dark: false)
        defer { window.close() }
        window.show(ActivityLineView(burst: burst, expanded: true, expandedCalls: ["script/1"]).padding(NW.Space.xl))
        ListPerf.settle(window)
        let more = try #require(window.controls().first { $0.label?.contains("more lines") == true })
        #expect(ControlPress.undersized([more], minimum: .desktop).isEmpty)
        try window.press(try #require(more.label))
        try await eventuallyOnMain("nested output sheet to open") { window.window.attachedSheet != nil }
        let host = try #require(window.window.attachedSheet?.contentView)
        let text = AccessibilityNode.all(under: host).flatMap { [$0.label, $0.value].compactMap { $0 } }.joined(separator: "\n")
        #expect(text.contains(String(repeating: "line\n", count: 29)))
        #expect(!text.contains("handled"), "the sheet does not show the script's result")
        try ControlPress.press("Done", under: host)
        try await eventuallyOnMain("output sheet to close") { window.window.attachedSheet == nil }
    }

    @MainActor
    private static func pressCalls() throws {
        AccessibilityNode.enable()
        let rows = RPCThreadState.projectHistory([try CodemodeFixture.message()])
        let bursts = nativeActivityBursts(rows.map(NativeActivityCall.init))
        let window = OffscreenWindow(size: CGSize(width: 760, height: 720), dark: false)
        defer { window.close() }
        window.show(VStack(alignment: .leading) {
            ForEach(bursts) { ActivityLineView(burst: $0) }
            Spacer()
        }.padding(NW.Space.xl))
        ListPerf.settle(window)
        for burst in bursts {
            let pressed = try window.press(burst.accessibilityLabel)
            #expect(ControlPress.undersized([pressed], minimum: .desktop).isEmpty)
            ListPerf.settle(window)
            #expect(window.controls().contains { $0.label == burst.accessibilityLabel && $0.value == "Expanded" })
            for call in burst.calls {
                let label = [call.label, call.detail, call.stat, call.failed ? "failed" : nil].compactMap { $0 }.joined(separator: ", ")
                let control = try window.press(label)
                #expect(ControlPress.undersized([control], minimum: .desktop).isEmpty)
                ListPerf.settle(window)
                #expect(window.controls().contains { $0.label == label && $0.value == "Expanded" })
                let text = AccessibilityNode.all(under: window.host).flatMap { [$0.label, $0.value].compactMap { $0 } }.joined(separator: "\n")
                #expect(text.contains(call.outputHead.joined(separator: "\n")), "opened output belongs to \(call.id)")
                try window.press(label)
                ListPerf.settle(window)
                #expect(!window.controls().contains { $0.label == label && $0.value == "Expanded" })
            }
            try window.press(burst.accessibilityLabel)
        }
    }
}
