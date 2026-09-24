import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdRemote

/// The queue's rules, shared by the host and the store's instant edits.
@Suite("Queue rules")
struct QueueRulesTests {
    static func item(_ text: String, _ n: Int, state: NativeQueuedMessage.State = .queued, images: Int = 0) -> NativeQueuedMessage {
        NativeQueuedMessage(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!, text: text,
                            images: Array(repeating: NativeQueuedImage(mimeType: "image/png"), count: images), sentAt: Double(n), state: state)
    }

    static let a = item("a", 1), b = item("b", 2), c = item("c", 3)
    static let steering = item("s", 9, state: .steering)

    // MARK: What one delivery takes

    @Test(arguments: [
        // One per turn takes the head.
        (["a", "b", "c"], NativeQueueMode.oneAtATime, 1),
        // All at once takes everything that can go together.
        (["a", "b", "c"], .all, 3),
        // A command or template goes alone: pi reads "/" only at the start of a message.
        (["/fix x", "b"], .all, 1),
        // …and ends the run of items before it.
        (["a", "b", "/fix x", "c"], .all, 2),
        ([], .all, 0),
    ])
    func aDeliveryTakesTheHeadOrEverythingThatCanGoTogether(texts: [String], mode: NativeQueueMode, count: Int) {
        let items = texts.enumerated().map { Self.item($1, $0) }
        #expect(NativeQueueRules.batchCount(items, mode: mode) == count)
    }

    /// The host's copy of an older client's message goes alone: that client finds its message
    /// in the thread by the text it sent.
    @Test(arguments: [
        ([false, true, false], 1),
        ([true, false, false], 1),
        ([false, false, false], 3),
    ])
    func anItemThatGoesAloneEndsTheRunBeforeIt(alone: [Bool], count: Int) {
        struct Entry: NativeQueueEntry {
            var entry: NativeQueuedMessage
            var goesAlone: Bool
        }
        let items = alone.enumerated().map { Entry(entry: Self.item("m\($0)", $0), goesAlone: $1) }
        #expect(NativeQueueRules.batchCount(items, mode: .all) == count)
    }

    @Test func aDeliveryCarriesAtMostFourImages() {
        let items = [Self.item("a", 1, images: 2), Self.item("b", 2, images: 2), Self.item("c", 3, images: 1)]
        #expect(NativeQueueRules.batchCount(items, mode: .all) == 2)
        #expect(NativeQueueRules.batchCount([Self.item("a", 1, images: 5)], mode: .all) == 1, "the head always goes")
    }

    @Test func aDeliveryStopsBeforeTheJoinedTextLimit() {
        let big = String(repeating: "x", count: NativeQueueRules.joinedTextLimit / 2)
        let items = [Self.item(big, 1), Self.item(big, 2), Self.item("c", 3)]
        #expect(NativeQueueRules.batchCount(items, mode: .all) == 1)
    }

    @Test func partsJoinWithABlankLineAndKeepTheirOwnTimes() {
        let items = [Self.a, Self.item("b", 2, images: 1)]
        #expect(NativeQueueRules.joined(items) == "a\n\nb")
        #expect(NativeQueueRules.parts(items) == [NativeQueuePart(id: Self.a.id, text: "a", sentAt: 1),
                                                   NativeQueuePart(id: items[1].id, text: "b", sentAt: 2, images: 1)])
    }

    // MARK: Changes

    @Test func indexesCountQueuedItemsOnlySteeringStaysOnTop() {
        var items = [Self.steering, Self.a, Self.b, Self.c]
        #expect(NativeQueueRules.queuedIndex(of: Self.a.id, in: items) == 0)
        #expect(NativeQueueRules.queuedIndex(of: Self.steering.id, in: items) == nil)
        #expect(NativeQueueRules.move(Self.c.id, toQueuedIndex: 0, in: &items))
        #expect(items.map(\.text) == ["s", "c", "a", "b"])
        #expect(NativeQueueRules.move(Self.c.id, toQueuedIndex: 99, in: &items))
        #expect(items.map(\.text) == ["s", "a", "b", "c"])
        #expect(!NativeQueueRules.move(Self.steering.id, toQueuedIndex: 1, in: &items), "a steering item is pi's")
    }

    @Test func aRemovedItemComesBackWhereItWas() {
        var items = [Self.steering, Self.a, Self.b, Self.c]
        let removed = NativeQueueRules.remove([Self.b.id], from: &items)
        #expect(removed.map(\.index) == [1] && items.map(\.text) == ["s", "a", "c"])
        NativeQueueRules.insert(removed.map(\.item), atQueuedIndex: removed[0].index, into: &items)
        #expect(items.map(\.text) == ["s", "a", "b", "c"])
        NativeQueueRules.insert([Self.a], atQueuedIndex: 0, into: &items)
        #expect(items.count == 4, "an item already there is not added twice")
    }

    @Test func steeringItemsCannotBeEditedOrRemoved() {
        var items = [Self.steering, Self.a]
        #expect(!NativeQueueRules.edit(Self.steering.id, text: "x", in: &items))
        #expect(NativeQueueRules.remove([Self.steering.id], from: &items).isEmpty)
        #expect(NativeQueueRules.edit(Self.a.id, text: "a2", in: &items) && items[1].text == "a2")
    }

    @Test func editingReleasesTheHold() {
        var items = [Self.a]
        NativeQueueRules.hold(Self.a.id, true, in: &items)
        #expect(items[0].held)
        NativeQueueRules.edit(Self.a.id, text: "saved", in: &items)
        #expect(!items[0].held)
    }

    @Test func steeringMovesToTheEndOfTheSteeringItemsAndBackToTheQueuesHead() {
        var items = [Self.steering, Self.a, Self.b, Self.c]
        #expect(NativeQueueRules.steer([Self.c.id, Self.a.id], in: &items) == [Self.c.id, Self.a.id])
        #expect(items.map(\.text) == ["s", "c", "a", "b"] && items.map(\.state) == [.steering, .steering, .steering, .queued])
        #expect(NativeQueueRules.unsteer(Self.a.id, in: &items))
        #expect(items.map(\.text) == ["s", "c", "a", "b"] && items[2].state == .queued, "back as the queue's first")
        #expect(!NativeQueueRules.unsteer(Self.b.id, in: &items))
    }

    @Test func normalizingPutsSteeringFirstKeepingOrder() {
        var items = [Self.a, Self.steering, Self.b, Self.item("t", 8, state: .steering)]
        NativeQueueRules.normalize(&items)
        #expect(items.map(\.text) == ["s", "t", "a", "b"])
    }
}
