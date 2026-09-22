import Foundation
import Testing
@testable import ShepherdProtocol

@Suite("NDJSON framing")
struct FramingTests {
    private struct Probe: Codable, Equatable { var path: String; var n: Int }

    @Test func encodingIsOneSortedLineWithoutEscapedSlashes() throws {
        let line = try NDJSON.encode(Probe(path: "/tmp/a", n: 1))
        #expect(String(decoding: line, as: UTF8.self) == "{\"n\":1,\"path\":\"/tmp/a\"}\n")
    }

    @Test func embeddedNewlinesAreEscapedSoTheFrameStaysOneLine() throws {
        let line = try NDJSON.encode(Probe(path: "a\nb\r\n", n: 0))
        #expect(line.filter { $0 == 0x0A }.count == 1)
        #expect(try NDJSON.decode(Probe.self, from: line.dropLast()) == Probe(path: "a\nb\r\n", n: 0))
    }

    @Test func thePayloadCapIsOneMebibyte() {
        #expect(NDJSON.maxPayloadBytes == 1_048_576)
    }
}

@Suite("LineBuffer")
struct LineBufferTests {
    private static func line(_ s: String) -> Data { Data((s + "\n").utf8) }

    @Test func aLineSplitAcrossChunksIsYieldedOnceComplete() throws {
        var buffer = LineBuffer()
        #expect(try buffer.append(Data("{\"a\":".utf8)).isEmpty)
        #expect(try buffer.append(Data("1}\n".utf8)) == [Data("{\"a\":1}".utf8)])
    }

    @Test(arguments: 1...7)
    func anyChunkingYieldsTheSameLines(chunkSize: Int) throws {
        let stream = Self.line("one") + Self.line("two") + Self.line("three")
        var buffer = LineBuffer()
        var lines: [Data] = []
        var offset = 0
        while offset < stream.count {
            let end = min(offset + chunkSize, stream.count)
            lines += try buffer.append(stream.subdata(in: offset..<end))
            offset = end
        }
        #expect(lines.map { String(decoding: $0, as: UTF8.self) } == ["one", "two", "three"])
    }

    @Test func manyLinesInOneChunkAreAllYieldedInOrder() throws {
        var buffer = LineBuffer()
        let stream = (0..<50).map { Self.line("\($0)") }.reduce(Data(), +)
        let lines = try buffer.append(stream)
        #expect(lines.map { String(decoding: $0, as: UTF8.self) } == (0..<50).map(String.init))
    }

    @Test func emptyChunksAndBlankLinesAreHandled() throws {
        var buffer = LineBuffer()
        #expect(try buffer.append(Data()).isEmpty)
        #expect(try buffer.append(Data("\n\n".utf8)) == [Data(), Data()])
    }

    @Test func aPartialTailIsKeptForTheNextChunk() throws {
        var buffer = LineBuffer()
        #expect(try buffer.append(Data("a\nb".utf8)) == [Data("a".utf8)])
        #expect(try buffer.append(Data("c\n".utf8)) == [Data("bc".utf8)])
    }

    @Test func aPayloadExactlyAtTheCapIsAccepted() throws {
        var buffer = LineBuffer()
        let payload = Data(repeating: 0x61, count: NDJSON.maxPayloadBytes)
        #expect(try buffer.append(payload).isEmpty)
        #expect(try buffer.append(Data([0x0A])) == [payload])
    }

    @Test(arguments: [false, true])
    func aPayloadOverTheCapThrowsAndTheBufferRecovers(terminated: Bool) throws {
        var buffer = LineBuffer()
        var oversized = Data(repeating: 0x61, count: NDJSON.maxPayloadBytes + 1)
        if terminated { oversized.append(0x0A) }
        #expect(throws: LineBufferError.payloadTooLarge(bytes: NDJSON.maxPayloadBytes + 1, terminated: terminated)) {
            try buffer.append(oversized)
        }
        #expect(try buffer.append(Self.line("ok")) == [Data("ok".utf8)])
    }

    @Test func anOverflowAcrossChunksIsCaughtBeforeTheNewline() throws {
        var buffer = LineBuffer()
        let half = Data(repeating: 0x61, count: NDJSON.maxPayloadBytes / 2 + 1)
        #expect(try buffer.append(half).isEmpty)
        #expect(throws: LineBufferError.self) { try buffer.append(half) }
    }
}
