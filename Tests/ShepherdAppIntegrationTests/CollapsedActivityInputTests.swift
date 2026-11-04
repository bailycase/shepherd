#if DEBUG
import AppKit
import Foundation
import Observation
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

// Fileprivate: Observation's generated extension must be able to name the fixture.
@MainActor @Observable
fileprivate final class ActivityInputFixture {
    var calls: [NativeActivityCall]
    init(_ calls: [NativeActivityCall]) { self.calls = calls }
    var burst: NativeActivityBurst { nativeActivityBurst(calls) }
}

@MainActor
fileprivate final class ActivityInputReceipt {
    var parents = 0
    var preparations = 0
    var calls = 0
    func prepared(_ count: Int) { preparations += 1; calls += count }
}

fileprivate struct ActivityInputHarness: View {
    let fixture: ActivityInputFixture
    let receipt: ActivityInputReceipt
    var body: some View {
        let _ = { receipt.parents += 1 }()
        ScrollView {
            // Always seed false: a later parent update must still honor the mounted open state.
            ActivityLineView(burst: fixture.burst, didPrepareInputs: receipt.prepared)
                .equatable()
                .padding(SH.Space.xl)
        }
        .environment(\._accessibilityReduceMotion, true)
    }
}

@Suite("Collapsed activity inputs", .integrationTimeLimit)
struct CollapsedActivityInputTests {
    @Test func aGrowingCollapsedBurstDoesNoInputPreparationAndReopensCurrentScripts() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.growingAndReopening() }
        }
        expectScenarioCompleted(result)
    }

    @Test func ordinaryRawInputsStillToggleAndOpenTheirFullText() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.rawInputs() }
        }
        expectScenarioCompleted(result)
    }

    fileprivate static func code(_ marker: String) -> String {
        (1...40).map { "text('\(marker) line \($0) \(String(repeating: "x", count: 70))');" }.joined(separator: "\n")
    }

    fileprivate static func call(_ index: Int, code: String) throws -> NativeActivityCall {
        let data = try JSONSerialization.data(withJSONObject: ["code": code], options: [.sortedKeys])
        return NativeActivityCall(NativeThreadMessage(entryID: "entry-\(index)", role: "toolResult",
            blocks: [NativeThreadBlock(kind: .text, text: "output \(index)")], toolName: "codemode",
            toolCallID: "call-\(index)", argumentsText: String(decoding: data, as: UTF8.self), status: "complete"))
    }

    @MainActor
    private static func text(_ view: NSView) -> String {
        AccessibilityNode.all(under: view).flatMap { [$0.label, $0.value].compactMap { $0 } }.joined(separator: "\n")
    }

    @MainActor
    private static func expanded(_ window: OffscreenWindow, label: String) -> Bool {
        window.controls().contains { $0.label == label && $0.value == "Expanded" }
    }

    @MainActor
    private static func change(_ window: OffscreenWindow, receipt: ActivityInputReceipt, _ mutation: () -> Void) async throws {
        let before = receipt.parents
        mutation()
        try await eventuallyOnMain("the changed burst reaches its existing view") {
            ListPerf.settle(window)
            return receipt.parents > before
        }
    }

    @MainActor
    private static func growingAndReopening() async throws {
        AccessibilityNode.enable()
        let all = try (0..<20).map { try call($0, code: code("original-\($0)")) }
        let fixture = ActivityInputFixture([all[0]]), receipt = ActivityInputReceipt()
        let window = OffscreenWindow(size: CGSize(width: 760, height: 720), dark: false,
                                     ActivityInputHarness(fixture: fixture, receipt: receipt))
        defer { window.close() }
        for count in 2...20 {
            try await change(window, receipt: receipt) { fixture.calls = Array(all.prefix(count)) }
            #expect(fixture.burst.id == all[0].id)
            #expect(!expanded(window, label: fixture.burst.accessibilityLabel))
        }
        // Baseline's initializer prepares growing prefixes; this counts work, not row draws.
        #expect(receipt.preparations == 0 && receipt.calls == 0,
                "prepared \(receipt.calls) inputs in \(receipt.preparations) passes while collapsed")
        try window.press(fixture.burst.accessibilityLabel)
        try await eventuallyOnMain("opening prepares and auto-expands scripts") {
            ListPerf.settle(window)
            return receipt.calls >= 20 && expanded(window, label: "codemode script")
        }

        // Keep the same burst/first-call identity, now with one visible script for control checks.
        try await change(window, receipt: receipt) { fixture.calls = [all[0]] }
        let updated = try call(0, code: code("open-update"))
        try await change(window, receipt: receipt) { fixture.calls = [updated] }
        #expect(expanded(window, label: fixture.burst.accessibilityLabel), "initializer default false cannot close retained state")
        #expect(text(window.host).contains("open-update line 1"))
        try window.press("codemode script")
        ListPerf.settle(window)
        #expect(!expanded(window, label: "codemode script"))
        let stillClosed = try call(0, code: code("kept-closed"))
        try await change(window, receipt: receipt) { fixture.calls = [stillClosed] }
        #expect(!expanded(window, label: "codemode script"), "an argument update preserves a user's input disclosure")

        try window.press(fixture.burst.accessibilityLabel)
        try await eventuallyOnMain("the detail is fully closed") {
            ListPerf.settle(window)
            return !window.controls().contains { $0.label == "codemode script" }
        }
        let prepared = receipt.calls
        let reopenedCode = code("reopened-current")
        let reopened = try call(0, code: reopenedCode)
        try await change(window, receipt: receipt) { fixture.calls = [reopened] }
        #expect(receipt.calls == prepared, "changing arguments while closed must not prepare inputs")
        try window.press(fixture.burst.accessibilityLabel)
        try await eventuallyOnMain("reopening auto-expands the current script") {
            ListPerf.settle(window)
            return expanded(window, label: "codemode script") && text(window.host).contains("reopened-current line 1")
        }
        let more = try #require(window.controls().first { $0.label?.contains("more lines") == true })
        try window.press(try #require(more.label))
        try await eventuallyOnMain("the full current script opens") { window.window.attachedSheet != nil }
        let sheet = try #require(window.window.attachedSheet?.contentView)
        #expect(text(sheet).contains(reopenedCode))
        #expect(!text(sheet).contains("open-update"))
        try ControlPress.press("Done", under: sheet)
        try await eventuallyOnMain("the script sheet closes") { window.window.attachedSheet == nil }
        try window.press("codemode script")
        ListPerf.settle(window)
        #expect(!expanded(window, label: "codemode script"), "auto-open does not prevent closing the input afterward")
    }

    @MainActor
    private static func rawInputs() async throws {
        AccessibilityNode.enable()
        let data = try JSONSerialization.data(withJSONObject: Dictionary(uniqueKeysWithValues: (0..<20).map { ("field-\($0)", "value-\($0)") }),
                                              options: [.prettyPrinted, .sortedKeys])
        let raw = String(decoding: data, as: UTF8.self)
        let call = NativeActivityCall(NativeThreadMessage(entryID: "plain", role: "toolResult",
            blocks: [NativeThreadBlock(kind: .text, text: "independent output")], toolName: "fixture_tool",
            toolCallID: "plain", argumentsText: raw, status: "complete"))
        let fixture = ActivityInputFixture([call]), receipt = ActivityInputReceipt()
        let window = OffscreenWindow(size: CGSize(width: 760, height: 720), dark: true,
                                     ActivityInputHarness(fixture: fixture, receipt: receipt))
        defer { window.close() }
        #expect(receipt.calls == 0)
        try window.press(fixture.burst.accessibilityLabel)
        ListPerf.settle(window)
        #expect(!expanded(window, label: "fixture_tool arguments"))
        try window.press("fixture_tool arguments")
        ListPerf.settle(window)
        #expect(expanded(window, label: "fixture_tool arguments"))
        let more = try #require(window.controls().first { $0.label?.contains("more lines") == true })
        try window.press(try #require(more.label))
        try await eventuallyOnMain("the full raw input opens") { window.window.attachedSheet != nil }
        let sheet = try #require(window.window.attachedSheet?.contentView)
        #expect(text(sheet).contains(raw))
        #expect(!text(sheet).contains("independent output"))
        try ControlPress.press("Done", under: sheet)
        try await eventuallyOnMain("the raw input sheet closes") { window.window.attachedSheet == nil }
        try window.press(fixture.burst.accessibilityLabel)
        ListPerf.settle(window)
        try window.press(fixture.burst.accessibilityLabel)
        ListPerf.settle(window)
        #expect(expanded(window, label: "fixture_tool arguments"), "ordinary input expansion survives closing the outer line")
    }
}

@Suite("Activity input first paint", .mainActorExclusive)
@MainActor
struct ActivityInputFirstPaintTests {
    @Test(arguments: [false, true])
    func initiallyExpandedScriptsArePopulatedWithoutAnAppearanceCallback(dark: Bool) throws {
        let call = try CollapsedActivityInputTests.call(0, code: CollapsedActivityInputTests.code("first-paint"))
        let burst = nativeActivityBurst([call])
        func render(_ expandedCalls: Set<String>, expanded: Bool = true) throws -> CGImage {
            let renderer = ImageRenderer(content: ActivityLineView(burst: burst, expanded: expanded, expandedCalls: expandedCalls)
                .padding(SH.Space.xl)
                .frame(width: 760)
                .background(Color.sh.bgWindow)
                .environment(\.colorScheme, dark ? .dark : .light))
            return try #require(renderer.cgImage)
        }
        let automatic = try render([]), explicit = try render(["\(call.id):input"])
        let collapsed = try render([], expanded: false)
        #expect(automatic.width == explicit.width && automatic.height == explicit.height,
                "first paint must already have the explicitly-open script's layout, not wait for onAppear")
        #expect(automatic.height > collapsed.height)
    }
}
#endif
