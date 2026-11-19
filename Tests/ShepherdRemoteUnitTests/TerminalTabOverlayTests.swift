import Foundation
import ShepherdCore
import Testing
@testable import ShepherdRemote

/// What a terminal panel draws while + and Close wait for their host (Mac and iOS share it): the
/// placeholder tab, the hidden closing tab, and the races between the host's push and its reply.
@Suite("Terminal tab overlay")
struct TerminalTabOverlayTests {
    private static func tab(_ id: PaneID, session: SessionID? = SessionID()) -> TerminalPanelTab {
        TerminalPanelTab(leaf: LeafPane(id: id, sessionID: session, cwd: "~/code"))
    }

    @Test func aNewTabOpensAtOnceAsAStartingTabAfterTheHostsTerminals() {
        let shell = PaneID()
        var overlay = TerminalTabOverlay()
        let placeholder = overlay.beginOpen(layout: [shell], cwd: "~/code", previousChosen: shell, previousFocus: shell)

        let tabs = overlay.tabs([Self.tab(shell)])
        #expect(tabs.map(\.id) == [shell, placeholder])
        #expect(tabs.last?.leaf.sessionID == nil, "no session: nothing can be typed into it")
        #expect(tabs.last?.leaf.title == TerminalTabOverlay.startingTitle)
        #expect(overlay.isPending(placeholder))
        #expect(TerminalPanel.selected(tabs, chosen: placeholder)?.id == placeholder)
    }

    @Test func theRealPaneTakesThePlaceholdersPlaceOnceTheLayoutHasIt() {
        let shell = PaneID(), real = PaneID()
        var overlay = TerminalTabOverlay()
        let placeholder = overlay.beginOpen(layout: [shell], cwd: "~", previousChosen: nil, previousFocus: nil)

        let r1 = overlay.opened(placeholder, real: real)
        #expect(r1 == .adopted)
        #expect(overlay.tabs([Self.tab(shell)]).map(\.id) == [shell, placeholder], "Starting until the layout has the pane")
        let s101 = overlay.settle(layout: [shell])
        #expect(s101.isEmpty)

        // The pane arrives: it is a tab of its own, never shown twice, and the selection follows.
        let layout = [Self.tab(shell), Self.tab(real)]
        #expect(overlay.tabs(layout).map(\.id) == [shell, real])
        #expect(overlay.resolved(placeholder, in: [shell, real]) == real)
        let r2 = overlay.settle(layout: [shell, real])
        #expect(r2 == [.init(pending: placeholder, real: real)])
        #expect(overlay.isEmpty)
        #expect(overlay.tabs(layout).map(\.id) == [shell, real])
    }

    /// The host's push can carry the pane before its reply does. The pane is the new tab already,
    /// so it never shows beside the placeholder.
    @Test func aPaneThatArrivesBeforeTheReplyIsNotShownTwice() {
        let shell = PaneID(), real = PaneID()
        var overlay = TerminalTabOverlay()
        let placeholder = overlay.beginOpen(layout: [shell], cwd: "~", previousChosen: nil, previousFocus: nil)
        let layout = [Self.tab(shell), Self.tab(real)]

        #expect(overlay.tabs(layout).map(\.id) == [shell, placeholder])
        #expect(overlay.claimed(in: [shell, real]) == [real], "its arrival is not another device's terminal")
        let s102 = overlay.settle(layout: [shell, real])
        #expect(s102.isEmpty, "the reply has not said whose it is")

        let r3 = overlay.opened(placeholder, real: real)
        #expect(r3 == .adopted)
        #expect(overlay.tabs(layout).map(\.id) == [shell, real])
        let r4 = overlay.settle(layout: [shell, real])
        #expect(r4 == [.init(pending: placeholder, real: real)])
    }

    @Test func aTerminalAnotherDeviceOpenedIsATabOnceTheReplyNamesOurs() {
        let shell = PaneID(), theirs = PaneID(), real = PaneID()
        var overlay = TerminalTabOverlay()
        let placeholder = overlay.beginOpen(layout: [shell], cwd: "~", previousChosen: nil, previousFocus: nil)
        // Before the reply the first new pane is assumed ours.
        #expect(overlay.tabs([Self.tab(shell), Self.tab(theirs)]).map(\.id) == [shell, placeholder])

        _ = overlay.opened(placeholder, real: real)
        let layout = [Self.tab(shell), Self.tab(theirs), Self.tab(real)]
        #expect(overlay.tabs(layout).map(\.id) == [shell, theirs, real])
        let r5 = overlay.settle(layout: layout.map(\.id))
        #expect(r5 == [.init(pending: placeholder, real: real)])
    }

    @Test func twoTabsAskedForAtOnceEachBecomeTheirOwnPane() {
        let shell = PaneID(), first = PaneID(), second = PaneID()
        var overlay = TerminalTabOverlay()
        let a = overlay.beginOpen(layout: [shell], cwd: "~", previousChosen: nil, previousFocus: nil)
        let b = overlay.beginOpen(layout: [shell], cwd: "~", previousChosen: a, previousFocus: nil)
        #expect(overlay.tabs([Self.tab(shell)]).map(\.id) == [shell, a, b])

        // The second reply comes first.
        _ = overlay.opened(b, real: second)
        _ = overlay.opened(a, real: first)
        let layout = [Self.tab(shell), Self.tab(first), Self.tab(second)]
        #expect(overlay.tabs(layout).map(\.id) == [shell, first, second])
        let promotions = overlay.settle(layout: layout.map(\.id))
        #expect(Set(promotions) == [.init(pending: a, real: first), .init(pending: b, real: second)])
    }

    @Test func aRefusedOpenGivesTheTabBackAndWhatItTook() throws {
        let shell = PaneID(), focus = PaneID()
        var overlay = TerminalTabOverlay()
        let placeholder = overlay.beginOpen(layout: [shell], cwd: "~", previousChosen: shell, previousFocus: focus)

        let failed = overlay.openFailed(placeholder)
        let refused = try #require(failed)
        #expect(refused.previousChosen == shell && refused.previousFocus == focus)
        #expect(overlay.isEmpty)
        #expect(overlay.tabs([Self.tab(shell)]).map(\.id) == [shell])
        let r6 = overlay.openFailed(placeholder)
        #expect(r6 == nil, "a second refusal finds nothing")
        // A pane that arrived while it waited is an ordinary tab again.
        var again = TerminalTabOverlay()
        let next = again.beginOpen(layout: [shell], cwd: "~", previousChosen: nil, previousFocus: nil)
        let other = PaneID()
        #expect(again.tabs([Self.tab(shell), Self.tab(other)]).map(\.id) == [shell, next])
        again.openFailed(next)
        #expect(again.tabs([Self.tab(shell), Self.tab(other)]).map(\.id) == [shell, other])
    }

    @Test func closingAStartingTabBeforeTheReplyClosesWhatTheHostMakes() {
        let shell = PaneID(), real = PaneID()
        var overlay = TerminalTabOverlay()
        let placeholder = overlay.beginOpen(layout: [shell], cwd: "~", previousChosen: nil, previousFocus: nil)

        let r7 = overlay.abandon(placeholder)
        #expect(r7 == .waiting)
        #expect(!overlay.isPending(placeholder))
        #expect(overlay.tabs([Self.tab(shell)]).map(\.id) == [shell], "the tab is gone at once")
        // Its pane may be pushed before the reply: still not a tab.
        #expect(overlay.tabs([Self.tab(shell), Self.tab(real)]).map(\.id) == [shell])
        let r8 = overlay.opened(placeholder, real: real)
        #expect(r8 == .close(real))
        #expect(overlay.tabs([Self.tab(shell), Self.tab(real)]).map(\.id) == [shell], "hidden while the host closes it")

        overlay.closeConfirmed(real)
        let s103 = overlay.settle(layout: [shell, real])
        #expect(s103.isEmpty)
        let s104 = overlay.settle(layout: [shell])
        #expect(s104.isEmpty)
        #expect(overlay.isEmpty)
    }

    @Test func closingAStartingTabAfterTheReplyClosesItsPaneNow() {
        let shell = PaneID(), real = PaneID()
        var overlay = TerminalTabOverlay()
        let placeholder = overlay.beginOpen(layout: [shell], cwd: "~", previousChosen: nil, previousFocus: nil)
        _ = overlay.opened(placeholder, real: real)

        let r9 = overlay.abandon(placeholder)
        #expect(r9 == .close(real))
        #expect(overlay.tabs([Self.tab(shell)]).map(\.id) == [shell])
        #expect(overlay.tabs([Self.tab(shell), Self.tab(real)]).map(\.id) == [shell])
        let r10 = overlay.abandon(placeholder)
        #expect(r10 == .unknown)
    }

    @Test func anAbandonedOpenThatTheHostRefusesLeavesNothing() {
        let shell = PaneID()
        var overlay = TerminalTabOverlay()
        let placeholder = overlay.beginOpen(layout: [shell], cwd: "~", previousChosen: nil, previousFocus: nil)
        _ = overlay.abandon(placeholder)
        let r11 = overlay.openFailed(placeholder)
        #expect(r11 != nil)
        #expect(overlay.isEmpty)
    }

    @Test func aClosingTabIsGoneAtOnceAndForgottenWhenTheLayoutDropsIt() {
        let a = PaneID(), b = PaneID()
        var overlay = TerminalTabOverlay()
        let r12 = overlay.beginClose(a)
        #expect(r12)
        let r13 = overlay.beginClose(a)
        #expect(!r13, "a second Close is not a second request")

        #expect(overlay.tabs([Self.tab(a), Self.tab(b)]).map(\.id) == [b])
        overlay.closeConfirmed(a)
        // The reply is not the layout: it stays hidden until the push drops it, so it never flickers back.
        let s105 = overlay.settle(layout: [a, b])
        #expect(s105.isEmpty)
        #expect(overlay.tabs([Self.tab(a), Self.tab(b)]).map(\.id) == [b])
        let s106 = overlay.settle(layout: [b])
        #expect(s106.isEmpty)
        #expect(overlay.isEmpty)
    }

    @Test func aRefusedCloseBringsTheTabBack() {
        let a = PaneID(), b = PaneID()
        var overlay = TerminalTabOverlay()
        _ = overlay.beginClose(a)
        overlay.closeFailed(a)

        #expect(overlay.isEmpty)
        #expect(overlay.tabs([Self.tab(a), Self.tab(b)]).map(\.id) == [a, b])
    }

    @Test func aCloseThatTheLayoutAnsweredBeforeTheReplyIsDoneAtTheReply() {
        let a = PaneID(), b = PaneID()
        var overlay = TerminalTabOverlay()
        _ = overlay.beginClose(a)
        let s107 = overlay.settle(layout: [a, b])
        #expect(s107.isEmpty)
        let s108 = overlay.settle(layout: [b])
        #expect(s108.isEmpty, "the push dropped it before the reply")
        #expect(overlay.isEmpty)
    }

    @Test func aTabClosedNeverSeenInTheLayoutIsKeptUntilTheHostConfirms() {
        let a = PaneID(), shell = PaneID()
        var overlay = TerminalTabOverlay()
        // The pane of an abandoned open is closing before the layout has shown it.
        let placeholder = overlay.beginOpen(layout: [shell], cwd: "~", previousChosen: nil, previousFocus: nil)
        _ = overlay.abandon(placeholder)
        _ = overlay.opened(placeholder, real: a)
        let s109 = overlay.settle(layout: [shell])
        #expect(s109.isEmpty)
        #expect(overlay.isClosing(a), "a late push must not show it")
        #expect(overlay.tabs([Self.tab(shell), Self.tab(a)]).map(\.id) == [shell])
    }

    @Test func aPlaceholderIsNeverAChosenPaneOfTheLayoutUntilItsPaneArrives() {
        let shell = PaneID(), real = PaneID()
        var overlay = TerminalTabOverlay()
        let placeholder = overlay.beginOpen(layout: [shell], cwd: "~", previousChosen: nil, previousFocus: nil)
        #expect(overlay.resolved(placeholder, in: [shell]) == placeholder)
        _ = overlay.opened(placeholder, real: real)
        #expect(overlay.resolved(placeholder, in: [shell]) == placeholder, "the reply alone is not the layout")
        #expect(overlay.resolved(placeholder, in: [shell, real]) == real)
        #expect(overlay.resolved(shell, in: [shell, real]) == shell)
        #expect(overlay.resolved(nil, in: [shell]) == nil)
    }

    @Test func anOverlayThatHoldsNothingChangesNothing() {
        let tabs = [Self.tab(PaneID()), Self.tab(PaneID())]
        #expect(TerminalTabOverlay().tabs(tabs) == tabs)
        #expect(TerminalPanel.tabs(in: .leaf(LeafPane(id: PaneID(), cwd: "~")), thread: nil, overlay: TerminalTabOverlay()).count == 1)
    }
}
