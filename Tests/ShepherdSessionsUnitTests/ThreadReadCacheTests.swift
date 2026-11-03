import Foundation
import Testing
@testable import ShepherdSessions

@Suite("Shared thread read budget")
struct ThreadReadCacheTests {
    @Test func aHundredOwnersShareOneByteLRUAndReleaseIndependently() {
        let cache = ThreadReadCache(byteLimit: 100)
        let owners = (0..<101).map { _ in UUID() }
        for index in 0..<100 {
            cache.insert(.image(("image/png", Data(repeating: UInt8(index), count: 4))), bytes: 4, owner: owners[index], name: "same-image-id")
            #expect(cache.retainedBytes <= 100)
        }
        #expect(cache.value(owner: owners[0], name: "same-image-id") == nil)
        guard case .image(let kept) = cache.value(owner: owners[75], name: "same-image-id") else { Issue.record("missing oldest retained owner"); return }
        #expect(kept.data == Data(repeating: 75, count: 4))
        cache.insert(.image(("image/png", Data(repeating: 100, count: 4))), bytes: 4, owner: owners[100], name: "same-image-id")
        #expect(cache.value(owner: owners[76], name: "same-image-id") == nil, "touching owner 75 updates the shared LRU")
        #expect(cache.value(owner: owners[75], name: "same-image-id") != nil)
        for owner in owners { cache.remove(owner: owner) }
        #expect(cache.retainedBytes == 0)
    }

    @Test func workReservationsAreAggregateAndSurviveOwnerInvalidation() {
        let cache = ThreadReadCache(byteLimit: 100, inFlightLimit: 32)
        var working = (0..<4).compactMap { _ in cache.reserve(bytes: 8) }
        #expect(working.count == 4 && cache.inFlightBytes == 32)
        #expect(cache.reserve(bytes: 1) == nil)
        cache.remove(owner: UUID())
        #expect(cache.inFlightBytes == 32, "retiring an owner does not make its still-held worker free")
        working.removeLast()
        #expect(cache.inFlightBytes == 24)
        var replacement = cache.reserve(bytes: 8)
        #expect(replacement != nil && cache.inFlightBytes == 32)
        working.removeAll()
        replacement = nil
        #expect(cache.inFlightBytes == 0)
    }
}
