import Foundation
import Testing
@testable import ShepherdRemote

/// Finished board pictures kept on disk: keyed by the board's content, bounded, least recently used first out.
@Suite struct BoardPictureCacheTests {
    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("bpc-\(UUID().uuidString.prefix(8))", isDirectory: true)
    }

    private func key(_ content: String = "aa", props: String? = nil, board: CGSize = CGSize(width: 1280, height: 800),
                     width: Int = 160, scale: Int = 2, renderer: String = "1") -> BoardPictureKey {
        BoardPictureKey(content: content, props: props, board: board, width: width, scale: scale, renderer: renderer)
    }

    @Test func everyFieldOfTheKeyNamesADifferentPicture() {
        let base = key()
        let others = [key("bb"), key(props: "{}"), key(board: CGSize(width: 1280, height: 801)), key(width: 320), key(scale: 3),
                      key(renderer: "2")]
        #expect(Set(others.map(\.name) + [base.name]).count == others.count + 1)
        #expect(key().name == base.name)
    }

    @Test func aPictureKeptComesBackAndAnUnchangedBoardNeverDrawsAgain() {
        let cache = BoardPictureCache(directory: folder())
        defer { cache.removeAll() }
        cache.store(Data("png".utf8), for: key("aa"))
        #expect(cache.contains(key("aa")))
        #expect(cache.data(for: key("aa")) == Data("png".utf8))
        // A new instance over the same folder (the app relaunched) still has it.
        #expect(BoardPictureCache(directory: cache.directory).contains(key("aa")))
    }

    @Test func aChangedBoardDrawsAgain() {
        let cache = BoardPictureCache(directory: folder())
        defer { cache.removeAll() }
        cache.store(Data("old".utf8), for: key("aa"))
        // Its file changed (new hash), its tweak changed, it was resized, or it is shown larger: none has a picture.
        for changed in [key("bb"), key("aa", props: "{\"n\":1}"), key("aa", board: CGSize(width: 390, height: 844)), key("aa", width: 320)] {
            #expect(!cache.contains(changed))
            #expect(cache.data(for: changed) == nil)
        }
        cache.store(Data("new".utf8), for: key("bb"))
        #expect(cache.data(for: key("bb")) == Data("new".utf8))
        #expect(cache.data(for: key("aa")) == Data("old".utf8))
    }

    @Test func pastItsLimitTheLeastRecentlyUsedGoFirst() {
        let clock = Clock()
        let cache = BoardPictureCache(directory: folder(), byteLimit: 100, now: { clock.tick() })
        defer { cache.removeAll() }
        let block = Data(repeating: 1, count: 40)
        cache.store(block, for: key("a"))
        cache.store(block, for: key("b"))
        // `a` is used again, so `b` is the oldest.
        #expect(cache.data(for: key("a")) != nil)
        cache.store(block, for: key("c"))
        #expect(cache.bytes <= 100)
        #expect(cache.contains(key("a")))
        #expect(!cache.contains(key("b")))
        #expect(cache.contains(key("c")))
    }

    @Test func theNewestPictureSurvivesEvenWhenItAloneIsOverTheLimit() {
        let cache = BoardPictureCache(directory: folder(), byteLimit: 10)
        defer { cache.removeAll() }
        cache.store(Data(repeating: 1, count: 50), for: key("a"))
        #expect(cache.contains(key("a")))
        cache.store(Data(repeating: 1, count: 50), for: key("b"))
        #expect(!cache.contains(key("a")))
        #expect(cache.contains(key("b")))
    }

    @Test func aFolderOverItsLimitIsTrimmedWhenOpenedAndKeepsUseOrder() {
        let clock = Clock()
        let directory = folder()
        let first = BoardPictureCache(directory: directory, byteLimit: 1_000, now: { clock.tick() })
        defer { first.removeAll() }
        for name in ["a", "b", "c"] { first.store(Data(repeating: 1, count: 40), for: key(name)) }
        #expect(first.data(for: key("a")) != nil)
        let smaller = BoardPictureCache(directory: directory, byteLimit: 100)
        #expect(smaller.bytes <= 90)
        #expect(smaller.contains(key("a")))
        #expect(!smaller.contains(key("b")))
    }

    @Test func aPictureRemovedIsGoneAndForgettingEmptiesTheFolder() {
        let cache = BoardPictureCache(directory: folder())
        cache.store(Data("x".utf8), for: key("a"))
        cache.store(Data("y".utf8), for: key("b"))
        cache.remove(key("a"))
        #expect(!cache.contains(key("a")) && cache.contains(key("b")))
        cache.removeAll()
        #expect(cache.count == 0 && cache.bytes == 0)
        #expect(!FileManager.default.fileExists(atPath: cache.directory.path))
    }

    @Test func aBoardIsDrawnAtTheSmallestWidthThatIsSharpWhereItIsShown() {
        #expect(BoardPictureTier.width(boardWidth: 1280, zoom: 0.05) == 160)
        #expect(BoardPictureTier.width(boardWidth: 1280, zoom: 0.25) == 320)
        #expect(BoardPictureTier.width(boardWidth: 1280, zoom: 0.26) == 640)
        #expect(BoardPictureTier.width(boardWidth: 1280, zoom: 4) == 640)
    }
}

/// A clock that moves one second at each look, so use order is exact.
private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: TimeInterval = 1_000_000

    func tick() -> Date {
        lock.lock(); defer { lock.unlock() }
        seconds += 1
        return Date(timeIntervalSince1970: seconds)
    }
}
