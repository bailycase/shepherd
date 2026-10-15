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

/// A design system's page (DesignSystemPage and its eight sibling boards), drawn for a system the user built,
/// every control it draws pressed through accessibility on a real scratch server: Dark and Light, Re-sync, New
/// design, the contents button and its rows, the group popup, More and the breadcrumb. Each must do what it says,
/// with a hit area of at least 24pt. The page draws no Edit, Add or component open control, and the test says so.
@Suite("Design system reference controls", .integrationTimeLimit)
struct DesignSystemReferenceControlTests {
    /// A system as a design's agent writes it with system_write: Shepherd UI's colors in light and dark, page
    /// copy, and three components, two with a specimen in two groups.
    @MainActor
    static func writeShepherdUI(_ app: AppHarness, sources: [String] = []) async throws -> Design {
        let owner = Design(name: "Shepherd chat UI", createdAt: 1_000)
        _ = try await app.server.createDesign(owner)
        func color(_ name: String, _ light: String, _ dark: String) -> JSONValue {
            .object(["name": .string(name), "value": .string(light), "dark": .string(dark)])
        }
        func component(_ name: String, group: String, specimen: Bool) -> JSONValue {
            var fields: [String: JSONValue] = ["name": .string(name), "export": .string("Shepherd.\(name)"), "group": .string(group)]
            if specimen { fields["specimen"] = .string("components/\(name).html") }
            return .object(fields)
        }
        let tokens: JSONValue = .object([
            "format": .string(DesignSystemTokens.format), "name": .string("Shepherd UI"),
            "colors": .array([color("--bg-window", "#fbfbfa", "#0d0e10"), color("--bg-raised", "#ffffff", "#15171a"),
                              color("--text-primary", "#151618", "#e8e9ec"), color("--lantern", "#e39a26", "#f2a93b")]),
            "type": .array([.object(["name": .string("title"), "size": .number(15), "weight": .number(600), "family": .string("Geist")])]),
            "spacing": .array([.object(["name": .string("--space-m"), "px": .number(8)])]),
            "radii": .array([.object(["name": .string("--radius-s"), "px": .number(6), "use": .string("buttons, fields, rows")])]),
            "components": .array([component("SettingsButton", group: "Settings", specimen: true),
                                  component("ThreadChip", group: "Chat & agents", specimen: true),
                                  component("AttachButton", group: "Chat & agents", specimen: false)]),
            "page": .object(["tagline": .string("The app’s own components and tokens."),
                             "principles": .array([.object(["lead": .string("Readable measure."), "text": .string("Prose at most 640pt.")])]),
                             "sizes": .array([.object(["name": .string("control"), "value": .string("32px"), "use": .string("Buttons")])])]),
        ])
        let specimen = "<div style=\"display:flex;gap:8px;padding:8px\"><span style=\"height:28px;padding:0 12px;border-radius:6px;"
            + "background:var(--lantern)\">Save</span></div>\n"
        _ = try await app.server.writeDesignSystem(DesignSystemWrite(
            namespace: "shepherd-ui", title: "Shepherd UI", tokens: tokens,
            files: ["README.md": .string("# Shepherd UI\n"), "components/SettingsButton.html": .string(specimen),
                    "components/ThreadChip.html": .string(specimen)],
            sources: sources.isEmpty ? nil : sources), for: owner.id)
        return owner
    }

    @Test func everyControlOnASystemsPageDoesWhatItSays() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.pressing() }
        }
    }

    /// A native menu is chosen with `NativeMenuChoice`, which leaves its tracking open, so the popup has a scenario of its own.
    @Test func theComponentGroupPopupFiltersTheSystemsComponentsToOneGroup() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.filtering() }
        }
    }

    @Test func theMoreMenuStaysAndItsDuplicateActionMakesACopy() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.duplicating() }
        }
    }

    @Test func withManyDesignsInAShortWindowTheContentsMenuStaysInsideItAndReachesTheLastOne() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.overflowing() }
        }
    }

    /// Pressing New design on a system's page draws the new design in that system, even when another system is the
    /// default, and sending creates a design that installed it.
    @Test func newDesignOnASystemsPageDrawsInThatSystemNotTheDefaultOne() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.startingADesign() }
        }
    }

    /// Whether a heading by this label is inside the window right now: its accessibility frame meets the window's.
    @MainActor
    private static func onScreen(_ label: String, in window: OffscreenWindow) -> Bool {
        window.layout()
        let area = window.window.frame
        return AccessibilityNode.all(under: window.host).contains { $0.label == label && $0.frame.intersects(area) }
    }

    @MainActor
    private static func more(in window: OffscreenWindow, _ help: String) -> AccessibilityNode? {
        AccessibilityNode.all(under: window.host).first { node in
            node.role == ControlRole.menuButton
                && (node.object.perform(NSSelectorFromString("accessibilityHelp"))?.takeUnretainedValue() as? String) == help
        }
    }

    @MainActor
    private static func duplicating() async throws {
        AccessibilityNode.enable()
        let app = try AppHarness()
        defer { app.stop() }
        app.settings.designToolEnabled = true
        let vm = try await app.start()
        _ = try await writeShepherdUI(app)
        vm.adopt(app.server.state)
        await vm.loadDesignSystems()
        vm.openDesignSystem("shepherd-ui")
        let window = OffscreenWindow(size: CGSize(width: 1208, height: 900), dark: true, DesignSystemDestination(vm: vm))
        defer { window.close() }
        try await eventuallyOnMain("the page") { window.controls().contains { $0.label == "New design" } }
        let more = try #require(Self.more(in: window, "More for Shepherd UI"), "the page keeps its More menu")
        let offered = try await NativeMenuChoice.choose("Duplicate", from: more)
        #expect(offered.contains("Duplicate") && offered.contains("Rename…"), "a user's system's menu: \(offered)")
        try await eventuallyOnMain("the copy to be made and opened") {
            vm.shownDesignSystem == "shepherd-ui-copy" && vm.designSystems.summary("shepherd-ui-copy") != nil
        }
        // The copy is drawn on the same page, with the copy's own title.
        try await eventuallyOnMain("the copy's page") { vm.designSystemPage(.system("shepherd-ui-copy")).reference != nil }
    }

    @MainActor
    private static func overflowing() async throws {
        AccessibilityNode.enable()
        let app = try AppHarness()
        defer { app.stop() }
        app.settings.designToolEnabled = true
        let vm = try await app.start()
        _ = try await writeShepherdUI(app)
        for index in 1...14 {
            var design = Design(name: "Design \(index) with a rather long name that has to truncate", createdAt: Double(3_000 + index), boardCount: index)
            design.systemNamespace = "shepherd-ui"
            _ = try await app.server.createDesign(design)
        }
        vm.adopt(app.server.state)
        await vm.loadDesignSystems()
        vm.openDesignSystem("shepherd-ui")
        let reference = try #require(vm.designSystemPage(.system("shepherd-ui")).reference)
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
        #expect(rows.contains { $0.frame.minY < area.minY || $0.frame.maxY > area.maxY || !area.contains($0.frame) },
                "some rows lie past the window, so the menu scrolls instead of growing")
        let last = try #require(reference.used.last)
        try window.press("\(last.name), \(last.boards)")
        try await eventuallyOnMain("the last design to open") { vm.shownDestination != .designSystem }
        #expect(vm.designsPageSelection == last.id)
    }

    @MainActor
    private static func startingADesign() async throws {
        try StubPi.installAsEngine()
        AccessibilityNode.enable()
        let app = try AppHarness()
        defer { app.stop() }
        app.settings.designToolEnabled = true
        let vm = try await app.start()
        vm.designNetwork = .none
        _ = try await writeShepherdUI(app)
        // A system built from a project: the one New design would otherwise pick.
        let builder = Design(name: "acme", createdAt: 2_000, buildsSystem: true)
        _ = try await app.server.createDesign(builder)
        _ = try await app.server.writeDesignSystem(DesignSystemWrite(
            namespace: "acme-web",
            tokens: .object(["format": .string(DesignSystemTokens.format), "name": .string("acme-web"),
                             "colors": .array([.object(["name": .string("--accent"), "value": .string("#4f46e5")])])]),
            files: ["README.md": .string("# acme-web\n")]), for: builder.id)
        vm.adopt(app.server.state)
        await vm.loadDesignSystems()
        #expect(NewDesignState.defaultSystem(in: vm.designSystems.summaries)?.namespace == "acme-web",
                "without the fix this is where New design would draw")

        vm.openDesignSystem("shepherd-ui")
        let window = OffscreenWindow(size: CGSize(width: 1208, height: 900), dark: true, DesignSystemDestination(vm: vm))
        defer { window.close() }
        try await eventuallyOnMain("the page") { window.controls().contains { $0.label == "New design" } }
        try window.press("New design")
        #expect(vm.shownDestination == .newDesign)
        #expect(vm.newDesign.systemToInstall(vm) == "shepherd-ui", "New design opened drawing in \(String(describing: vm.newDesign.systemToInstall(vm)))")

        // Send: the design that is made installed the page's system and no other.
        vm.newDesign.brief = "A settings page"
        vm.newDesign.send(vm)
        try await eventuallyOnMain("the design to open") { vm.shownDesign != nil && !vm.newDesign.starting }
        let design = try #require(vm.shownDesign)
        #expect(design.systemNamespace == "shepherd-ui")
        let snapshot = try await app.server.designSnapshot(design.id)
        #expect(snapshot.index.designSystems?.map(\.namespace) == ["shepherd-ui"])
    }

    @MainActor
    private static func filtering() async throws {
        AccessibilityNode.enable()
        let app = try AppHarness()
        defer { app.stop() }
        app.settings.designToolEnabled = true
        let vm = try await app.start()
        vm.designNetwork = .none
        _ = try await writeShepherdUI(app)
        vm.adopt(app.server.state)
        await vm.loadDesignSystems()
        vm.openDesignSystem("shepherd-ui")
        let window = OffscreenWindow(size: CGSize(width: 1208, height: 900), dark: true, DesignSystemDestination(vm: vm))
        defer { window.close() }
        func specimens() -> [String] {
            window.layout()
            return AccessibilityNode.all(under: window.host).compactMap(\.label).filter { $0.hasSuffix(" specimen") }
        }
        try await eventuallyOnMain("the page") { window.controls().contains { $0.label == "Contents" } }
        try window.press("Contents")
        try await eventuallyOnMain("the menu") { window.controls().contains { $0.label?.hasPrefix("Components") == true } }
        try window.press("Components, 3")
        // The components with a specimen are drawn; the one without is counted, not drawn.
        try await eventuallyOnMain("the components") { specimens() == ["SettingsButton specimen", "ThreadChip specimen"] }
        // The footnote ends a lazy list: it is built once the page has scrolled to it, as a reader scrolls.
        let page = try #require(ListPerf.scrollView(in: window))
        ListPerf.jump(window, page, toEnd: true)
        try await eventuallyOnMain("the footnote under the components") {
            window.layout()
            return AccessibilityNode.all(under: window.host).contains { $0.label == "Showing 2 of 3, the ones with a specimen." }
        }
        let popup = try #require(Self.more(in: window, "Component group"))
        let offered = try await NativeMenuChoice.choose("Chat & agents", from: popup)
        #expect(offered == ["All groups", "Settings", "Chat & agents"], "All groups first, then each group: \(offered)")
        try await eventuallyOnMain("the list to narrow to Chat & agents") { specimens() == ["ThreadChip specimen"] }
    }

    @MainActor
    private static func pressing() async throws {
        AccessibilityNode.enable()
        let app = try AppHarness()
        defer { app.stop() }
        app.settings.designToolEnabled = true
        let vm = try await app.start()
        vm.designNetwork = .none
        _ = try await writeShepherdUI(app)
        var design = Design(name: "Refund ledger", createdAt: 3_000, boardCount: 4)
        design.systemNamespace = "shepherd-ui"
        _ = try await app.server.createDesign(design)
        vm.adopt(app.server.state)
        await vm.loadDesignSystems()
        vm.openDesignSystem("shepherd-ui")
        let reference = try #require(vm.designSystemPage(.system("shepherd-ui")).reference)
        let colors = "Colors, \(reference.colorCount)"
        let window = OffscreenWindow(size: CGSize(width: 1208, height: 900), dark: true, DesignSystemDestination(vm: vm))
        defer { window.close() }
        try await eventuallyOnMain("the page's header") { window.controls().contains { $0.label == "New design" } }
        let offered = window.controls().map(\.description).joined(separator: "; ")

        // Honest affordances: nothing is drawn that edits, adds or opens a component, and no Re-sync for a system
        // with nothing to read again.
        for forbidden in ["Add", "Edit", "Open", "Re-sync"] {
            #expect(!window.controls().contains { $0.label?.hasPrefix(forbidden) == true }, "\(forbidden) must not be drawn: \(offered)")
        }
        #expect(AccessibilityNode.all(under: window.host).contains { $0.label == "Shepherd UI" }, "the hero names the system")
        // The page's own controls meet the desktop hit area; the segments are the shared picker's.
        let own = window.controls().filter { ["New design", "Contents"].contains($0.label ?? "") }
        #expect(own.count == 2 && ControlPress.undersized(own, minimum: .desktop).isEmpty, "\(offered)")

        // Dark | Light: the picker reports its own value, so the press is read back from the tree, not assumed.
        func chosen() -> String? {
            window.layout()
            return AccessibilityNode.all(under: window.host).first { $0.role == ControlRole.radioButton && $0.isSelected }?.label
        }
        #expect(chosen() == "Dark", "the page starts in the window's appearance")
        try window.press("Light", role: ControlRole.radioButton)
        try await eventuallyOnMain("Light to be chosen") { chosen() == "Light" }
        try window.press("Dark", role: ControlRole.radioButton)
        try await eventuallyOnMain("Dark to be chosen") { chosen() == "Dark" }

        // The contents button opens the menu with the system's parts; a Used by row opens that design.
        let contents = try window.press("Contents")
        #expect(ControlPress.undersized([contents], minimum: .desktop).isEmpty)
        try await eventuallyOnMain("the contents menu", timeout: .seconds(5)) { window.controls().contains { $0.label == colors } }
        #expect(!window.controls().contains { $0.label?.hasPrefix("Voice") == true }, "a system with no voice copy has no Voice part")
        try window.press("Refund ledger, \(reference.used[0].boards)")
        try await eventuallyOnMain("the design to open") { vm.shownDestination != .designSystem }
        #expect(vm.designsPageSelection == design.id)

        // A part scrolls the page to it and closes the menu.
        vm.openDesignSystem("shepherd-ui")
        window.show(DesignSystemDestination(vm: vm))
        try await eventuallyOnMain("the page again") { window.controls().contains { $0.label == "Contents" } }
        try window.press("Contents")
        try await eventuallyOnMain("the menu again") { window.controls().contains { $0.label == colors } }
        try window.press("Size, 1")
        try await eventuallyOnMain("the menu to close") { !window.controls().contains { $0.label == colors } }
        try await eventuallyOnMain("the page to scroll to Size") { onScreen("Size", in: window) }
        #expect(!onScreen("Principles", in: window), "pressing a part moves the page to it, not just closes the menu")

        // The breadcrumb goes back to the Designs page.
        try window.press("Design systems")
        #expect(vm.shownDestination == .designs)
    }

    @Test func reSyncOnAProjectsSystemReadsItsStylesheetsAgain() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.resyncing() }
        }
    }

    /// A system built from a project draws Re-sync in the header, and pressing it reads the stylesheet again.
    @MainActor
    private static func resyncing() async throws {
        AccessibilityNode.enable()
        let app = try AppHarness()
        defer { app.stop() }
        app.settings.designToolEnabled = true
        let repo = try makeScratchDirectory("dashboard-web")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("web"), withIntermediateDirectories: true)
        try Data(":root {\n  --accent: #4f46e5;\n}\n".utf8).write(to: repo.appendingPathComponent("web/tokens.css"))
        let space = Fixture.space("dashboard-web", path: repo.path)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: []))
        vm.designNetwork = .none
        var build = Design(name: "acme", createdAt: 1_000, buildsSystem: true)
        build.sourceSpaceID = space.id
        _ = try await app.server.createDesign(build)
        _ = try await app.server.writeDesignSystem(DesignSystemWrite(
            namespace: "acme-web",
            tokens: .object(["format": .string(DesignSystemTokens.format), "name": .string("acme-web"),
                             "colors": .array([.object(["name": .string("--accent"), "value": .string("#4f46e5"),
                                                        "source": .object(["file": .string("web/tokens.css"), "line": .number(2)])])])]),
            files: ["README.md": .string("# acme-web\n")], sources: ["web/tokens.css"]), for: build.id)
        vm.adopt(app.server.state)
        await vm.loadDesignSystems()
        // The build itself opens as its agent's layout; the page is the Design systems destination.
        vm.lastDesignSystem = .system("acme-web")
        vm.shownDesignSystem = "acme-web"
        vm.openDestination(.designSystem)
        let window = OffscreenWindow(size: CGSize(width: 1208, height: 900), dark: true, DesignSystemDestination(vm: vm))
        defer { window.close() }
        try await eventuallyOnMain("Re-sync") { window.controls().contains { $0.label == "Re-sync" } }
        // The project's stylesheet changes; Re-sync takes the new value.
        try Data(":root {\n  --accent: #e11d48;\n}\n".utf8).write(to: repo.appendingPathComponent("web/tokens.css"))
        let resync = try window.press("Re-sync")
        #expect(ControlPress.undersized([resync], minimum: .desktop).isEmpty)
        try await eventuallyOnMain("the new value") {
            vm.designSystems.tokens("acme-web")?.colors.first?.value == "#e11d48"
        }
        try await eventuallyOnMain("the page to show it") {
            vm.designSystemPage(.system("acme-web")).reference?.colors.first?.rows.first?.light == "#e11d48"
        }
    }
}
