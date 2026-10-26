import AppKit
import Foundation
import ShepherdCore
import ShepherdRemote
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// The Browser pane's tabs over the real model: a real root `BrowserSession` and its `BrowserTabs`,
/// real web views loading real pages from a local server, and the pane in an off-screen window, pressed
/// the way VoiceOver presses (`ControlPress`). Nothing is posted to the window. The accessibility tree
/// is process-wide, so each scenario runs in its own process.
@Suite("Browser pane tabs", .integrationTimeLimit)
struct BrowserPaneTabsTests {
    @Test func stripListAndNewTabDriveTheRealTabs() async {
        await #expect(processExitsWith: .success) { await recordingErrors { try await Self.stripAndList() } }
    }

    @Test func theCapNoteAndAFullStrip() async {
        await #expect(processExitsWith: .success) { await recordingErrors { try await Self.capped() } }
    }

    @Test func theOpenedNoteShowItAndTheAgentsBarAndChip() async {
        await #expect(processExitsWith: .success) { await recordingErrors { try await Self.openedAndAgent() } }
    }

    @Test func theThreadsOwnNoticeStaysInViewOnAnotherTabAndAddressTextFollowsTheTab() async {
        await #expect(processExitsWith: .success) { await recordingErrors { try await Self.rootNoticeAndAddress() } }
    }

    @Test func commandTOpensATabOnlyWhileTheBrowserIsOnScreen() async {
        await #expect(processExitsWith: .success) { await recordingErrors { try await Self.commandT() } }
    }

    static let pages = [
        "/refunds": "<html><head><title>Refund overview</title></head><body><h1>Refunds</h1></body></html>",
        "/checkout": "<html><head><title>Checkout</title></head><body><h1>Checkout</h1></body></html>",
        "/docs": "<html><head><title>Refunds API · Stripe Docs</title></head><body>Docs</body></html>",
    ]

    /// The pane, the way `SidePane` mounts it, over a real root page.
    @MainActor
    struct Rig {
        let web: TinyWebServer
        let app: AppHarness
        let vm: ShepherdViewModel
        let root: BrowserSession
        let window: OffscreenWindow

        var tabs: BrowserTabs { root.tabs }

        init(active: Bool = true, size: CGSize = CGSize(width: AppLayout.paneDefaultWidth, height: 700)) async throws {
            AccessibilityNode.enable()
            web = try TinyWebServer(pages: BrowserPaneTabsTests.pages)
            try await web.start()
            app = try AppHarness()
            vm = try await app.start()
            root = BrowserSession(agentID: AgentID(), dataStores: .ephemeral)
            window = OffscreenWindow(size: size, dark: true,
                                     BrowserPane(vm: vm, session: root, store: NativeThreadStore(), active: active)
                                        .frame(width: size.width, height: size.height)
                                        .background(Color.sh.bgWindow))
        }

        func close() {
            window.close()
            root.close()
            app.stop()
            web.stop()
        }

        /// Loads `path` in `page` and waits for its real title.
        func load(_ path: String, in page: BrowserSession, title: String) async throws {
            page.load(web.url(path))
            try await eventuallyOnMain("\(path) to load as \(title)") { !page.isLoading && page.tabTitle == title }
        }

        /// The plus button. A blank tab's own title is also "New tab", so the button is the last of the two.
        @discardableResult
        func pressNewTab() throws -> Control {
            let count = window.controls().filter { $0.label == "New tab" }.count
            return try window.press("New tab", nth: max(0, count - 1))
        }

        func settle() async throws {
            try await Task.sleep(for: .milliseconds(150))
            window.layout()
        }
    }

    // MARK: Scenarios

    @MainActor
    static func stripAndList() async throws {
        let rig = try await Rig()
        defer { rig.close() }
        try await rig.load("/refunds", in: rig.root, title: "Refund overview")
        try await rig.settle()

        // One tab: its close, New tab, All tabs. The note is absent.
        var labels = rig.window.controls().compactMap(\.label)
        #expect(labels.contains("Refund overview") && labels.contains("Close Refund overview") && labels.contains("New tab") && labels.contains("All tabs"), "\(labels)")
        #expect(rig.window.element("Dismiss") == nil, "no note with one tab and nothing to say")
        #expect(rig.window.element("Refund overview")?.isSelected == true)

        // New tab: a real second page, shown, blank.
        try rig.pressNewTab()
        try await eventuallyOnMain("a second tab") { rig.tabs.pages.count == 2 }
        #expect(rig.tabs.selectedPage !== rig.root, "the new tab is the one shown")
        try await rig.settle()
        #expect(rig.window.element("New tab")?.isSelected == true, "its title is New tab until it has a page: \(rig.window.controls().compactMap(\.label))")

        // It loads a real page; its tab takes the real title.
        let second = rig.tabs.selectedPage
        try await rig.load("/checkout", in: second, title: "Checkout")
        try await rig.settle()
        #expect(rig.window.element("Checkout")?.isSelected == true)

        // The list: both rows, the checked one is the shown tab, and the footer counts them.
        try rig.window.press("All tabs")
        try await rig.settle()
        let rows = ControlPress.controls(in: "All tabs", under: rig.window.host).compactMap(\.label)
        #expect(rows.contains { $0.hasPrefix("Refund overview, ") } && rows.contains { $0.hasPrefix("Checkout, ") } && rows.contains("Close other tabs"), "\(rows)")

        // A row selects the root again; the toolbar and the page are the root's.
        try rig.window.press(try #require(rows.first { $0.hasPrefix("Refund overview, ") }), in: "All tabs")
        #expect(rig.tabs.selectedPage === rig.root)
        #expect(ControlPress.controls(in: "All tabs", under: rig.window.host).isEmpty, "choosing a row closes the list")

        // Close other tabs, then close the last one: the pane keeps an empty tab and its claim.
        try rig.window.press("All tabs")
        try rig.window.press("Close other tabs", in: "All tabs")
        try await eventuallyOnMain("one tab left") { rig.tabs.pages.count == 1 }
        #expect(rig.tabs.selectedPage === rig.root)
        try rig.window.press("Close Refund overview")
        try await eventuallyOnMain("an empty tab replaces the last one") { rig.tabs.pages.count == 1 && rig.tabs.selectedPage !== rig.root }
        labels = rig.window.controls().compactMap(\.label)
        #expect(!labels.contains("Refund overview"), "\(labels)")
        #expect(ControlPress.undersized(rig.window.controls(), minimum: .desktop).isEmpty,
                "\(ControlPress.undersized(rig.window.controls(), minimum: .desktop))")
    }

    @MainActor
    static func capped() async throws {
        let rig = try await Rig()
        defer { rig.close() }
        try await rig.load("/refunds", in: rig.root, title: "Refund overview")
        for _ in 1..<BrowserTabs.maxTabs { try rig.pressNewTab() }
        try await eventuallyOnMain("eight tabs") { rig.tabs.pages.count == BrowserTabs.maxTabs }
        try await rig.settle()
        let newTab = try #require(rig.window.controls().last { $0.label == "New tab" })
        #expect(!newTab.isEnabled, "New tab is disabled at the cap")
        #expect((try? rig.pressNewTab()) == nil)
        #expect(rig.tabs.pages.count == BrowserTabs.maxTabs)

        // A link that opens a window, at the bound: the model says so, and the pane shows its words.
        rig.tabs.notice = .cap
        try await rig.settle()
        let words = "This thread has 8 tabs, the most it keeps. New links open in this tab."
        #expect(rig.window.element(words) != nil, "the cap's words come from the app's notice: \(rig.window.elements().compactMap(\.label))")
        try rig.window.press("Dismiss")
        #expect(rig.tabs.notice == nil)
        try await rig.settle()
        #expect(rig.window.element(words) == nil)

        // The popup's own words.
        rig.tabs.notice = .popup
        try await rig.settle()
        #expect(rig.window.element("A link opened a new window. Shepherd opened it as a tab.") != nil)
    }

    @MainActor
    static func openedAndAgent() async throws {
        let rig = try await Rig()
        defer { rig.close() }
        try await rig.load("/refunds", in: rig.root, title: "Refund overview")

        // The agent opens a tab in the background: a dot, the note, Show it.
        let agentPage = try #require(rig.tabs.add(source: .agent, select: false))
        try await rig.load("/docs", in: agentPage, title: "Refunds API · Stripe Docs")
        try await rig.settle()
        #expect(rig.tabs.selectedPage === rig.root, "an agent's tab does not take the user's page")
        #expect(rig.window.element("Refunds API · Stripe Docs, new") != nil, "the unseen dot reads as new: \(rig.window.controls().compactMap(\.label))")
        #expect(rig.window.element("The agent opened Refunds API · Stripe Docs in a new tab.") != nil)
        try rig.window.press("Show it")
        #expect(rig.tabs.selectedPage === agentPage && !agentPage.tabUnseen && rig.tabs.openedPage == nil)
        try await rig.settle()
        #expect(rig.window.element("Show it") == nil, "the note goes with the tab shown")

        // The agent works in the page that is not shown: the chip, which shows that tab when pressed.
        rig.tabs.select(rig.root.tabID)
        rig.root.agentBegan(note: "filling the checkout form")
        try await eventuallyOnMain("the agent's overlay") { rig.tabs.agentPage === rig.root }
        try await rig.settle()
        #expect(rig.window.element("Take over") != nil, "the bar is on the page the agent is using")
        #expect(rig.window.element("Agent is filling the checkout form") != nil)
        rig.tabs.select(agentPage.tabID)
        try await rig.settle()
        #expect(rig.window.element("Take over") == nil, "the bar belongs to the agent's page, not the one shown")
        try rig.window.press("Agent is in Refund overview. Show it")
        #expect(rig.tabs.selectedPage === rig.root)
        try await rig.settle()
        try rig.window.press("Take over")
        #expect(rig.root.userHasControl, "Take over reaches the page the bar belongs to")
    }

    @MainActor
    static func rootNoticeAndAddress() async throws {
        let rig = try await Rig()
        defer { rig.close() }
        try await rig.load("/refunds", in: rig.root, title: "Refund overview")
        try rig.pressNewTab()
        try await eventuallyOnMain("the new tab shown") { rig.tabs.selectedPage !== rig.root }
        let other = rig.tabs.selectedPage

        // Another Mac took the agent's browser: the root holds the notice, and a blank tab is shown.
        let words = "Another Mac took over this thread's browser. Show this tab to take it back."
        rig.root.notice = BrowserNotice(message: words)
        try await rig.settle()
        #expect(rig.window.element(words) != nil, "the root's notice shows while another tab is shown: \(rig.window.elements().compactMap(\.label))")
        // The page's own notice outranks it.
        other.notice = BrowserNotice(message: "Port 5173 is in use on this Mac.")
        try await rig.settle()
        #expect(rig.window.element("Port 5173 is in use on this Mac.") != nil && rig.window.element(words) == nil)
        try rig.window.press("Dismiss")
        #expect(other.notice == nil && rig.root.notice != nil, "Dismiss clears the notice that was shown, not the other")
        try await rig.settle()
        try rig.window.press("Dismiss")
        #expect(rig.root.notice == nil, "and then the root's, on the root")
        try await rig.settle()
        #expect(rig.window.element(words) == nil)

        // ⌘T while the address is being edited: the new tab's field is empty, not the old tab's URL.
        rig.tabs.select(rig.root.tabID)
        let watcher = try #require(Self.watcher(in: rig.window.host))
        rig.root.focusAddress()
        try await rig.settle()
        let cmdT = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                                 windowNumber: rig.window.window.windowNumber, context: nil, characters: "t",
                                                 charactersIgnoringModifiers: "t", isARepeat: false, keyCode: 17))
        #expect(watcher.handle(cmdT))
        try await rig.settle()
        let fields = rig.window.elements().filter { $0.role == "AXTextField" }
        #expect(fields.count == 1 && (fields[0].value ?? "").isEmpty, "the new tab's address is empty: \(fields.map { $0.value ?? "nil" })")
    }

    @MainActor
    static func commandT() async throws {
        let rig = try await Rig(active: true)
        defer { rig.close() }
        try await rig.load("/refunds", in: rig.root, title: "Refund overview")
        let watcher = try #require(Self.watcher(in: rig.window.host))
        let cmdT = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                                 windowNumber: rig.window.window.windowNumber, context: nil, characters: "t",
                                                 charactersIgnoringModifiers: "t", isARepeat: false, keyCode: 17))
        #expect(rig.vm.keybindings.display(.browserNewTab) == "⌘T")
        #expect(watcher.handle(cmdT), "⌘T is the Browser's while it is on screen")
        #expect(rig.tabs.pages.count == 2 && rig.tabs.selectedPage !== rig.root)
        let shiftT = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
                                                   windowNumber: rig.window.window.windowNumber, context: nil, characters: "T",
                                                   charactersIgnoringModifiers: "t", isARepeat: false, keyCode: 17))
        #expect(!watcher.handle(shiftT), "⇧⌘T stays New Agent with Options")
        #expect(rig.tabs.pages.count == 2)
        watcher.active = false
        #expect(!watcher.handle(cmdT), "off screen, the chord is not the Browser's")
        #expect(rig.tabs.pages.count == 2)
    }

    @MainActor
    private static func watcher(in view: NSView) -> BrowserKeys.Watcher? {
        if let found = view as? BrowserKeys.Watcher { return found }
        return view.subviews.lazy.compactMap { watcher(in: $0) }.first
    }
}
