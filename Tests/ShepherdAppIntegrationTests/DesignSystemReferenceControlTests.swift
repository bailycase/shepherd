import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// The built-in Shepherd UI page (DesignSystemPage and its eight sibling boards), every control it
/// draws pressed through accessibility on a real scratch server: Dark and Light, New design, the
/// contents button and its rows, the All groups popup and the breadcrumb. Each must do what it says,
/// with a hit area of at least 24pt. The page draws no Edit, Add or component open control, and the
/// test says so.
@Suite("Design system reference controls", .integrationTimeLimit)
struct DesignSystemReferenceControlTests {
    @Test func everyControlOnTheBuiltInSystemPageDoesWhatItSays() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.pressing() }
        }
    }

    /// A native menu is chosen with `NativeMenuChoice`, which leaves its tracking open, so the popup has a scenario of its own.
    @Test func theComponentGroupPopupFiltersTheCatalogToOneGroup() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.filtering() }
        }
    }

    /// Whether a heading by this label is inside the window right now: its accessibility frame meets the window's.
    @MainActor
    private static func onScreen(_ label: String, in window: OffscreenWindow) -> Bool {
        window.layout()
        let area = window.window.frame
        return AccessibilityNode.all(under: window.host).contains { $0.label == label && $0.frame.intersects(area) }
    }

    @Test func theMoreMenuStaysAndItsDuplicateActionMakesACopyOfTheBuiltInSystem() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.duplicating() }
        }
    }

    @MainActor
    private static func duplicating() async throws {
        AccessibilityNode.enable()
        let app = try AppHarness()
        defer { app.stop() }
        app.settings.designToolEnabled = true
        app.server.designSystems.register(NightWatchSystem.builtIn())
        let vm = try await app.start()
        await vm.loadDesignSystems()
        vm.openDesignSystem(NightWatchSystem.namespace)
        let window = OffscreenWindow(size: CGSize(width: 1208, height: 900), dark: true, DesignSystemDestination(vm: vm))
        defer { window.close() }
        try await eventuallyOnMain("the page") { window.controls().contains { $0.label == "New design" } }
        let more = try #require(AccessibilityNode.all(under: window.host).first { node in
            node.role == ControlRole.menuButton
                && (node.object.perform(NSSelectorFromString("accessibilityHelp"))?.takeUnretainedValue() as? String) == "More for Shepherd UI"
        }, "the page keeps its More menu")
        let offered = try await NativeMenuChoice.choose("Duplicate as a New System", from: more)
        #expect(offered.contains("Duplicate as a New System") && offered.contains("Open"), "the built-in's menu: \(offered)")
        try await eventuallyOnMain("the copy to be made and opened") {
            vm.shownDesignSystem == "night-watch-copy" && vm.designSystems.summary("night-watch-copy") != nil
        }
        #expect(vm.designSystems.summary("night-watch-copy")?.builtIn == false)
        #expect(vm.designSystems.summary(NightWatchSystem.namespace)?.info.title == "Night Watch", "the built-in keeps its registered title")
    }

    @Test func withManyDesignsInAShortWindowTheContentsMenuStaysInsideItAndReachesTheLastOne() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.overflowing() }
        }
    }

    @MainActor
    private static func overflowing() async throws {
        AccessibilityNode.enable()
        let app = try AppHarness()
        defer { app.stop() }
        app.settings.designToolEnabled = true
        app.server.designSystems.register(NightWatchSystem.builtIn())
        let vm = try await app.start()
        for index in 1...14 {
            var design = Design(name: "Design \(index) with a rather long name that has to truncate", createdAt: Double(3_000 + index), boardCount: index)
            design.systemNamespace = NightWatchSystem.namespace
            _ = try await app.server.createDesign(design)
        }
        vm.adopt(app.server.state)
        await vm.loadDesignSystems()
        vm.openDesignSystem(NightWatchSystem.namespace)
        let reference = try #require(vm.designSystemPage(.system(NightWatchSystem.namespace)).reference)
        #expect(reference.used.count == 14)
        let window = OffscreenWindow(size: CGSize(width: 1208, height: 420), dark: true, DesignSystemDestination(vm: vm))
        defer { window.close() }
        try await eventuallyOnMain("the page") { window.controls().contains { $0.label == "Contents" } }
        try window.press("Contents")
        try await eventuallyOnMain("the menu") { window.controls().contains { $0.label?.hasPrefix("Overview") == true } }
        // The menu is bounded by the window: its first row is inside it, and not every design row fits.
        let area = window.window.frame
        let rows = window.controls().filter { $0.label?.contains(", ") == true && $0.label?.hasPrefix("Design ") == true }
        #expect(rows.count == 14, "every design is in the menu, scrolled or not")
        #expect(window.controls().first { $0.label?.hasPrefix("Overview") == true }.map { area.contains($0.frame) } == true)
        let menuBottom = rows.map(\.frame.maxY).min() ?? 0
        #expect(rows.contains { $0.frame.minY < area.minY || $0.frame.maxY > area.maxY || !area.contains($0.frame) },
                "some rows lie past the window, so the menu scrolls instead of growing: bottom \(menuBottom) in \(area)")
        let last = try #require(reference.used.last)
        try window.press("\(last.name), \(last.boards)")
        try await eventuallyOnMain("the last design to open") { vm.shownDestination != .designSystem }
        #expect(vm.designsPageSelection == last.id)
    }

    /// Pressing New design on the Shepherd UI page draws the new design in Shepherd UI, even when a system built from
    /// a project exists (which is what New design otherwise defaults to), and sending creates a design that
    /// installed it.
    @Test func newDesignOnTheBuiltInPageDrawsInTheBuiltInSystemNotTheDefaultOne() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.startingADesign() }
        }
    }

    @MainActor
    private static func startingADesign() async throws {
        try StubPi.installAsEngine()
        AccessibilityNode.enable()
        let app = try AppHarness()
        defer { app.stop() }
        app.settings.designToolEnabled = true
        app.server.designSystems.register(NightWatchSystem.builtIn())
        let vm = try await app.start()
        vm.designNetwork = .none
        // A system built here: the one New design would otherwise pick.
        let owner = Design(name: "acme", createdAt: 1_000, buildsSystem: true)
        _ = try await app.server.createDesign(owner)
        _ = try await app.server.writeDesignSystem(DesignSystemWrite(
            namespace: "acme-web",
            tokens: .object(["format": .string(DesignSystemTokens.format), "name": .string("acme-web"),
                             "colors": .array([.object(["name": .string("--accent"), "value": .string("#4f46e5")])])]),
            files: ["README.md": .string("# acme-web\n")]), for: owner.id)
        vm.adopt(app.server.state)
        await vm.loadDesignSystems()
        let builtIn = NightWatchSystem.namespace
        try #require(vm.designSystems.summary("acme-web") != nil)
        #expect(NewDesignState.defaultSystem(in: vm.designSystems.summaries)?.namespace == "acme-web",
                "without the fix this is where New design would draw")

        vm.openDesignSystem(builtIn)
        let window = OffscreenWindow(size: CGSize(width: 1208, height: 900), dark: true, DesignSystemDestination(vm: vm))
        defer { window.close() }
        try await eventuallyOnMain("the page") { window.controls().contains { $0.label == "New design" } }
        try window.press("New design")
        #expect(vm.shownDestination == .newDesign)
        #expect(vm.newDesign.systemToInstall(vm) == builtIn, "New design opened drawing in \(String(describing: vm.newDesign.systemToInstall(vm)))")
        #expect(vm.newDesign.system == builtIn)
        // The card on the page shows the chosen system, not the default.
        let card = NewDesignState.card(system: vm.newDesign.chosenSystem(in: vm.designSystems.summaries), spaces: vm.state.spaces)
        #expect(card.title == builtIn, "the card names \(card.title)")

        // Send: the design that is made installed the built-in system and no other.
        vm.newDesign.brief = "A settings page"
        vm.newDesign.send(vm)
        try await eventuallyOnMain("the design to open") { vm.shownDesign != nil && !vm.newDesign.starting }
        let design = try #require(vm.shownDesign)
        #expect(design.systemNamespace == builtIn, "the design installed \(String(describing: design.systemNamespace))")
        let snapshot = try await app.server.designSnapshot(design.id)
        #expect(snapshot.index.designSystems?.map(\.namespace) == [builtIn])

        // Another system's own entry points are unchanged: opening New design from the Designs page keeps the default.
        vm.newDesign.choose(system: "acme-web")
        vm.openNewDesign()
        #expect(vm.newDesign.systemToInstall(vm) == "acme-web", "openNewDesign() with no system keeps what was picked")
    }

    @MainActor
    private static func filtering() async throws {
        AccessibilityNode.enable()
        let app = try AppHarness()
        defer { app.stop() }
        app.settings.designToolEnabled = true
        app.server.designSystems.register(NightWatchSystem.builtIn())
        let vm = try await app.start()
        await vm.loadDesignSystems()
        vm.openDesignSystem(NightWatchSystem.namespace)
        let window = OffscreenWindow(size: CGSize(width: 1208, height: 900), dark: true, DesignSystemDestination(vm: vm))
        defer { window.close() }
        func specimens() -> [String] {
            window.layout()
            return AccessibilityNode.all(under: window.host).compactMap(\.label).filter { $0.hasSuffix(" specimen") }
        }
        // Every catalog entry is drawn before a group is chosen.
        try await eventuallyOnMain("the catalog") { specimens().count == NWComponentCatalog.entries.count }
        let group = try #require(NWComponentCatalog.groups.first)
        let expected = NWComponentCatalog.entries.filter { $0.group == group }.map { "\($0.id) specimen" }
        #expect(expected.count < NWComponentCatalog.entries.count, "the group must narrow the list for this test to mean anything")
        let popup = try #require(AccessibilityNode.all(under: window.host).first { node in
            node.role == ControlRole.menuButton
                && (node.object.perform(NSSelectorFromString("accessibilityHelp"))?.takeUnretainedValue() as? String) == "Component group"
        })
        let offered = try await NativeMenuChoice.choose(group, from: popup)
        #expect(offered == [NWComponentCatalog.allGroups] + NWComponentCatalog.groups, "All groups first, then each group: \(offered)")
        try await eventuallyOnMain("the list to narrow to \(group)") { specimens() == expected }
    }

    @MainActor
    private static func pressing() async throws {
        AccessibilityNode.enable()
        let app = try AppHarness()
        defer { app.stop() }
        app.settings.designToolEnabled = true
        app.server.designSystems.register(NightWatchSystem.builtIn())
        let vm = try await app.start()
        var design = Design(name: "Refund ledger", createdAt: 3_000, boardCount: 4)
        design.systemNamespace = NightWatchSystem.namespace
        _ = try await app.server.createDesign(design)
        vm.adopt(app.server.state)
        await vm.loadDesignSystems()
        vm.openDesignSystem(NightWatchSystem.namespace)
        let reference = try #require(vm.designSystemPage(.system(NightWatchSystem.namespace)).reference)
        let colors = "Colors, \(reference.colorCount)"
        let window = OffscreenWindow(size: CGSize(width: 1208, height: 900), dark: true, DesignSystemDestination(vm: vm))
        defer { window.close() }
        try await eventuallyOnMain("the page's header") { window.controls().contains { $0.label == "New design" } }
        let offered = window.controls().map(\.description).joined(separator: "; ")

        // Honest affordances: nothing is drawn that edits, adds or opens a component.
        for forbidden in ["Add", "Edit", "Open"] {
            #expect(!window.controls().contains { $0.label?.hasPrefix(forbidden) == true }, "\(forbidden) must not be drawn: \(offered)")
        }
        // Specimens are pictures: nothing in the catalog is pressable.
        for specimen in ["Start the agent", "Review", "Not now", "Delete thread", "Learn from threads", "Standard", "Fast"] {
            #expect(!window.controls().contains { $0.label == specimen }, "\(specimen) is a specimen and must not be a control: \(offered)")
        }
        // The page's own controls clear 24pt. The breadcrumb (17pt tall) and the segmented picker's
        // segments (22pt wide in the tree) are the shared header's and picker's, unchanged here.
        let own = window.controls().filter { ["New design", "Contents"].contains($0.label ?? "") || $0.label?.contains(", ") == true }
        #expect(ControlPress.undersized(own, minimum: .desktop).isEmpty, "\(offered)")

        // Dark | Light.
        // The window is dark. Light lays the whole page out in the light appearance; Dark puts it back.
        // The picker reports its own value, so the press is read back from the tree, not assumed.
        func chosen() -> String? {
            window.layout()
            return AccessibilityNode.all(under: window.host).first { $0.role == ControlRole.radioButton && $0.isSelected }?.label
        }
        #expect(chosen() == "Dark", "the page starts in the window's appearance")
        try window.press("Light", role: ControlRole.radioButton)
        try await eventuallyOnMain("Light to be chosen") { chosen() == "Light" }
        try window.press("Dark", role: ControlRole.radioButton)
        try await eventuallyOnMain("Dark to be chosen") { chosen() == "Dark" }

        // The contents button opens the menu; a row closes it; a Used by row opens that design.
        let contents = try window.press("Contents")
        #expect(ControlPress.undersized([contents], minimum: .desktop).isEmpty)
        do { try await eventuallyOnMain("the contents menu", timeout: .seconds(5)) { window.controls().contains { $0.label == colors } } }
        catch { throw NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "menu did not open; window offers: \(window.controls().map(\.description).joined(separator: "; "))"]) }
        try window.press("Refund ledger, \(reference.used[0].boards)")
        try await eventuallyOnMain("the design to open") { vm.shownDestination != .designSystem }
        #expect(vm.designsPageSelection == design.id)

        // New design opens the existing flow.
        vm.openDesignSystem(NightWatchSystem.namespace)
        window.show(DesignSystemDestination(vm: vm))
        try await eventuallyOnMain("the page again") { window.controls().contains { $0.label == "New design" } }
        let contentsAgain = try window.press("Contents")
        _ = contentsAgain
        try await eventuallyOnMain("the menu again") { window.controls().contains { $0.label == colors } }
        try window.press("Size, \(reference.sizes.count)")
        try await eventuallyOnMain("the menu to close") { !window.controls().contains { $0.label == colors } }
        try await eventuallyOnMain("the page to scroll to Size") { onScreen("Size", in: window) }
        #expect(!onScreen("Principles", in: window), "pressing a part moves the page to it, not just closes the menu")
        try window.press("New design")
        #expect(vm.shownDestination == .newDesign)
        #expect(vm.newDesign.system == NightWatchSystem.namespace, "New design opens drawing in the system the page shows")

        // The breadcrumb goes back to the Designs page.
        vm.openDesignSystem(NightWatchSystem.namespace)
        window.show(DesignSystemDestination(vm: vm))
        try await eventuallyOnMain("the page a third time") { window.controls().contains { $0.label == "Design systems" } }
        try window.press("Design systems")
        #expect(vm.shownDestination == .designs)
    }
}
