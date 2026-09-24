import AppKit
import Foundation
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
        case slash, models, thinking

        var testDescription: String { rawValue }

        /// Its popover's height at rest over a full catalog and command list, and its board width.
        var height: CGFloat {
            let padding = 2 * NW.Space.s
            switch self {
            case .slash: return NWComposerMetrics.menuHeaderHeight + CGFloat(NWComposerMetrics.menuMaxRows) * NWComposerMetrics.menuRowHeight + padding
            case .models: return NWComposerMetrics.modelSearchHeight + NW.Space.xs + NWComposerMetrics.modelPickerMaxHeight + padding
            case .thinking: return NWComposerMetrics.menuHeaderHeight + 4 * NWComposerMetrics.menuRowHeight + padding
            }
        }

        var width: CGFloat {
            switch self {
            case .slash: NWComposerMetrics.slashMenuWidth
            case .models: NWComposerMetrics.modelPickerWidth
            case .thinking: NWComposerMetrics.thinkingMenuWidth
            }
        }

        @MainActor func open(in thread: ComposerThread) {
            switch self {
            case .slash: thread.openSlashMenu()
            case .models: thread.openModelPicker()
            case .thinking: thread.commands.send(.thinkingMenu, to: ComposerThread.key)
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
        let thread = ComposerThread(size: size)
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
        let band = Int(thread.cardTop - NWComposerMetrics.focusRing - 1)
        let changed = try #require(Pixels.bounds(differing: before, after, rows: 0..<band), "the menu opened")
        let width = min(menu.width, size.width - 2 * thread.columnLeading)
        let allowed = CGRect(x: thread.columnLeading - Self.shadow, y: thread.cardTop - AppLayout.menuGap - menu.height - Self.shadow,
                             width: width + 2 * Self.shadow, height: menu.height + AppLayout.menuGap + Self.shadow)
        #expect(allowed.contains(changed), "only the menu drew over the thread: \(changed) is outside \(allowed)")
        // Left-aligned with the card, its bottom 8pt above it.
        let solid = try #require(Pixels.bounds(differing: before, after, rows: 0..<band, by: Self.edge))
        #expect(abs(solid.minX - thread.columnLeading) <= 2, "starts at the card's leading edge: \(solid)")
        #expect(abs(solid.maxY - (thread.cardTop - AppLayout.menuGap)) <= 2, "ends 8pt above the card: \(solid)")
    }

    /// The menu is the topmost thing where it floats: a point in it hits the menu, never the
    /// thread's scroll view beneath.
    @Test func theOpenMenuTakesThePointerOverTheThread() async throws {
        let thread = ComposerThread()
        defer { thread.close() }
        try await thread.waitUntilReady()
        let threadScroll = try #require(thread.threadScroll)
        let inPicker = CGPoint(x: thread.columnLeading + NWComposerMetrics.modelPickerWidth / 2, y: thread.cardTop - AppLayout.menuGap - 60)
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
        let thread = ComposerThread(size: CGSize(width: 720, height: 460), dialogs: [dialog])
        defer { thread.close() }
        try await thread.waitUntilReady()
        let room = thread.cardTop - AppLayout.menuGap - AppLayout.menuMargin
        try #require(room < Menu.models.height, "the composer leaves less room than the picker's full height: \(room)")
        let whole = CGRect(origin: .zero, size: thread.size)
        let before = FrameTimer.capture(thread.window, whole)

        thread.openModelPicker()
        try await thread.settle()

        let after = FrameTimer.capture(thread.window, whole)
        let band = Int(thread.cardTop - NWComposerMetrics.focusRing - 1)
        let solid = try #require(Pixels.bounds(differing: before, after, rows: 0..<band, by: Self.edge))
        #expect(solid.minY >= AppLayout.menuMargin - 1, "the picker stays inside the thread: \(solid)")
        #expect(solid.minY <= AppLayout.menuMargin + NWComposerMetrics.menuRowHeight, "and takes the room it has: \(solid)")
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
        #expect(abs(list.contentView.bounds.origin.y) < 0.5, "scrolled \(list.contentView.bounds.origin.y)pt down its list")
    }

    /// Menus open one at a time: a chip's menu (or ⇧⌘M) takes over from the slash menu a "/"
    /// draft opened, and typing a command takes over from a chip's menu. Each looks exactly as
    /// it does opened alone.
    @Test func menusOpenOneAtATime() async throws {
        let thread = ComposerThread(animated: false)
        defer { thread.close() }
        try await thread.waitUntilReady()
        let above = CGRect(x: 0, y: 0, width: thread.size.width, height: thread.cardTop - NWComposerMetrics.focusRing - 1)
        func alone(_ menu: Menu, draft: String = "/") async throws -> FrameTimer.Capture {
            if menu == .slash { thread.store.draft = draft } else { menu.open(in: thread) }
            try await thread.settle()
            let capture = FrameTimer.capture(thread.window, above)
            if menu == .slash { thread.store.draft = "" } else { menu.open(in: thread) }
            try await thread.settle()
            return capture
        }
        let models = try await alone(.models), thinking = try await alone(.thinking), commands = try await alone(.slash, draft: "/r")

        thread.openSlashMenu()
        try await thread.settle()
        thread.openModelPicker()
        try await thread.settle()
        #expect(FrameTimer.capture(thread.window, above) == models, "the picker takes over from the slash menu")

        Menu.thinking.open(in: thread)
        try await thread.settle()
        #expect(FrameTimer.capture(thread.window, above) == thinking, "the thinking menu takes over from the picker")

        thread.store.draft = "/r"
        try await thread.settle()
        #expect(FrameTimer.capture(thread.window, above) == commands, "typing a command takes over from the thinking menu")
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

    /// A click outside the menu and the card closes it (and still lands where it was aimed); a
    /// click in the menu, or in the card (a chip toggles its own menu), leaves it open. The
    /// clicks are handed to the composer's watcher directly: nothing is posted to the window.
    @Test(arguments: [Menu.models, .slash, .thinking])
    func aClickOutsideTheMenuClosesIt(_ menu: Menu) async throws {
        let thread = ComposerThread()
        defer { thread.close() }
        try await thread.waitUntilReady()
        // The thread above the card: typing "/" changes the field too.
        let whole = CGRect(x: 0, y: 0, width: thread.size.width, height: thread.cardTop - NWComposerMetrics.focusRing - 1)
        let closed = FrameTimer.capture(thread.window, whole)
        menu.open(in: thread)
        try await thread.settle()
        let open = FrameTimer.capture(thread.window, whole)
        #expect(open != closed)
        let dismissal = try #require(thread.menuDismissal)

        dismissal.handle(thread.click(at: CGPoint(x: thread.columnLeading + 40, y: thread.cardTop - AppLayout.menuGap - 20)))
        dismissal.handle(thread.click(at: CGPoint(x: thread.columnLeading + 40, y: thread.cardTop + 20)))
        try await thread.settle()
        #expect(FrameTimer.capture(thread.window, whole) == open, "clicks in the menu and the card leave it open")

        dismissal.handle(thread.click(at: CGPoint(x: thread.size.width - 40, y: 40)))
        try await thread.settle()
        #expect(FrameTimer.capture(thread.window, whole) == closed, "a click in the thread closes it")
        if menu == .slash { #expect(thread.store.draft == "/", "closing the slash menu keeps the draft") }
    }
}

// MARK: Reading the window

extension ComposerThread {
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
