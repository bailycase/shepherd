import AppKit
import Foundation
import ShepherdCore
import ShepherdTestSupport
import ShepherdUI
import CoreText
import SwiftUI
import Testing
import WebKit
@testable import ShepherdApp

@MainActor
@Suite("Project Browser controls", .mainActorExclusive)
struct ProjectBrowserControlTests {
    @Test func staleWebKitReadbackStopsAfterTwentyRefreshAttempts() async {
        var reads = 0, clears = 0
        let scope = ProjectCookieScope(projectID: SpaceID(), hostID: nil)
        let model = ProjectCookiesModel(read: { _ in reads += 1; return [BrowserCookieSite(site: "stale.test", count: 1)] }, clear: { _, _ in clears += 1 })
        await model.load(scope); model.ask(.all)
        await model.confirm(scope)
        #expect(clears == 1 && reads == 21)
        #expect(!model.clearing && model.error == nil && model.notice?.contains("created new cookies") == true)
    }

    @Test func clearControlsDeleteOnlyTheConfirmedSiteInTheSelectedProject() async throws {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.pressControls() }
        }
    }

    @Test @MainActor func fractionalFontsKeepTheBoardsTextWidths() {
        NWFonts.register()
        let scale = ThemeStore.shared.textScale
        defer { ThemeStore.shared.textScale = scale }
        ThemeStore.shared.textScale = 1
        let sample = "Browser tabs in all threads and worktrees for payments share cookies on this Mac. Other spaces"
        let font = CTFontCreateWithName("Geist-Regular" as CFString, 13.5, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: sample, attributes: [.font: font]))
        let expected = CTLineGetTypographicBounds(line, nil, nil, nil)
        let host = NSHostingView(rootView: Text(sample).font(.nwSans(13.5)).fixedSize())
        #expect(abs(host.fittingSize.width - expected) <= 1)
        #expect(expected < 610, "13.5pt Geist must not round up to 14pt")
    }

    @Test func projectsAndBrowserFillTheSettingsWidthAfterNavigationAndResize() async throws {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.checkLayout() }
        }
    }

    private static func checkLayout() async throws {
        try StubPi.installAsEngine()
        AccessibilityNode.enable()
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await app.start()
        let directory = app.dir.appendingPathComponent("payments")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "# Project instructions\n".write(to: directory.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        try await app.server.addSpace(Space(name: "payments", path: directory.path), first: false)
        await vm.projects.load(vm.projectsSources)
        let row = try #require(vm.projects.rows.first { $0.project.directory == directory.path })
        vm.settingsSection = .projects; vm.showSettings = true
        let window = OffscreenWindow(size: CGSize(width: 1440, height: 900), dark: true, RootView(vm: vm))
        defer { window.close() }
        try await eventuallyOnMain("Projects list in the Settings overlay") {
            window.layout()
            return AccessibilityNode.all(under: window.host).contains { $0.label == "Open payments" }
        }
        func column(_ identifier: String) throws -> CGRect {
            let selector = NSSelectorFromString("accessibilityIdentifier")
            let node = try #require(AccessibilityNode.all(under: window.host).first {
                $0.object.responds(to: selector) && $0.object.perform(selector)?.takeUnretainedValue() as? String == identifier
            })
            return window.host.convert(window.window.convertFromScreen(node.frame), from: nil)
        }
        let list = try column("ProjectsTable")
        #expect(abs(list.width - 1128) <= 1, "the table fills the page: \(list)")
        try ControlPress.press("Open payments", under: window.host)
        try await eventuallyOnMain("project detail in the Settings overlay") {
            window.layout()
            return AccessibilityNode.all(under: window.host).contains { $0.label == "Space category Browser" }
        }
        let editor = try column("ProjectEditorColumn"), context = try column("ProjectContextColumn")
        #expect(abs(editor.minX - 272) <= 1 && abs(editor.width - 858) <= 1)
        #expect(abs(context.width - 250) <= 1 && abs(context.minX - editor.maxX - 20) <= 1)
        let textScale = ThemeStore.shared.textScale
        defer { ThemeStore.shared.textScale = textScale }
        for scale in [1.0, 1.3] {
            ThemeStore.shared.textScale = scale
            window.window.setContentSize(CGSize(width: 1050, height: 900))
            window.layout()
            for scroll in nativeScrollViews(window.host) {
                scroll.scrollerStyle = .legacy; scroll.autohidesScrollers = false
            }
            try await eventuallyOnMain("the narrow project editor to stack its context") {
                window.layout()
                let nodes = AccessibilityNode.all(under: window.host)
                return abs(window.host.bounds.width - 1050) <= 1 && vm.projects.fileLoaded && !vm.projects.saving
                    && nodes.contains { $0.label == "Save" } && nodes.contains { $0.label == "Open in editor" }
                    && (try? column("ProjectContextColumn").minY > column("ProjectEditorColumn").maxY) == true
            }
            let narrowEditor = try column("ProjectEditorColumn"), narrowContext = try column("ProjectContextColumn")
            let availableWidth = window.host.bounds.width - 312
            let scrollbarSpace = nativeScrollViews(window.host).map {
                max(0, $0.bounds.width - $0.contentView.bounds.width)
            }.max() ?? 0
            // macOS 26 reports the outer AX group; 27 reports its clipped children.
            // Both must fill the available column, excluding only native scrollbar space.
            #expect(abs(narrowEditor.minX - 272) <= 1)
            #expect(abs(narrowEditor.width - availableWidth) <= 1
                    || abs(narrowEditor.width - (availableWidth - scrollbarSpace)) <= 1,
                    "Editor \(narrowEditor) fills \(availableWidth)pt with \(scrollbarSpace)pt scrollbar space at text scale \(scale)")
            #expect(abs(narrowContext.width - narrowEditor.width) <= 1 && abs(narrowContext.minX - narrowEditor.minX) <= 1)
            for label in ["Save", "Open in editor"] {
                let control = try #require(AccessibilityNode.all(under: window.host).first { $0.label == label })
                let frame = window.host.convert(window.window.convertFromScreen(control.frame), from: nil)
                #expect(control.isEnabled && frame.width >= 24 && frame.height >= 24)
                #expect(frame.minX >= 272 && frame.maxX <= 1010 && frame.minY >= 0 && frame.maxY <= 900,
                        "\(label) stays in the narrow viewport at text scale \(scale)")
            }
            let savedText = vm.projects.draft + "# Saved at text scale \(scale)\n"
            vm.projects.draft = savedText
            window.layout()
            let save = try ControlPress.press("Save", under: window.host)
            #expect(save.isEnabled)
            try await eventuallyOnMain("the narrow editor's save to finish") {
                vm.projects.saved == savedText && !vm.projects.saving && vm.projects.fileLoaded && !vm.projects.dirty
            }
            #expect(try String(contentsOf: directory.appendingPathComponent("AGENTS.md"), encoding: .utf8) == savedText)
        }
        ThemeStore.shared.textScale = textScale
        window.window.setContentSize(CGSize(width: 1440, height: 900))
        try await eventuallyOnMain("the wide project editor to restore its context rail") {
            window.layout()
            return abs(window.host.bounds.width - 1440) <= 1 && (try? column("ProjectContextColumn").width) == 250
                && !vm.projects.saving && AccessibilityNode.all(under: window.host).contains { $0.label == "Space category Browser" && $0.isEnabled }
        }
        #expect(!vm.projects.dirty)
        try ControlPress.press("Space category Browser", under: window.host)
        try await eventuallyOnMain("Browser table in the Settings overlay") {
            window.layout()
            return !vm.projectCookies.loading && AccessibilityNode.all(under: window.host).contains { $0.label == "Sites with cookies" }
        }
        func frame(_ label: String) throws -> CGRect {
            let node = try #require(AccessibilityNode.all(under: window.host).first { $0.label == label || $0.value == label })
            return window.host.convert(window.window.convertFromScreen(node.frame), from: nil)
        }
        let table = try frame("Sites with cookies")
        #expect(abs(table.width - 1128) <= 1, "Browser fills the available Settings width")
        #expect(abs(table.minX - 272) <= 1, "Browser uses the same 40pt gutter as Skills")
        #expect(abs(table.height - 235) <= 1, "the empty table has a 32pt header, 200pt body and border insets")
        #expect(abs(table.minY - 335) <= 1, "the Browser groups follow the board's vertical spacing: \(table)")
        let description = try frame("Browser tabs in all threads and worktrees for payments share cookies on this Mac. Other spaces use separate cookies.")
        #expect(description.minX >= table.minX && description.maxX <= table.minX + 620,
                "the rendered explanation stays within the board's 620pt text measure")
        #expect(abs(try frame("Back to Spaces").minX - table.minX) <= 1)
        for size in [CGSize(width: 1050, height: 900), CGSize(width: 1267, height: 900), CGSize(width: 1800, height: 1000), CGSize(width: 1440, height: 900)] {
            window.window.setContentSize(size)
            try await eventuallyOnMain("the Settings host to adopt its resized width") {
                window.layout()
                return abs(window.host.bounds.width - size.width) <= 1
            }
            let resizedTable = try frame("Sites with cookies")
            #expect(abs(resizedTable.width - (size.width - 312)) <= 1, "Browser follows the available width after a resize")
            #expect(abs(resizedTable.minX - 272) <= 1)
            #expect(abs(try frame("Back to Spaces").minX - resizedTable.minX) <= 1)
        }
        ThemeStore.shared.textScale = 1.3
        window.layout()
        #expect(abs(try frame("Sites with cookies").width - 1128) <= 1)
        let back = try ControlPress.press("Back to Spaces", under: window.host)
        #expect(back.isEnabled)
        try await eventuallyOnMain("return to the full-width Projects list") { vm.projects.selected == nil }
        window.layout()
        #expect(abs(try column("ProjectsTable").width - 1128) <= 1)
    }

    private static func nativeScrollViews(_ view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(nativeScrollViews)
    }

    private static func pressControls() async throws {
        try StubPi.installAsEngine()
        AccessibilityNode.enable()
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await app.start()
        let project = Space(name: "payments", path: app.dir.appendingPathComponent("payments").path)
        let other = Space(name: "unrelated", path: app.dir.appendingPathComponent("unrelated").path)
        for space in [project, other] { try FileManager.default.createDirectory(atPath: space.path, withIntermediateDirectories: true) }
        try await app.server.addSpace(project, first: false)
        try await app.server.addSpace(other, first: false)
        let mine = Agent(name: "mine", spaceID: project.id, tabID: TabID())
        let sibling = Agent(name: "sibling", spaceID: project.id, tabID: TabID())
        let unrelated = Agent(name: "other", spaceID: other.id, tabID: TabID())
        var state = vm.state; state.agents += [mine, sibling, unrelated]
        vm.browsers.prune(state: state)
        for agent in [mine, sibling, unrelated] { vm.browsers.session(for: agent.id).load(URL(string: "about:blank")!) }
        let store = try #require(vm.browsers.existing(mine.id)?.webView?.configuration.websiteDataStore)
        let otherStore = try #require(vm.browsers.existing(unrelated.id)?.webView?.configuration.websiteDataStore)
        let one = try #require(HTTPCookie(properties: [.domain: "one.test", .path: "/", .name: "private-name", .value: "private-value"]))
        let two = try #require(HTTPCookie(properties: [.domain: "two.test", .path: "/", .name: "secret-name", .value: "secret-value"]))
        await store.httpCookieStore.setCookie(one); await store.httpCookieStore.setCookie(two)
        await otherStore.httpCookieStore.setCookie(one)
        await vm.projects.load(vm.projectsSources)
        let row = try #require(vm.projects.rows.first { $0.project.directory == project.path })
        await vm.projects.open(row)
        await vm.projects.navigate(.browser)
        let scope = try #require(vm.cookieScope(for: row))
        await vm.projectCookies.load(scope)
        vm.showSettings = true; vm.settingsSection = .projects
        let window = OffscreenWindow(size: CGSize(width: 1440, height: 900), dark: true, RootView(vm: vm))
        defer { window.close() }
        try await eventuallyOnMain("cookie controls") { window.layout(); return AccessibilityNode.all(under: window.host).contains { $0.label == "Clear cookies for one.test" } }
        let nodes = AccessibilityNode.all(under: window.host)
        let siteFilter = try #require(nodes.first { $0.label == "Filter sites" && $0.role == "AXTextField" })
        let setter = NSSelectorFromString("setAccessibilityValue:")
        #expect(siteFilter.object.responds(to: setter))
        _ = siteFilter.object.perform(setter, with: "one.test")
        func nativeInput(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.placeholderString == "Filter sites" || field.stringValue == "one.test" { return field }
            return view.subviews.lazy.compactMap(nativeInput).first
        }
        if let field = nativeInput(window.host) {
            field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        }
        try await eventuallyOnMain("native cookie filter") { vm.projectCookies.filter == "one.test" && vm.projectCookies.visible.count == 1 }
        #expect(vm.projectCookies.total == 2)
        window.layout()
        try ControlPress.press("Clear search", under: window.host)
        try await eventuallyOnMain("all cookie sites") { vm.projectCookies.visible.count == 2 }
        window.layout()
        let clear = try ControlPress.press("Clear cookies for one.test", under: window.host)
        #expect(ControlPress.undersized([clear], minimum: .desktop).isEmpty)
        #expect(await store.httpCookieStore.allCookies().count == 2)
        window.layout()
        let confirmationNodes = AccessibilityNode.all(under: window.host)
        #expect(!confirmationNodes.contains { $0.label == "Back to Shepherd" || $0.label == "Space category Instructions" || $0.label == "Clear cookies for two.test" })
        let labels = confirmationNodes.compactMap(\.label).joined(separator: " ")
        #expect(!["private-name", "private-value", "secret-name", "secret-value"].contains { labels.contains($0) })
        try ControlPress.press("Cancel", under: window.host)
        #expect(await store.httpCookieStore.allCookies().count == 2)
        for width in [900.0, 720.0] {
            window.window.setContentSize(CGSize(width: width, height: 900))
            try await eventuallyOnMain("the narrow Settings viewport") {
                window.layout(); return abs(window.host.bounds.width - width) <= 1
            }
            #expect(!nativeScrollViews(window.host).contains {
                $0.hasHorizontalScroller && ($0.documentView?.bounds.width ?? 0) > $0.contentView.bounds.width + 1
                    && $0.frame.width > 600
            }, "the project page no longer scrolls a fixed-width column")
            window.layout()
            try ControlPress.press("Clear cookies for one.test", under: window.host)
            window.layout()
            let visible = AccessibilityNode.all(under: window.host)
            for label in ["Cancel", "Clear cookies"] {
                let node = try #require(visible.first { $0.label == label })
                let local = window.host.convert(window.window.convertFromScreen(node.frame), from: nil)
                #expect(local.minX >= 0 && local.maxX <= width && local.minY >= 0 && local.maxY <= 900,
                        "\(label) at \(local) must fit the \(width)pt Settings viewport")
            }
            try ControlPress.press("Cancel", under: window.host)
            #expect(await store.httpCookieStore.allCookies().count == 2)
        }
        window.window.setContentSize(CGSize(width: 1440, height: 900))
        window.layout()
        try ControlPress.press("Clear cookies for one.test", under: window.host)
        window.layout()
        try ControlPress.press("Clear cookies", under: window.host)
        try await eventuallyOnMain("one site cleared") { !vm.projectCookies.clearing && vm.projectCookies.total == 1 }
        #expect(await store.httpCookieStore.allCookies().map(\.domain) == ["two.test"])
        #expect(await otherStore.httpCookieStore.allCookies().count == 1)
        #expect(vm.browsers.existing(sibling.id)?.webView?.configuration.websiteDataStore === store)
        window.layout()
        let all = try ControlPress.press("Clear all cookies", under: window.host)
        #expect(ControlPress.undersized([all], minimum: .desktop).isEmpty)
        #expect(await store.httpCookieStore.allCookies().count == 1)
        window.layout()
        try ControlPress.press("Clear cookies", under: window.host)
        try await eventuallyOnMain("all project cookies cleared") { !vm.projectCookies.clearing && vm.projectCookies.total == 0 }
        #expect(await store.httpCookieStore.allCookies().isEmpty)
        #expect(await otherStore.httpCookieStore.allCookies().count == 1)
    }
}
