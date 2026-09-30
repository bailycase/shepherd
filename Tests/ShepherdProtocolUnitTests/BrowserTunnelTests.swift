import Foundation
import Testing
import ShepherdCore
@testable import ShepherdProtocol

/// Browser tunnels on the wire (docs/browser.md › Remote): the frames, the credit arithmetic that
/// keeps a slow end from making the other buffer without bound, chunking, and which URLs a tunnel serves.
@Suite("Browser tunnel")
struct BrowserTunnelTests {
    static let agent = AgentID(rawValue: "agent")
    static let frames: [BrowserTunnelFrame] = [
        .open(tunnel: 1, agentID: agent, port: 5173),
        .opened(tunnel: 1),
        .data(tunnel: 1, bytes: Data("GET / HTTP/1.1\r\nHost: localhost:5173\r\n\r\n".utf8)),
        .data(tunnel: 2, bytes: Data([0x00, 0xFF, 0x7F])),
        .credit(tunnel: 1, bytes: 65_536),
        .finish(tunnel: 1),
        .close(tunnel: 1, code: BrowserTunnelCode.refused),
        .close(tunnel: 3, code: nil),
        .keepalive(tunnel: 4),
    ]

    @Test(arguments: frames)
    func everyFrameRoundTripsInBothDirections(_ frame: BrowserTunnelFrame) throws {
        #expect(try Wire.roundTrip(RemoteRequest.tunnel(frame)) == .tunnel(frame))
        #expect(try Wire.roundTrip(RemoteReply.tunnel(frame)) == .tunnel(frame))
    }

    @Test func aTunnelFrameIsOneObjectUnderItsType() throws {
        let object = try Wire.object(RemoteRequest.tunnel(.open(tunnel: 9, agentID: Self.agent, port: 3000)))
        #expect(object["type"] as? String == "tunnel")
        #expect(object["id"] == nil, "nothing answers a tunnel frame by id")
        #expect(object["frame"] != nil)
    }

    @Test func aFrameNamesItsTunnelAndCountsOnlyDataBytes() {
        for frame in Self.frames { #expect(frame.tunnel >= 1) }
        #expect(BrowserTunnelFrame.data(tunnel: 1, bytes: Data(count: 5)).payloadBytes == 5)
        #expect(BrowserTunnelFrame.credit(tunnel: 1, bytes: 500).payloadBytes == 0)
    }

    @Test func aFullChunkStaysWellUnderTheFrameCap() throws {
        let frame = BrowserTunnelFrame.data(tunnel: 1_000_000, bytes: Data(repeating: 0xFF, count: BrowserTunnelLimits.chunkBytes))
        let line = try NDJSON.encode(RemoteReply.tunnel(frame))
        #expect(line.count < NDJSON.maxPayloadBytes / 10, "a 48 KiB chunk is about 64 KiB of base64")
    }

    @Test func theHostAndTheClientListThePairsCapability() {
        #expect(RemoteProtocol.capabilities.contains(RemoteProtocol.browserTunnelCapability))
        #expect(RemoteProtocol.clientCapabilities.contains(RemoteProtocol.browserTunnelCapability))
        #expect(RemoteProtocol.browserTunnelCapability == "browser.tunnel.v1")
    }

    @Test func theTerminalActionNeedsTheTunnelCapability() {
        #expect(RemoteAgentAction.openTerminal(cwd: "/r", command: "pnpm dev").capability == RemoteProtocol.browserTunnelCapability)
    }

    // MARK: Credit

    @Test func aSenderSendsNoMoreThanTheWindowUntilTheOtherEndTakesSome() {
        var credit = BrowserTunnelCredit()
        var sent = 0
        while true {
            let n = credit.take(BrowserTunnelLimits.chunkBytes)
            if n == 0 { break }
            sent += n
        }
        #expect(sent == BrowserTunnelLimits.window)
        #expect(credit.available == 0)
        credit.grant(1_000)
        #expect(credit.take(BrowserTunnelLimits.chunkBytes) == 1_000)
    }

    @Test func aChunkNeverExceedsTheChunkSizeOrWhatIsWanted() {
        var credit = BrowserTunnelCredit()
        #expect(credit.take(10) == 10)
        #expect(credit.take(10_000_000) == BrowserTunnelLimits.chunkBytes)
        #expect(credit.take(0) == 0)
        #expect(credit.take(-5) == 0)
    }

    @Test func aPeerCannotGrantMoreThanTheWindowIsWorth() {
        var credit = BrowserTunnelCredit()
        credit.grant(50_000_000)
        #expect(credit.available == BrowserTunnelLimits.window)
        credit.grant(-3)
        #expect(credit.available == BrowserTunnelLimits.window)
    }

    // MARK: Receipt

    @Test func aReceiverGivesCreditBackInBatches() {
        var receipt = BrowserTunnelReceipt()
        let first = receipt.received(BrowserTunnelLimits.chunkBytes)
        #expect(first)
        #expect(receipt.taken(BrowserTunnelLimits.chunkBytes) == nil, "48 KiB is under the 64 KiB batch")
        let second = receipt.received(BrowserTunnelLimits.chunkBytes)
        #expect(second)
        #expect(receipt.taken(BrowserTunnelLimits.chunkBytes) == 2 * BrowserTunnelLimits.chunkBytes)
        #expect(receipt.owed == 0 && receipt.held == 0)
    }

    @Test func aReceiverRefusesBytesTheSenderHadNoCreditFor() {
        var receipt = BrowserTunnelReceipt()
        var sent = 0
        while receipt.received(BrowserTunnelLimits.chunkBytes) { sent += BrowserTunnelLimits.chunkBytes }
        #expect(sent == 5 * BrowserTunnelLimits.chunkBytes, "the sixth 48 KiB chunk is past a 256 KiB window")
        let rest = receipt.received(BrowserTunnelLimits.window - sent)
        #expect(rest, "exactly the window is allowed")
        sent = BrowserTunnelLimits.window
        let oneMore = receipt.received(1)
        let negative = receipt.received(-1)
        #expect(!oneMore)
        #expect(!negative)
        // Bytes that are written out but not yet given back still count against the window.
        _ = receipt.taken(BrowserTunnelLimits.chunkBytes)
        #expect(receipt.held == BrowserTunnelLimits.window - BrowserTunnelLimits.chunkBytes)
    }

    /// The pair never deadlocks: however the receiver takes bytes, a sender at zero credit is
    /// always owed something it will be given.
    @Test(arguments: [1, 700, 4_096, 48 * 1024, 100_000])
    func aSenderIsNeverStuckWhateverSizeTheReceiverTakes(_ step: Int) {
        var credit = BrowserTunnelCredit()
        var receipt = BrowserTunnelReceipt()
        var inFlight = 0
        var total = 0
        var overran = false
        var stuck = false
        // Pump 2 MiB through: send whenever there is credit, take `step` at a time.
        while total < 2 * 1024 * 1024 {
            let n = credit.take(BrowserTunnelLimits.chunkBytes)
            if n > 0 {
                if !receipt.received(n) { overran = true }
                inFlight += n
                total += n
                continue
            }
            // No credit: something is in flight for the receiver to take, so it makes progress.
            if inFlight == 0 { stuck = true; break }
            let taking = min(step, inFlight)
            inFlight -= taking
            if let back = receipt.taken(taking) { credit.grant(back) }
        }
        #expect(!overran, "the sender never sent past its credit")
        #expect(!stuck, "at zero credit something is always in flight")
    }

    @Test func aReceiverNeverGivesBackMoreThanItTook() {
        var receipt = BrowserTunnelReceipt()
        let received = receipt.received(1_000)
        #expect(received)
        #expect(receipt.taken(5_000) == nil)
        #expect(receipt.owed == 1_000)
    }

    // MARK: Chunks

    @Test func dataIsCutIntoOrderedChunksOfAtMostTheChunkSize() {
        let data = Data((0..<(BrowserTunnelLimits.chunkBytes * 2 + 7)).map { UInt8($0 % 251) })
        let chunks = BrowserTunnelChunks.split(data)
        #expect(chunks.map(\.count) == [BrowserTunnelLimits.chunkBytes, BrowserTunnelLimits.chunkBytes, 7])
        #expect(chunks.reduce(Data(), +) == data)
        #expect(BrowserTunnelChunks.split(Data()).isEmpty)
        #expect(BrowserTunnelChunks.split(Data([1]), size: 5) == [Data([1])])
    }

    // MARK: Which pages a tunnel serves

    @Test(arguments: [
        ("http://localhost:5173/checkout", 5173), ("http://127.0.0.1:3000", 3000), ("http://[::1]:8080/x", 8080),
        ("https://localhost:8443", 8443), ("http://localhost/", 80), ("https://localhost", 443), ("HTTP://LOCALHOST:4173", 4173),
    ] as [(String, Int)])
    func aLoopbackPageGoesThroughTheTunnelOnItsPort(_ url: String, _ port: Int) throws {
        #expect(BrowserTunnelTarget.port(of: try #require(URL(string: url))) == port)
    }

    @Test(arguments: [
        "https://example.com/", "http://192.168.1.20:5173", "http://build-01.local:5173", "http://foo.localhost:5173", "about:blank",
        "file:///tmp/x.html", "data:text/html,hi", "http://0.0.0.0:3000", "ftp://localhost:21",
    ])
    func anyOtherPageLoadsFromTheViewerAsItAlwaysDid(_ url: String) throws {
        #expect(BrowserTunnelTarget.port(of: try #require(URL(string: url))) == nil)
    }
}

@Suite("Dev servers")
struct DevServerWireTests {
    @Test func aDevServerRoundTripsAndKeepsItsPath() throws {
        let server = DevServer(script: "dev", command: "pnpm dev", packageName: "acme-web", directory: "/host/repo/apps/web",
                               manifest: "apps/web/package.json", port: 5173)
        #expect(try Wire.roundTrip(server) == server)
        #expect(server.detail == "from apps/web/package.json · acme-web")
        #expect(server.url?.absoluteString == "http://localhost:5173")
        #expect(server.id == "/host/repo/apps/web#dev")
    }

    @Test func aServerWithNoKnownPortHasNoURL() {
        #expect(DevServer(script: "start", command: "npm start", packageName: nil, directory: "/r", manifest: "package.json", port: nil).url == nil)
    }
}
