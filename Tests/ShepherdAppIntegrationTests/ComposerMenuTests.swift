import AppKit
import Foundation
import ShepherdCore
import ShepherdSessions
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// The composer's menus float over the thread: opening one never changes the composer's height,
/// the thread's inset or scroll position, or any of the thread's pixels outside the menu. Each
/// opens the way the app opens it, in a real `ThreadView` over a long thread, in an off-screen
/// window; nothing here clicks or presses a key.
@Suite("Composer menus", .serialized, .mainActorExclusive)
@MainActor
struct ComposerMenuTests {
    enum Menu: String, CaseIterable, CustomTestStringConvertible {
        case slash, models, thinking, speed

        var testDescription: String { rawValue }

        /// Its popover's height at rest over a full catalog and command list, and its board width
        /// (the slash menu spans the card). The model-settings popover is a model section, then a
        /// segmented Thinking control (one row of segments for pi's standard four levels) and,
        /// for a model with a Fast tier, a segmented Speed control.
        /// Picker and slash-menu height; settings menus also need their produced model-row count.
        var height: CGFloat { height(thinkingRows: 1, modelRows: 0) }

        /// `thinkingRows` counts segment tracks; `modelRows` includes the quick choices and All models.
        func height(thinkingRows: Int, modelRows: Int) -> CGFloat {
            let padding = 2 * SH.Space.s
            switch self {
            case .slash: return SHComposerMetrics.menuHeaderHeight + CGFloat(SHComposerMetrics.menuMaxRows) * SHComposerMetrics.slashRowHeight + padding
            case .models: return SHComposerMetrics.modelSearchHeight + 2 * SH.Space.xs + SHComposerMetrics.modelPickerMaxHeight
            case .thinking, .speed:
                // A hairline between sections, a header, a track of 24pt segments in 2pt padding, and 6pt under it.
                func section(rows: Int) -> CGFloat {
                    SH.Space.xs * 2 + 1 + SHComposerMetrics.menuHeaderHeight
                        + CGFloat(rows) * SH.Height.controlS + CGFloat(rows - 1) * SH.Space.xxs + SH.Space.xxs * 2 + SH.Space.s
                }
                let models = SHComposerMetrics.menuHeaderHeight + CGFloat(modelRows) * SHComposerMetrics.menuRowHeight + padding
                return models + section(rows: thinkingRows) + (self == .speed ? section(rows: 1) : 0)
            }
        }

        var width: CGFloat {
            switch self {
            case .slash: .infinity
            case .models: SHComposerMetrics.modelPickerWidth
            case .thinking, .speed: SHComposerMetrics.modelSettingsWidth
            }
        }

        @MainActor func open(in thread: ComposerThread) {
            switch self {
            case .slash: thread.openSlashMenu()
            case .models: thread.openModelPicker()
            case .thinking: thread.commands.send(.thinkingMenu, to: ComposerThread.key)
            case .speed: thread.openSpeedMenu()
            }
        }
    }

    /// The window sizes that matter: a wide window, the smallest window, and the thread beside a
    /// docked right pane (at least 400pt, `ShellLayout`).
    nonisolated static let sizes = [CGSize(width: 900, height: 600), CGSize(width: 720, height: 600), CGSize(width: 440, height: 600)]

    /// How far the popover's shadow reaches past its edges (faintly: this is any change at all).
    nonisolated static let shadow: CGFloat = 48
    /// A change stronger than the shadow's darkest: the popover's own line and what it holds.
    nonisolated static let edge = 0.11

    @Test(arguments: Menu.allCases, sizes)
    func openingAMenuLeavesTheThreadAndTheComposerWhereTheyWere(_ menu: Menu, size: CGSize) async throws {
        let thread = ComposerThread(size: size, speed: menu == .speed)
        defer { thread.close() }
        try await thread.waitUntilReady()
        let inset = thread.composerInset, offset = thread.threadOffset
        let whole = CGRect(origin: .zero, size: size)
        let before = FrameTimer.capture(thread.window, whole)

        menu.open(in: thread)
        try await thread.settle()

        #expect(thread.composerInset == inset, "the composer's height and the thread's inset hold")
        #expect(thread.threadOffset == offset, "the thread stays where it was scrolled")
        let after = FrameTimer.capture(thread.window, whole)
        // The card's focus ring (3pt outside it) lights with an open menu: compare the thread above it.
        let band = Int(thread.cardTop - SHComposerMetrics.focusRing - 1)
        let changed = try #require(Pixels.bounds(differing: before, after, rows: 0..<band), "the menu opened")
        let width = min(menu.width, size.width - 2 * thread.columnLeading)
        let height = menu.height(thinkingRows: 1, modelRows: thread.settingsModelRows)
        let allowed = CGRect(x: thread.columnLeading - Self.shadow, y: thread.cardTop - AppLayout.menuGap - height - Self.shadow,
                             width: width + 2 * Self.shadow, height: height + AppLayout.menuGap + Self.shadow)
        #expect(allowed.contains(changed), "only the menu drew over the thread: \(changed) is outside \(allowed)")
        // Left-aligned with the card, its bottom 8pt above it.
        let solid = try #require(Pixels.bounds(differing: before, after, rows: 0..<band, by: Self.edge))
        #expect(abs(solid.minX - thread.columnLeading) <= 2, "starts at the card's leading edge: \(solid)")
        #expect(abs(solid.maxY - (thread.cardTop - AppLayout.menuGap)) <= 2, "ends 8pt above the card: \(solid)")
    }

    /// Up to four levels share one row of segments, more wrap onto balanced rows of the same track
    /// (5 = 3 + 2, 7 = 4 + 3), so no title is cut and the popover stays 328pt wide.
    @Test(arguments: [
        (["low", "medium", "high", "xhigh"], 1),
        (["off", "minimal", "low", "medium", "high"], 2),
        (["off", "minimal", "low", "medium", "high", "xhigh", "max"], 2),
    ] as [([String], Int)])
    func everySupportedThinkingLevelHasItsOwnSegment(_ levels: [String], rows: Int) async throws {
        let thread = ComposerThread(thinkingLevels: levels)
        defer { thread.close() }
        try await thread.waitUntilReady()
        let whole = CGRect(origin: .zero, size: thread.size)
        let before = FrameTimer.capture(thread.window, whole)
        Menu.thinking.open(in: thread)
        try await thread.settle()
        let after = FrameTimer.capture(thread.window, whole)
        let band = Int(thread.cardTop - SHComposerMetrics.focusRing - 1)
        let solid = try #require(Pixels.bounds(differing: before, after, rows: 0..<band, by: Self.edge))
        #expect(abs(solid.height - Menu.thinking.height(thinkingRows: rows, modelRows: thread.settingsModelRows)) <= 2, "\(rows) row(s) of segments: \(solid)")
        #expect(abs(solid.width - SHComposerMetrics.modelSettingsWidth) <= 2, "all segments stay inside the popover")
    }

    /// Standard adds nothing to the unified button; Fast adds a bolt without changing height.
    @Test func onlyFastSpeedAddsAnIndicatorToModelSettings() async throws {
        let plain = ComposerThread(model: "openai/gpt-6-luna"), standard = ComposerThread(speed: true), fast = ComposerThread(speed: true, fast: true)
        defer { plain.close(); standard.close(); fast.close() }
        try await plain.waitUntilReady()
        try await standard.waitUntilReady()
        try await fast.waitUntilReady()
        #expect(plain.composerInset == standard.composerInset)
        #expect(plain.composerInset == fast.composerInset)
        let card = CGRect(x: 0, y: plain.cardTop, width: plain.size.width, height: plain.size.height - plain.cardTop)
        let withoutTier = FrameTimer.capture(plain.window, card)
        let standardTier = FrameTimer.capture(standard.window, card)
        let fastTier = FrameTimer.capture(fast.window, card)
        #expect(withoutTier == standardTier, "Standard draws no speed indicator")
        let changed = try #require(Pixels.bounds(differing: standardTier, fastTier, rows: 0..<Int(card.height), by: 0.05), "Fast draws a bolt")
        #expect(changed.minX > plain.columnLeading, "inside the control row: \(changed)")
    }

    /// The composer takes the keyboard while its thread is the focused pane (the window is never
    /// key, so this never takes the user's focus), gives it up while its agent is hidden, and
    /// takes it again when the agent is switched back to.
    @Test func theComposerTakesTheKeyboardAgainWhenItsThreadComesBack() async throws {
        let thread = FakeThread(ThreadFixture.snapshot(ThreadFixture.history(2)), focused: true)
        defer { thread.close() }
        try await thread.waitUntilReady()
        let window = thread.window.window
        func typing() -> Bool { (window.firstResponder as? NSTextView)?.isFieldEditor == true }
        try await eventuallyOnMain("the composer to take the keyboard") { typing() }

        thread.visibility.focused = false
        try await thread.show(false)
        #expect(!typing())

        thread.visibility.focused = true
        try await thread.show(true)
        try await eventuallyOnMain("the composer to take the keyboard again") { typing() }
    }

    @Test(arguments: [false, true], [false, true])
    func modelShortcutRoutesToTheVisibleThread(terminal: Bool, rebound: Bool) async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            [terminal = terminal as Bool, rebound = rebound as Bool] in
            await completingScenario { try await Self.shortcut(terminal: terminal, rebound: rebound) }
        }
        expectScenarioCompleted(result)
    }

    @MainActor final class ModelCommandTarget: NSObject {
        let vm: ShepherdViewModel
        init(_ vm: ShepherdViewModel) { self.vm = vm }
        @objc func chooseModel() { vm.sendThreadCommand(.modelPicker) }
    }

    static func shortcut(terminal: Bool, rebound: Bool) async throws {
        try StubPi.installAsEngine()
        let app = try AppHarness()
        let keys = app.keybindings
        if rebound { #expect(keys.assign(KeyChord(key: "m", command: true, option: true), to: .modelPicker) == nil) }
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let info = try await app.server.createSession(params: CreateSessionParams(cwd: space.path, command: StubPi.command, runtime: .rpc))
        let agent = Fixture.agent("visible", in: space, piSession: info.id)
        let hidden = Fixture.agent("hidden", in: space)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent, hidden]))
        vm.selectAgent(agent.agent.id)
        let window = OffscreenWindow(size: CGSize(width: 1000, height: 800), WorkspaceView(vm: vm)
            .environment(\.threadCommands, vm.threadCommands))
        defer { window.close() }
        let store = vm.threadStores.store(for: agent.agent.id)
        try await eventuallyOnMain("the visible composer to load and focus") { store.ready && window.window.firstResponder is NSTextView }
        if terminal {
            vm.newTerminalTab()
            try await eventuallyOnMain("the terminal to take focus") {
                window.layout()
                return window.window.firstResponder.map { String(describing: type(of: $0)).contains("AppTerminalView") } == true
            }
        }
        let chord = keys.chord(for: .modelPicker)
        #expect(chord == (rebound ? KeyChord(key: "m", command: true, option: true) : ShortcutAction.modelPicker.defaultChord))
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: chord.modifierFlags,
            timestamp: 1, windowNumber: window.window.windowNumber, context: nil, characters: "m",
            charactersIgnoringModifiers: "m", isARepeat: false, keyCode: 46))
        if terminal {
            let surface = try #require(window.window.firstResponder as? NSView)
            #expect(!surface.performKeyEquivalent(with: event), "Ghostty leaves the default/rebound app chord alone")
        }
        let menu = NSMenu(title: "Agent"), target = ModelCommandTarget(vm)
        let item = menu.addItem(withTitle: "Choose Model…", action: #selector(ModelCommandTarget.chooseModel), keyEquivalent: chord.key)
        item.keyEquivalentModifierMask = chord.modifierFlags
        item.target = target
        item.isEnabled = MenuState.Snapshot(vm).hasVisibleThread
        #expect(item.isEnabled)
        #expect(menu.performKeyEquivalent(with: event))
        try await eventuallyOnMain("the shortcut to focus Search models") {
            window.layout()
            return (window.window.firstResponder as? NSTextView)?.isFieldEditor == true
                && !(window.window.firstResponder is ComposerTextField.Editor)
        }
        #expect(vm.threadCommands.request?.thread == ThreadCommandCenter.key(local: agent.agent.id))
        #expect(!window.window.isKeyWindow)
    }

    @Test func modelsTakeFocusInTheMountedWorkspace() async throws {
        try StubPi.installAsEngine()
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let info = try await app.server.createSession(params: CreateSessionParams(cwd: space.path, command: StubPi.command, runtime: .rpc))
        let agent = Fixture.agent("agent", in: space, piSession: info.id)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        vm.selectAgent(agent.agent.id)
        let window = OffscreenWindow(size: CGSize(width: 1000, height: 800), WorkspaceView(vm: vm)
            .environment(\.threadCommands, vm.threadCommands))
        defer { window.close() }
        let store = vm.threadStores.store(for: agent.agent.id)
        try await eventuallyOnMain("the workspace thread to load") { store.ready }
        store.draft = "Keep workspace draft"
        try await eventuallyOnMain("the workspace composer to own the field editor") {
            window.layout()
            return (window.window.firstResponder as? NSTextView)?.string == store.draft
        }
        vm.sendThreadCommand(.modelPicker)
        try await eventuallyOnMain("Search models to take focus", timeout: .seconds(3)) {
            window.layout()
            guard let editor = window.window.firstResponder as? NSTextView else { return false }
            return editor.string.isEmpty
        }
        let editor = try #require(window.window.firstResponder as? NSTextView)
        editor.insertText("sonnet", replacementRange: NSRange(location: 0, length: 0))
        #expect(store.draft == "Keep workspace draft")
    }

    @Test func aModelChipThatAlsoFocusesItsPaneKeepsSearchFocused() async throws {
        let thread = FakeThread(ComposerThread.snapshot(messages: 2, commands: []))
        defer { thread.close() }
        try await thread.waitUntilReady()
        thread.store.draft = "Preserved draft"
        // The pane's simultaneous tap gesture focuses the pane as its chip opens the picker.
        thread.commands.send(.modelPicker, to: "fake")
        thread.visibility.focused = true
        try await eventuallyOnMain("the picker to take focus", timeout: .seconds(2)) {
            thread.window.layout()
            return (thread.window.window.firstResponder as? NSTextView)?.string == ""
        }
        let editor = try #require(thread.window.window.firstResponder as? NSTextView)
        editor.insertText("sonnet", replacementRange: NSRange(location: 0, length: 0))
        #expect(thread.store.draft == "Preserved draft")
    }

    @Test(arguments: [false, true])
    func openingModelsMovesTypingFromTheComposerToSearch(focused: Bool) async throws {
        let thread = ComposerThread(focused: focused)
        defer { thread.close() }
        try await thread.waitUntilReady()
        thread.store.draft = "Keep this draft"
        thread.openModelPicker()
        try await thread.settle()
        let editor = try #require(thread.focusedEditor)
        #expect(editor.string.isEmpty, "Search models, not the draft, owns the field editor")
        thread.type("sonnet")
        try await thread.settle()
        #expect(thread.store.draft == "Keep this draft")
        #expect(thread.focusedEditor?.string == "sonnet")
    }

    /// The menu is the topmost thing where it floats: a point in it hits the menu, never the
    /// thread's scroll view beneath.
    @Test func theOpenMenuTakesThePointerOverTheThread() async throws {
        let thread = ComposerThread()
        defer { thread.close() }
        try await thread.waitUntilReady()
        let threadScroll = try #require(thread.threadScroll)
        let inPicker = CGPoint(x: thread.columnLeading + SHComposerMetrics.modelPickerWidth / 2, y: thread.cardTop - AppLayout.menuGap - 60)
        let underneath = try #require(thread.hit(inPicker))
        #expect(underneath.isDescendant(of: threadScroll), "the thread is under the pointer before the menu opens")

        thread.openModelPicker()
        try await thread.settle()

        let hit = try #require(thread.hit(inPicker))
        #expect(!hit.isDescendant(of: threadScroll), "the menu takes the point, not the thread: \(hit)")
    }

    /// A menu never runs past the thread's top: over a tall composer (a question with a long
    /// message) the picker takes the room above the card and scrolls inside.
    @Test func aMenuFitsTheRoomAboveTheComposer() async throws {
        let dialog = NativeThreadDialog(id: "d1", kind: .input, title: "Describe the release",
                                        message: Array(repeating: "A long message that takes the question panel to its full height.", count: 12)
                                            .joined(separator: "\n"))
        // Measure the picker, not deferred transcript draws between captures. Long-thread
        // overlay behavior is covered by openingAMenuLeavesTheThreadAndTheComposerWhereTheyWere.
        let thread = ComposerThread(messages: 0, size: CGSize(width: 720, height: 460), dialogs: [dialog])
        defer { thread.close() }
        try await thread.waitUntilReady()
        let room = thread.cardTop - AppLayout.menuGap - AppLayout.menuMargin
        try #require(room < Menu.models.height, "the composer leaves less room than the picker's full height: \(room)")
        let whole = CGRect(origin: .zero, size: thread.size)
        let before = FrameTimer.capture(thread.window, whole)

        thread.openModelPicker()
        try await thread.settle()

        let after = FrameTimer.capture(thread.window, whole)
        let band = Int(thread.cardTop - SHComposerMetrics.focusRing - 1)
        let solid = try #require(Pixels.bounds(differing: before, after, rows: 0..<band, by: Self.edge))
        #expect(abs(solid.width - Menu.models.width) <= 2, "the changed pixels belong to the picker: \(solid)")
        #expect(solid.minY >= AppLayout.menuMargin - 1, "the picker stays inside the thread: \(solid)")
        #expect(solid.minY <= AppLayout.menuMargin + SHComposerMetrics.modelRowHeight, "and takes the room it has: \(solid)")
        let list = try #require(thread.menuScroll?.documentView)
        #expect(list.bounds.height > thread.menuScroll!.contentView.bounds.height, "the list scrolls inside the picker")
    }

    /// A menu's list opens at its top: growing from its corner never leaves the first row cut.
    @Test(arguments: [Menu.slash, .models])
    func aMenusListOpensAtItsTop(_ menu: Menu) async throws {
        let thread = ComposerThread()
        defer { thread.close() }
        try await thread.waitUntilReady()

        menu.open(in: thread)
        try await thread.settle()

        let list = try #require(thread.menuScroll)
        // `SHMenuListStartsAtTop` holds the list at its top for a fixed time after it appears. On a
        // loaded machine the growth's last frames arrive after that and leave the list 0.6 to 3.9pt
        // down (a Mac's efficiency cores under load); where CI=true that is a known issue.
        withKnownIssue("a busy main thread drifts the list after the menu stops holding it", isIntermittent: true) {
            #expect(abs(list.contentView.bounds.origin.y) < 0.5, "scrolled \(list.contentView.bounds.origin.y)pt down its list")
        } when: { !TimingTests.enabled }
    }

    /// Menus open one at a time: a chip's menu (or ⇧⌘M) takes over from the slash menu a "/"
    /// draft opened, and typing a command takes over from a chip's menu. Each looks exactly as
    /// it does opened alone.
    @Test func menusOpenOneAtATime() async throws {
        let thread = ComposerThread(animated: false)
        defer { thread.close() }
        try await thread.waitUntilReady()
        let above = CGRect(x: 0, y: 0, width: thread.size.width, height: thread.cardTop - SHComposerMetrics.focusRing - 1)
        // ⇧⌘M takes a few updates to reach the composer: wait for the window to change, then for
        // it to come to rest.
        func after(_ change: () -> Void) async throws -> FrameTimer.Capture {
            let before = FrameTimer.capture(thread.window, above)
            change()
            try await eventuallyOnMain("the menus to change") {
                thread.window.layout()
                return FrameTimer.capture(thread.window, above) != before
            }
            try await thread.settle()
            return FrameTimer.capture(thread.window, above)
        }
        // AppKit draws the search field's placeholder a point higher or lower depending on when
        // its field editor takes over, so the picker's comparison leaves that one row out.
        let pickerTop = thread.cardTop - AppLayout.menuGap - Menu.models.height
        let searchField = CGRect(x: thread.columnLeading, y: pickerTop, width: Menu.models.width,
                                 height: SHComposerMetrics.modelSearchHeight)
        let models = try await after { Menu.models.open(in: thread) }
        _ = try await after { Menu.models.open(in: thread) }
        let thinking = try await after { Menu.thinking.open(in: thread) }
        _ = try await after { Menu.thinking.open(in: thread) }
        let commands = try await after { thread.store.draft = "/r" }
        _ = try await after { thread.store.draft = "" }

        _ = try await after { thread.openSlashMenu() }
        let pickerOverCommands = try await after { Menu.models.open(in: thread) }
        let pickerDiffers = Pixels.bounds(differing: pickerOverCommands, models, rows: 0..<models.height)
        #expect(pickerDiffers.map(searchField.contains) ?? true, "the picker takes over from the slash menu: \(pickerDiffers.map { "\($0)" } ?? "")")
        let thinkingOverPicker = try await after { Menu.thinking.open(in: thread) }
        #expect(thinkingOverPicker == thinking, "the thinking menu takes over from the picker")
        let commandsOverThinking = try await after { thread.store.draft = "/r" }
        #expect(commandsOverThinking == commands, "typing a command takes over from the thinking menu")
    }

    /// A thread that mounts with a "/" draft already in its store (a remounted remote thread)
    /// shows its slash menu from the first frame, before the card has been measured.
    @Test func aThreadThatMountsWithASlashDraftShowsItsMenu() async throws {
        let thread = ComposerThread()
        defer { thread.close() }
        try await thread.waitUntilReady()
        let closed = FrameTimer.capture(thread.window, CGRect(x: 0, y: 0, width: thread.size.width, height: thread.cardTop - 4))
        thread.store.draft = "/"

        thread.remount()
        try await thread.settle()

        let band = CGRect(x: 0, y: 0, width: thread.size.width, height: thread.cardTop - 4)
        let open = FrameTimer.capture(thread.window, band)
        let menu = try #require(Pixels.bounds(differing: closed, open, rows: 0..<Int(band.height), by: Self.edge), "the menu shows")
        #expect(abs(menu.maxY - (thread.cardTop - AppLayout.menuGap)) <= 2, "above the card: \(menu)")
    }

    /// A click outside the menu closes it (and still lands where it was aimed); a click in the menu,
    /// or on a chip (it toggles its own menu), leaves it open. The field is the slash menu's own,
    /// and outside a chip's. The
    /// clicks are handed to the composer's watcher directly: nothing is posted to the window.
    @Test(arguments: [Menu.models, .slash, .thinking, .speed])
    func aClickOutsideTheMenuClosesIt(_ menu: Menu) async throws {
        let thread = ComposerThread(speed: menu == .speed)
        defer { thread.close() }
        try await thread.waitUntilReady()
        // The thread above the card: typing "/" changes the field too.
        let whole = CGRect(x: 0, y: 0, width: thread.size.width, height: thread.cardTop - SHComposerMetrics.focusRing - 1)
        let closed = FrameTimer.capture(thread.window, whole)
        menu.open(in: thread)
        try await thread.settle()
        let open = FrameTimer.capture(thread.window, whole)
        #expect(open != closed)
        let dismissal = try #require(thread.menuDismissal)

        dismissal.handle(thread.click(at: CGPoint(x: thread.columnLeading + 40, y: thread.cardTop - AppLayout.menuGap - 20)))
        // The field is the slash menu's own (it is typing there) but outside a chip's menu.
        if menu == .slash { dismissal.handle(thread.click(at: CGPoint(x: thread.columnLeading + 40, y: thread.cardTop + 20))) }
        try await thread.settle()
        #expect(FrameTimer.capture(thread.window, whole) == open, "clicks in the menu, and in the field for the slash menu, leave it open")
        if menu != .slash {
            dismissal.handle(thread.click(at: CGPoint(x: thread.columnLeading + 40, y: thread.cardTop + 20)))
            try await thread.settle()
            #expect(FrameTimer.capture(thread.window, whole) == closed, "a click in the field closes a chip's menu")
            return
        }

        dismissal.handle(thread.click(at: CGPoint(x: thread.size.width - 40, y: 40)))
        try await thread.settle()
        #expect(FrameTimer.capture(thread.window, whole) == closed, "a click in the thread closes it")
        if menu == .slash { #expect(thread.store.draft == "/", "closing the slash menu keeps the draft") }
    }

    /// A composer that goes away (its agent deleted, a remote thread remounted) takes its click
    /// watcher with it: nothing the watcher holds keeps the composer's state alive. (The slash
    /// menu, since a search field that had focus is held by AppKit's text system for a while.)
    @Test func aComposerThatGoesAwayLetsGoOfItsClickWatcher() async throws {
        let thread = ComposerThread()
        defer { thread.close() }
        try await thread.waitUntilReady()
        thread.openSlashMenu()
        try await thread.settle()
        thread.store.draft = ""
        try await thread.settle()
        weak var dismissal = thread.menuDismissal
        try #require(dismissal != nil)

        thread.window.show(EmptyView())

        try await eventuallyOnMain("the watcher to be released") {
            thread.window.layout()
            return dismissal == nil
        }
    }
}

// MARK: Reading the window

extension ComposerThread {
    /// Use the composer's producer and fixture catalog: another test's model pick can add a recent row.
    var settingsModelRows: Int {
        ModelCatalog.settingsModels(catalog: ModelCatalog(ModelCatalogFixture.entries), current: store.model,
                                    recent: RecentModels.load(modelDefaults).map(\.id)).count + 1 // All models…
    }

    /// The deepest view under `point` (from the window's top-left), as AppKit hit-tests it.
    func hit(_ point: CGPoint) -> NSView? {
        window.layout()
        let host = window.host
        let inHost = host.isFlipped ? point : CGPoint(x: point.x, y: host.bounds.height - point.y)
        return host.hitTest(host.convert(inHost, to: host.superview))
    }

    /// The open menu's click watcher.
    var menuDismissal: ComposerMenuDismissal? {
        func find(_ view: NSView) -> ComposerMenuRegion.Region? {
            if let region = view as? ComposerMenuRegion.Region { return region }
            return view.subviews.lazy.compactMap(find).first
        }
        return find(window.host)?.dismissal
    }

    /// A left-button press at `point` (from the window's top-left), built but never posted.
    func click(at point: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: point.x, y: size.height - point.y), modifierFlags: [], timestamp: 0,
                           windowNumber: window.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
}

/// Reading two captures of the same region (`FrameTimer.capture`) side by side.
enum Pixels {
    /// The bounding box, in points from the region's top-left, of the pixels in `rows` that
    /// differ between `a` and `b` (by more than `threshold`, 0…1, in some color channel).
    static func bounds(differing a: FrameTimer.Capture, _ b: FrameTimer.Capture, rows: Range<Int>, by threshold: Double = 0) -> CGRect? {
        precondition(a.width == b.width && a.height == b.height && a.bytesPerRow == b.bytesPerRow)
        let limit = Int(threshold * 255)
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        a.data.withUnsafeBytes { pa in
            b.data.withUnsafeBytes { pb in
                for y in rows.clamped(to: 0..<a.height) {
                    for x in 0..<a.width {
                        let offset = y * a.bytesPerRow + x * 4
                        let differs = (0..<3).contains { abs(Int(pa[offset + $0]) - Int(pb[offset + $0])) > limit }
                        if differs {
                            minX = min(minX, x); maxX = max(maxX, x)
                            minY = min(minY, y); maxY = max(maxY, y)
                        }
                    }
                }
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}
