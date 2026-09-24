import Foundation
import ShepherdProtocol
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// "Up next": how the stack lays out the host's queue, where a dragged message lands, which
/// keys a focused message answers, and how a draft goes while pi works.
@Suite("Queue stack")
@MainActor
struct QueueStackTests {
    static func message(_ text: String, _ state: NativeQueuedMessage.State = .queued, id: Int) -> NativeQueuedMessage {
        NativeQueuedMessage(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", id))!, text: text, sentAt: 0, state: state)
    }

    static let a = message("A", id: 1), b = message("B", id: 2), c = message("C", id: 3), d = message("D", id: 4)
    static let steering = message("S", .steering, id: 9)

    static func undo(_ message: NativeQueuedMessage, at index: Int) -> QueueStackLayout.Undo {
        QueueStackLayout.Undo(id: message.id.uuidString, messages: [message], index: index, cleared: false)
    }

    // MARK: Rows

    /// The number is the order, not a count: steering messages come first and are not numbered.
    @Test func queuedMessagesAreNumberedInTheOrderTheyGoAfterSteeringOnes() {
        let rows = QueueStackLayout.rows(queue: [Self.steering, Self.a, Self.b], undo: [])
        #expect(rows.map(\.kind) == [.steering, .queued(number: 1), .queued(number: 2)])
        #expect(rows.map(\.id) == [Self.steering, Self.a, Self.b].map(\.id.uuidString))
    }

    /// Up to three rows show them all; past that the first two and "Show N more" (steering
    /// rows count), and expanded every row with "Show fewer".
    @Test(arguments: [
        (3, false, [QueueRowModel.Kind.steering, .queued(number: 1), .queued(number: 2)]),
        (4, false, [.steering, .queued(number: 1), .more(hidden: 2, expanded: false)]),
        (4, true, [.steering, .queued(number: 1), .queued(number: 2), .queued(number: 3), .more(hidden: 0, expanded: true)]),
    ])
    func aLongStackShowsItsFirstTwoRows(messages: Int, expanded: Bool, kinds: [QueueRowModel.Kind]) {
        let queue = Array([Self.steering, Self.a, Self.b, Self.c].prefix(messages))
        #expect(QueueStackLayout.rows(queue: queue, undo: [], expanded: expanded).map(\.kind) == kinds)
    }

    /// An editor opened on a message the long stack hides (↑ on the last one) shows every row.
    @Test func anEditorBelowTheFoldExpandsTheStack() {
        let rows = QueueStackLayout.rows(queue: [Self.a, Self.b, Self.c, Self.d], undo: [], editing: Self.d.id)
        #expect(rows.map(\.kind) == [.queued(number: 1), .queued(number: 2), .queued(number: 3), .editing(number: 4),
                                     .more(hidden: 0, expanded: true)])
    }

    /// A deleted message's Undo row stands where it was, its id the message's (so the two
    /// cross-fade in place), and numbering skips it at once.
    @Test func aDeletedMessagesUndoRowKeepsItsPlace() {
        let rows = QueueStackLayout.rows(queue: [Self.a, Self.c], undo: [Self.undo(Self.b, at: 1)])
        #expect(rows.map(\.kind) == [.queued(number: 1), .deleted("B"), .queued(number: 2)])
        #expect(rows[1].id == Self.b.id.uuidString)
    }

    /// Clearing leaves one row for all of it, at the head of the queued messages.
    @Test func aClearedQueueLeavesOneUndoRowAtItsHead() {
        let cleared = QueueStackLayout.Undo(id: "cleared:1", messages: [Self.a, Self.b], index: 0, cleared: true)
        let rows = QueueStackLayout.rows(queue: [Self.steering], undo: [cleared])
        #expect(rows.map(\.kind) == [.steering, .cleared(2)])
    }

    /// Undo rows past the last queued message follow it, in the order they were made.
    @Test func undoRowsPastTheEndFollowInOrder() {
        let rows = QueueStackLayout.rows(queue: [Self.a], undo: [Self.undo(Self.c, at: 2), Self.undo(Self.b, at: 1)])
        #expect(rows.map(\.kind) == [.queued(number: 1), .deleted("B"), .deleted("C")])
    }

    /// A message back in the queue (another Mac's Undo, a refused delete) takes its Undo row's place.
    @Test func aMessageBackInTheQueueHidesItsUndoRow() {
        let rows = QueueStackLayout.rows(queue: [Self.a, Self.b], undo: [Self.undo(Self.b, at: 1)])
        #expect(rows.map(\.kind) == [.queued(number: 1), .queued(number: 2)])
    }

    // MARK: Drops

    /// Past the middle of a neighbour a dragged message takes its side; short of it, it stays.
    @Test(arguments: [
        // [A, B, C]: C up past B lands second; a nudge stays; A down past the end lands last.
        ("C", -46.0, QueueStackLayout.Drop(boundary: 1, index: 1)),
        ("C", -10.0, nil),
        ("B", 30.0, nil),
        ("B", 46.0, QueueStackLayout.Drop(boundary: 3, index: 2)),
        ("A", 400.0, QueueStackLayout.Drop(boundary: 3, index: 2)),
        ("C", -400.0, QueueStackLayout.Drop(boundary: 0, index: 0)),
    ] as [(String, Double, QueueStackLayout.Drop?)])
    func aDraggedMessageLandsPastTheMiddleOfItsNeighbour(text: String, translation: Double, drop: QueueStackLayout.Drop?) {
        let queue = [Self.a, Self.b, Self.c]
        let rows = QueueStackLayout.rows(queue: queue, undo: [])
        let id = queue.first { $0.text == text }!.id.uuidString
        #expect(QueueStackLayout.drop(rows: rows, moving: id, translation: translation) == drop)
    }

    /// Nothing drops above a steering message, and a steering message does not move.
    @Test func steeringMessagesStayAtTheTop() {
        let rows = QueueStackLayout.rows(queue: [Self.steering, Self.a, Self.b], undo: [])
        #expect(QueueStackLayout.drop(rows: rows, moving: Self.b.id.uuidString, translation: -400) == .init(boundary: 1, index: 0))
        #expect(QueueStackLayout.drop(rows: rows, moving: Self.steering.id.uuidString, translation: 200) == nil)
    }

    /// A lifted message follows the pointer, but floats no further than half a row past the
    /// stack's first and last rows; where it lands still follows the pointer.
    @Test(arguments: [(-400, -100), (400, 20), (-30, -30)] as [(CGFloat, CGFloat)])
    func aLiftedMessageStaysWithinHalfARowOfTheStack(translation: CGFloat, lift: CGFloat) {
        let state = QueueStackState()
        state.update([Self.a, Self.b, Self.c])
        state.drag(Self.c.id.uuidString, by: translation)
        #expect(state.translation == lift)
        if translation < -100 { #expect(state.drop == .init(boundary: 0, index: 0)) }
    }

    /// Undo rows are slots a drag passes, not places in the order.
    @Test func undoRowsAreNotCountedInTheOrder() {
        let rows = QueueStackLayout.rows(queue: [Self.a, Self.c], undo: [Self.undo(Self.b, at: 1)])
        // [A, Deleted B, C]: C up past the Undo row lands after A, second in the order.
        #expect(QueueStackLayout.drop(rows: rows, moving: Self.c.id.uuidString, translation: -46) == .init(boundary: 1, index: 1))
    }

    // MARK: Keys

    static let alternate = KeyChord(key: "return", command: true)

    /// The keys a focused message answers (Queue & steer boards, "Keyboard").
    @Test(arguments: [
        (KeyEquivalent.upArrow, EventModifiers(), QueueRowKey.previous),
        (.downArrow, [], .next),
        (.upArrow, .option, .moveUp),
        (.downArrow, .option, .moveDown),
        (.delete, [], .delete),
        (.deleteForward, [], .delete),
        (.return, [], .edit),
        (.return, .command, .steer),
        (.escape, [], .leave),
        (.tab, [], .leave),
    ] as [(KeyEquivalent, EventModifiers, QueueRowKey)])
    func aFocusedMessageAnswersItsKeys(key: KeyEquivalent, modifiers: EventModifiers, expected: QueueRowKey) {
        #expect(QueueRowKey(key: key, modifiers: modifiers, alternateSend: Self.alternate) == expected)
    }

    @Test func otherKeysPassThrough() {
        #expect(QueueRowKey(key: "a", modifiers: [], alternateSend: Self.alternate) == nil)
        #expect(QueueRowKey(key: .upArrow, modifiers: .command, alternateSend: Self.alternate) == nil)
        #expect(QueueRowKey(key: .return, modifiers: .shift, alternateSend: Self.alternate) == nil)
    }

    /// A rebound alternate send steers a focused message instead of ⌘↩.
    @Test func aReboundAlternateSendSteers() {
        let rebound = KeyChord(key: "j", command: true, option: true)
        #expect(QueueRowKey(key: "j", modifiers: [.command, .option], alternateSend: rebound) == .steer)
        #expect(QueueRowKey(key: .return, modifiers: .command, alternateSend: rebound) == nil)
    }

    // MARK: Sending

    /// ↩ goes the way Settings says while pi works; ⌘↩ always does the other one.
    @Test(arguments: [
        (ComposerSendKey.primary, ReturnWhileWorking.queue, NativeThreadDelivery.followUp),
        (.alternate, .queue, .steer),
        (.primary, .steer, .steer),
        (.alternate, .steer, .followUp),
    ])
    func returnFollowsTheSettingAndTheAlternateSendDoesTheOther(key: ComposerSendKey, setting: ReturnWhileWorking,
                                                                 delivery: NativeThreadDelivery) {
        #expect(key.delivery(setting) == delivery)
    }

    /// The Send menu lists Queue then Steer now, with ↩ on the Return setting's row.
    /// The Send menu stands beside the card only where the thread has room for it and its
    /// margin; else it opens above the card.
    @Test(arguments: [(0, false), (283, false), (284, true), (400, true)] as [(CGFloat, Bool)])
    func theSendMenuGoesBesideTheCardOnlyWhenItFits(room: CGFloat, beside: Bool) {
        #expect(Composer.sendMenuBeside(room: room) == beside)
    }

    @Test(arguments: [(ReturnWhileWorking.queue, ["↩", "⌘↩"]), (.steer, ["⌘↩", "↩"])])
    func theSendMenusKeysFollowTheReturnSetting(setting: ReturnWhileWorking, shortcuts: [String]) {
        let options = Composer.sendOptions(setting, send: "↩", alternate: "⌘↩")
        #expect(options.map(\.id) == ["queue", "steer"])
        #expect(options.map(\.shortcut) == shortcuts)
        #expect(Composer.sendTitles(setting).primary == (setting == .queue ? "Queue" : "Steer now"))
    }

    /// Esc closes a menu, then the command list, and only then stops pi.
    @Test(arguments: [
        (true, true, true, ComposerEscape.closeMenu),
        (false, true, true, .dismissCommands),
        (false, false, true, .stop),
        (false, false, false, .pass),
    ])
    func escapeClosesWhatIsOpenBeforeItStopsPi(menu: Bool, commands: Bool, canStop: Bool, expected: ComposerEscape) {
        #expect(ComposerEscape(menuOpen: menu, commandsOpen: commands, canStop: canStop) == expected)
    }
}
