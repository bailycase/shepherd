import AppKit
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing

/// The Browser's tab chrome (BrowserTabs boards), pressed the way VoiceOver presses
/// (`ControlPress`), over `NWBrowserTabsBoard`, which feeds the components plain values. This proves
/// each control is a control, is enabled in the state its board draws, calls its action and has a
/// 24pt hit area. It does not prove what the model does with the action: the app's tabs are not
/// wired in yet. Each scenario runs in its own process (the accessibility tree is process-wide).
@Suite("Browser tabs controls", .integrationTimeLimit)
struct BrowserTabsControlTests {
    @Test func twoTabsSelectCloseAndOpenANewOne() async {
        await #expect(processExitsWith: .success) { await recordingErrors { try await Self.twoTabs() } }
    }

    @Test func eightTabsCapNewTabAndTheListSelectsAndClosesOthers() async {
        await #expect(processExitsWith: .success) { await recordingErrors { try await Self.eightTabs() } }
    }

    @Test func theNotesAndTheAgentsControlsAnswer() async {
        await #expect(processExitsWith: .success) { await recordingErrors { try await Self.notesAndAgent() } }
    }

    @MainActor final class Log { var lines: [String] = [] }

    @MainActor
    private static func open(_ scene: NWBrowserTabsBoard.Scene, _ log: Log) -> OffscreenWindow {
        AccessibilityNode.enable()
        return OffscreenWindow(size: CGSize(width: NWBrowserTabsBoard.paneWidth, height: 560), dark: true,
                               NWBrowserTabsBoard(scene) { log.lines.append($0) })
    }

    @MainActor
    static func twoTabs() async throws {
        let log = Log()
        let window = open(.two, log)
        defer { window.close() }

        let labels = window.controls().compactMap(\.label)
        for expected in ["Refund overview", "Stripe · Test mode", "Close Refund overview", "Close Stripe · Test mode", "New tab", "All tabs"] {
            #expect(labels.contains(expected), "\(expected) is offered: \(labels)")
        }
        #expect(ControlPress.undersized(window.controls(), minimum: .desktop).isEmpty,
                "every control is 24pt: \(ControlPress.undersized(window.controls(), minimum: .desktop))")
        #expect(window.element("Refund overview")?.isSelected == true, "the shown tab says it is selected")
        #expect(window.element("Stripe · Test mode")?.isSelected != true)

        try window.press("Stripe · Test mode")
        try window.press("New tab")
        try window.press("Close Stripe · Test mode")
        #expect(log.lines == ["select 2", "new", "close 2"], "\(log.lines)")
        #expect(window.element("Close Stripe · Test mode") == nil, "a closed tab's controls are gone")
    }

    @MainActor
    static func eightTabs() async throws {
        let log = Log()
        let window = open(.full, log)
        defer { window.close() }

        let newTab = try #require(window.controls().first { $0.label == "New tab" })
        #expect(!newTab.isEnabled, "New tab is disabled at the cap")
        #expect((try? window.press("New tab")) == nil, "and a press is refused")
        #expect(log.lines.isEmpty, "\(log.lines)")
        #expect(window.controls().compactMap(\.label).filter { $0.hasPrefix("Close ") && $0 != "Close other tabs" } == ["Close Checkout"], "only the shown tab offers close with eight")
        #expect(ControlPress.undersized(window.controls(), minimum: .desktop).isEmpty,
                "\(ControlPress.undersized(window.controls(), minimum: .desktop))")
        #expect(ControlPress.controls(in: "All tabs", under: window.host).count >= 9, "eight rows and Close other tabs")

        try window.press("Refund overview, localhost:3000/refunds", in: "All tabs")
        #expect(log.lines.last == "select 1", "\(log.lines)")
        #expect(ControlPress.controls(in: "All tabs", under: window.host).isEmpty, "choosing a row closes the list")

        try window.press("All tabs")
        #expect(!ControlPress.controls(in: "All tabs", under: window.host).isEmpty)
        try window.press("Close other tabs", in: "All tabs")
        #expect(log.lines.last == "closeOthers", "\(log.lines)")
        #expect(ControlPress.controls(in: "All tabs", under: window.host).isEmpty)
        try window.press("All tabs")
        let close = try #require(ControlPress.controls(in: "All tabs", under: window.host).first { $0.label == "Close other tabs" })
        #expect(!close.isEnabled, "with one tab left there is nothing to close")
    }

    @MainActor
    static func notesAndAgent() async throws {
        let log = Log()
        let opened = open(.opened, log)
        #expect(opened.element("Refund overview · staging, new") != nil, "the unseen tab says it is new")
        try opened.press("Show it")
        #expect(log.lines == ["show"], "\(log.lines)")
        #expect(opened.element("Show it") == nil, "the note goes once shown")
        opened.close()

        let popup = open(.popup, log)
        try popup.press("Dismiss")
        #expect(log.lines.last == "dismiss")
        #expect(popup.element("Dismiss") == nil)
        popup.close()

        let agent = open(.agent, log)
        #expect(agent.element("Checkout, agent is using it") != nil, "the tab the agent is in says so")
        #expect(ControlPress.undersized(agent.controls(), minimum: .desktop).isEmpty, "\(ControlPress.undersized(agent.controls(), minimum: .desktop))")
        try agent.press("Take over")
        #expect(log.lines.last == "takeOver")
        agent.close()

        let elsewhere = open(.elsewhere, log)
        defer { elsewhere.close() }
        try elsewhere.press("Agent is in Checkout. Show it")
        #expect(log.lines.last == "select 2", "\(log.lines)")
        #expect(elsewhere.element("Agent is in Checkout. Show it") == nil, "showing the agent's tab takes the chip away")
    }
}
