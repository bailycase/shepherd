import Foundation
import ShepherdCore
import Testing
@testable import ShepherdRemote

@Suite("Terminal panel")
struct TerminalPanelTests {
    private static func leaf(_ id: PaneID) -> PaneNode { .leaf(LeafPane(id: id, cwd: "~/code")) }
    private static func split(_ first: PaneNode, _ second: PaneNode, _ axis: SplitAxis = .horizontal) -> PaneNode {
        .split(axis: axis, ratio: 0.5, first: first, second: second)
    }

    @Test func aLayoutOfOnlyTheThreadHasNoTabs() {
        let thread = PaneID()
        #expect(TerminalPanel.tabs(in: Self.leaf(thread), thread: thread).isEmpty)
    }

    @Test func panesSplitOffTheThreadAreTabsOldestFirst() {
        let thread = PaneID(), first = PaneID(), second = PaneID(), third = PaneID()
        // + three times: each new pane splits the thread, so it sits closest to it.
        var layout = Self.leaf(thread)
        for pane in [first, second, third] {
            layout = layout.splitting(pane: thread, axis: .horizontal, newPane: LeafPane(id: pane, cwd: "~"))!
        }
        #expect(TerminalPanel.tabs(in: layout, thread: thread).map(\.id) == [first, second, third])
    }

    @Test func aPaneSplitInsideATabStaysInThatTabWithItsSplit() {
        let thread = PaneID(), shell = PaneID(), beside = PaneID()
        let layout = Self.split(Self.leaf(thread), Self.split(Self.leaf(shell), Self.leaf(beside), .vertical), .vertical)
        let tabs = TerminalPanel.tabs(in: layout, thread: thread)
        #expect(tabs.map(\.id) == [shell])
        #expect(tabs.first?.panes.map(\.id) == [shell, beside])
        #expect(tabs.first?.node == Self.split(Self.leaf(shell), Self.leaf(beside), .vertical))
    }

    @Test func panesBeforeTheThreadAreTabsToo() {
        let thread = PaneID(), before = PaneID(), after = PaneID()
        let layout = Self.split(Self.leaf(before), Self.split(Self.leaf(thread), Self.leaf(after)), .vertical)
        #expect(TerminalPanel.tabs(in: layout, thread: thread).map(\.id) == [before, after])
    }

    @Test(arguments: [nil, PaneID()] as [PaneID?])
    func aLayoutWithoutItsThreadIsOneTab(thread: PaneID?) {
        let a = PaneID(), b = PaneID()
        let layout = Self.split(Self.leaf(a), Self.leaf(b))
        let tabs = TerminalPanel.tabs(in: layout, thread: thread)
        #expect(tabs.count == 1)
        #expect(tabs.first?.panes.map(\.id) == [a, b])
    }

    @Test func theChosenTabWinsWhileItExistsThenTheRememberedPanesThenFocusThenTheNewest() {
        let a = TerminalPanelTab(node: Self.leaf(PaneID()))
        let second = PaneID()
        let b = TerminalPanelTab(node: Self.split(Self.leaf(PaneID()), Self.leaf(second)))
        let c = TerminalPanelTab(node: Self.leaf(PaneID()))
        let tabs = [a, b, c]
        #expect(TerminalPanel.selected(tabs, chosen: a.id, focused: c.id) == a)
        #expect(TerminalPanel.selected(tabs, chosen: PaneID(), remembering: [second], focused: c.id) == b)
        #expect(TerminalPanel.selected(tabs, chosen: PaneID(), focused: b.id) == b)
        #expect(TerminalPanel.selected(tabs, chosen: nil, focused: nil) == c)
        #expect(TerminalPanel.selected([], chosen: a.id) == nil)
    }

    @Test func newTabsSplitTheThreadAndSplitsGoBesideTheFocusedPane() {
        let thread = PaneID(), a = PaneID(), b = PaneID()
        let layout = Self.split(Self.leaf(thread), Self.split(Self.leaf(a), Self.leaf(b)))
        #expect(TerminalPanel.newTabAnchor(in: layout, thread: thread) == (thread, .horizontal))
        #expect(TerminalPanel.newTabAnchor(in: layout, thread: nil) == (b, .vertical))
        let tab = TerminalPanel.tabs(in: layout, thread: thread)[0]
        #expect(TerminalPanel.splitAnchor(in: tab, focused: a) == a)
        #expect(TerminalPanel.splitAnchor(in: tab, focused: thread) == b)
        #expect(TerminalPanel.focusedPane(in: tab, focused: b) == b)
        #expect(TerminalPanel.focusedPane(in: tab, focused: nil) == a)
    }

    @Test func closingATabNeverClosesTheThread() {
        let thread = PaneID(), a = PaneID(), b = PaneID()
        let tab = TerminalPanelTab(node: Self.split(Self.leaf(a), Self.split(Self.leaf(thread), Self.leaf(b))))
        #expect(TerminalPanel.panesToClose(tab, thread: thread) == [a, b])
    }
}

@Suite("Terminal panel height")
struct TerminalPanelHeightTests {
    @Test(arguments: [
        // proposed, container, expected
        (330.0, 900.0, 330.0),
        (40.0, 900.0, 120.0),     // at least the minimum
        (880.0, 900.0, 700.0),    // leaves the thread 200
        (295.0, 900.0, 300.0),    // snaps to a third
        (445.0, 900.0, 450.0),    // half
        (606.0, 900.0, 600.0),    // two-thirds
        (270.0, 900.0, 270.0),    // outside the tolerance
        (200.0, 250.0, 50.0),     // a column too short for both keeps the thread
    ] as [(Double, Double, Double)])
    func theHeightIsClampedThenSnapped(proposed: Double, container: Double, expected: Double) {
        let height = TerminalPanelHeight.resolve(proposed, container: container, minimum: 120, threadMinimum: 200, tolerance: 8)
        #expect(abs(height - expected) < 0.001)
    }
}

@Suite("Terminal keys")
struct TerminalKeyTests {
    @Test(arguments: [
        (TerminalKey.escape, false, [0x1B]),
        (.tab, false, [0x09]),
        (.up, false, [0x1B, 0x5B, 0x41]),
        (.down, true, [0x1B, 0x4F, 0x42]),
        (.right, false, [0x1B, 0x5B, 0x43]),
        (.left, true, [0x1B, 0x4F, 0x44]),
        (.pipe, false, [0x7C]),
        (.tilde, false, [0x7E]),
        (.slash, false, [0x2F]),
        (.dash, false, [0x2D]),
        (.control, false, []),
        (.option, false, []),
    ] as [(TerminalKey, Bool, [UInt8])])
    func eachKeySendsItsBytes(key: TerminalKey, applicationCursor: Bool, bytes: [UInt8]) {
        #expect(key.bytes(applicationCursor: applicationCursor) == bytes)
    }

    @Test func modifiedArrowsUseXtermsModifierForm() {
        #expect(TerminalKey.up.bytes(applicationCursor: true, control: true) == Array("\u{1B}[1;5A".utf8))
        #expect(TerminalKey.left.bytes(applicationCursor: false, option: true) == Array("\u{1B}[1;3D".utf8))
        #expect(TerminalKey.right.bytes(applicationCursor: false, control: true, option: true) == Array("\u{1B}[1;7C".utf8))
    }

    @Test func ctrlMakesControlCodesAndOptionSendsEscapeFirst() {
        #expect(TerminalKey.pipe.bytes(applicationCursor: false, control: true) == [0x1C])
        #expect(TerminalKey.slash.bytes(applicationCursor: false, control: true) == [0x1F])
        #expect(TerminalKey.dash.bytes(applicationCursor: false, option: true) == [0x1B, 0x2D])
        #expect(TerminalKey.tab.bytes(applicationCursor: false, option: true) == [0x1B, 0x09])
    }

    @Test(arguments: [
        (UInt8(ascii: "c"), UInt8?(0x03)),
        (UInt8(ascii: "C"), 0x03),
        (UInt8(ascii: "["), 0x1B),
        (UInt8(ascii: "?"), 0x7F),
        (UInt8(ascii: " "), 0x00),
        (UInt8(ascii: "1"), nil),
    ] as [(UInt8, UInt8?)])
    func controlCodesFollowXterm(character: UInt8, code: UInt8?) {
        #expect(TerminalKey.controlCode(character) == code)
    }

    @Test func everyKeyHasALabelAndASpokenLabel() {
        for key in TerminalKey.allCases {
            #expect(!key.label.isEmpty)
            #expect(!key.spokenLabel.isEmpty)
        }
        #expect(TerminalKey.allCases.filter(\.isModifier) == [.control, .option])
    }
}

@Suite("Remote terminal link")
struct RemoteTerminalLinkTests {
    @Test func itAttachesOnceItIsWantedAndHasAGrid() {
        var link = RemoteTerminalLink()
        #expect(link.want(true).isEmpty)
        #expect(link.phase == .detached)
        #expect(link.noteGrid(cols: 100, rows: 30) == [.attach(cols: 100, rows: 30)])
        #expect(link.phase == .attaching)
        #expect(link.acceptsOutput)
        link.attached()
        #expect(link.phase == .live)
    }

    @Test func aGridBeforeItIsWantedWaitsForIt() {
        var link = RemoteTerminalLink()
        #expect(link.noteGrid(cols: 80, rows: 24).isEmpty)
        #expect(!link.acceptsOutput)
        #expect(link.want(true) == [.attach(cols: 80, rows: 24)])
    }

    @Test func aNewGridResizesOnlyWhenItChanged() {
        var link = RemoteTerminalLink()
        _ = link.want(true)
        _ = link.noteGrid(cols: 80, rows: 24)
        link.attached()
        #expect(link.noteGrid(cols: 80, rows: 24).isEmpty)
        #expect(link.noteGrid(cols: 120, rows: 24) == [.resize(cols: 120, rows: 24)])
        #expect(link.noteGrid(cols: 0, rows: 24).isEmpty)
    }

    @Test func leavingTheScreenDetachesAndComingBackAttachesAgain() {
        var link = RemoteTerminalLink()
        _ = link.want(true)
        _ = link.noteGrid(cols: 80, rows: 24)
        link.attached()
        #expect(link.want(false) == [.detach])
        #expect(!link.acceptsOutput)
        #expect(link.want(false).isEmpty)
        #expect(link.want(true) == [.attach(cols: 80, rows: 24)])
    }

    @Test func aDroppedConnectionReattachesOnTheNextOne() {
        var link = RemoteTerminalLink()
        _ = link.want(true)
        _ = link.noteGrid(cols: 80, rows: 24)
        link.attached()
        link.disconnected()
        #expect(link.phase == .detached)
        #expect(link.want(true) == [.attach(cols: 80, rows: 24)])
    }

    @Test func aFailedAttachIsRetriedWhenTheViewComesBack() {
        var link = RemoteTerminalLink()
        _ = link.want(true)
        _ = link.noteGrid(cols: 80, rows: 24)
        link.attachFailed("no_such_session")
        #expect(link.phase == .failed("no_such_session"))
        #expect(link.noteGrid(cols: 90, rows: 24).isEmpty)
        #expect(link.want(false).isEmpty)
        #expect(link.want(true) == [.attach(cols: 90, rows: 24)])
    }

    @Test func anExitedSessionNeverAttachesAgain() {
        var link = RemoteTerminalLink()
        _ = link.want(true)
        _ = link.noteGrid(cols: 80, rows: 24)
        link.attached()
        link.exited(1)
        #expect(link.phase == .exited(1))
        #expect(link.want(false).isEmpty)
        #expect(link.want(true).isEmpty)
        #expect(link.noteGrid(cols: 100, rows: 30).isEmpty)
        link.disconnected()
        #expect(link.phase == .exited(1))
    }
}
