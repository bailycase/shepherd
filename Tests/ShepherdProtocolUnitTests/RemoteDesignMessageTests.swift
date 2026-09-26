import Foundation
import Testing
import ShepherdCore
@testable import ShepherdProtocol

enum RemoteDesignSamples {
    static let design = DesignID(rawValue: "design-1")
    static let board = DesignPath("A.dc.html")!
    static let phone = DesignPath("flows/A-phone.dc.html")!
    static let comment = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!
    static let index = DesignIndex(title: "Checkout funnel", boards: [
        board: DesignIndex.Board(x: 0, y: 0, w: 1280, h: 800, title: "A · Funnel first"),
        phone: DesignIndex.Board(x: 1360, y: 0, w: 390, h: 844, title: "A · phone"),
    ], order: [board, phone])
    static let snapshot = DesignSnapshot(designID: design, revision: 7, index: index,
                                         boards: [board: String(repeating: "a", count: 64), phone: String(repeating: "b", count: 64)])
    static let record = Design(id: design, name: "Checkout funnel", agentID: AgentID(rawValue: "agent"),
                               systemNamespace: "acme-web", createdAt: 1_700_000_000_000, lastActiveAt: 1_700_000_100_000, boardCount: 2)
    static let system = DesignSystemSummary(info: DesignSystemInfo(namespace: "acme-web", title: "acme-web", revision: 3,
                                                                  createdAt: 1_700_000_000_000, sources: ["web/static/tokens.css"]),
                                            counts: DesignSystemCounts())
    static let draft = DesignCommentDraft(board: board, tid: 5, path: [1, 1, 0], label: "Checkout funnel", target: "Checkout funnel",
                                          rect: nil, text: "Make the \"drop\" red")
    static let kept = DesignComment(id: comment, number: 1, board: board, tid: 5, path: [1, 1, 0], label: "Checkout funnel",
                                    text: "Make the drop red", createdAt: 1_700_000_000_000)
    static let written = DesignWriteResult(revision: 8, changed: true, sha256: String(repeating: "c", count: 64), created: false,
                                           title: "Checkout funnel", boardCount: 2)

    static let requests: [RemoteDesignRequest] = [
        .list,
        .index(designID: design),
        .boards(designID: design, paths: nil, knownShas: [:]),
        .boards(designID: design, paths: ["A.dc.html", "ds/acme-web/tokens.css"], knownShas: ["A.dc.html": String(repeating: "a", count: 64)]),
        .file(designID: design, path: "fonts/Inter.woff2", sha256: String(repeating: "d", count: 64), offset: 262_144),
        .asset(designID: design, blobID: "3f2a91c0", offset: 0),
        .comments(designID: design),
        .addComment(designID: design, draft: draft, baseRevision: 4),
        .addComment(designID: design, draft: draft, baseRevision: nil),
        .replyToComment(designID: design, commentID: comment, text: "Thanks", baseRevision: 5),
        .resolveComment(designID: design, commentID: comment, resolved: false, baseRevision: nil),
        .writeBoards(designID: design, sources: ["A.dc.html": "<script src=\"./support.js\"></script>\n<x-dc></x-dc>"], baseRevision: 7),
        .updateIndex(designID: design, patch: .object(["boards": .object(["A.dc.html": .object(["x": .number(80), "y": .number(0)])])]),
                     baseRevision: 7),
        .duplicateBoard(designID: design, path: "A.dc.html", baseRevision: 7),
        .restoreVersions(designID: design, versions: ["A.dc.html": 3], ifCurrent: ["A.dc.html": String(repeating: "a", count: 64)]),
        .restoreVersions(designID: design, versions: [:], ifCurrent: nil),
        .system(namespace: "acme-web"),
        .watch(designIDs: [design]),
        .watch(designIDs: []),
    ]

    static let results: [RemoteDesignResult] = [
        .listing(RemoteDesignListing(designs: [
            RemoteDesignSummary(design: record, revision: 7, boardCount: 2, openComments: 1,
                                firstBoard: RemoteDesignFirstBoard(path: board, sha256: String(repeating: "a", count: 64), width: 1280, height: 800)),
            RemoteDesignSummary(design: record, revision: 0, boardCount: 0, openComments: 0, firstBoard: nil),
        ], systems: [system])),
        .listing(RemoteDesignListing(designs: [], systems: [])),
        .index(RemoteDesignIndex(snapshot: snapshot, files: [
            RemoteDesignFileInfo(path: "A.dc.html", sha256: String(repeating: "a", count: 64), size: 31_000),
            RemoteDesignFileInfo(path: "ds/acme-web/tokens.css", sha256: String(repeating: "e", count: 64), size: 2_400),
        ])),
        .files(RemoteDesignFiles(designID: design, revision: 7, changed: [
            RemoteDesignFile(path: "A.dc.html", sha256: String(repeating: "a", count: 64), size: 3, data: Data("<x>".utf8)),
            RemoteDesignFile(path: "fonts/Inter.woff2", sha256: String(repeating: "d", count: 64), size: 400_000, data: nil),
        ], unchanged: ["flows/A-phone.dc.html"], missing: ["gone.css"])),
        .chunk(RemoteDesignChunk(name: "3f2a91c0.png", sha256: String(repeating: "f", count: 64), offset: 0, total: 3, data: Data([0x89, 0x50, 0x4E]))),
        .chunk(RemoteDesignChunk(sha256: String(repeating: "d", count: 64), offset: 262_144, total: 400_000, data: Data([1]))),
        .comments(DesignComments(revision: 5, comments: [kept])),
        .comment(kept, undelivered: "The design agent isn't running."),
        .comment(kept, undelivered: nil),
        .written(written),
        .boardsWritten(RemoteDesignBoardsWrite(result: written, shas: ["A.dc.html": String(repeating: "c", count: 64)], versions: ["A.dc.html": 4])),
        .duplicated(path: DesignPath("A-copy.dc.html")!, result: written),
        .system(DesignSystemRead(summary: system, tokens: nil, readme: "# acme-web\n", files: ["tokens.css", "tokens.json"])),
        .ok,
    ]
}

@Suite("Remote design messages")
struct RemoteDesignMessageTests {
    typealias S = RemoteDesignSamples

    @Test(arguments: RemoteDesignSamples.requests)
    func everyDesignRequestRoundTrips(_ request: RemoteDesignRequest) throws {
        let message = RemoteRequest.design(id: 41, request: request)
        #expect(try Wire.roundTrip(message) == message)
        #expect(try Wire.object(message)["type"] as? String == "design")
    }

    @Test(arguments: RemoteDesignSamples.results)
    func everyDesignResultRoundTrips(_ result: RemoteDesignResult) throws {
        let message = RemoteReply.design(id: 41, result: result)
        #expect(try Wire.roundTrip(message) == message)
    }

    /// Exhaustive on purpose: a new request fails to compile here until it is named, then the
    /// samples fail until it has one.
    static func caseName(_ request: RemoteDesignRequest) -> String {
        switch request {
        case .list, .index, .boards, .file, .asset, .comments, .addComment, .replyToComment, .resolveComment, .writeBoards,
             .updateIndex, .duplicateBoard, .restoreVersions, .system, .watch:
            Wire.caseName(request)
        }
    }

    static func caseName(_ result: RemoteDesignResult) -> String {
        switch result {
        case .listing, .index, .files, .chunk, .comments, .comment, .written, .boardsWritten, .duplicated, .system, .ok:
            Wire.caseName(result)
        }
    }

    @Test func samplesCoverEveryCase() {
        #expect(Set(S.requests.map(Self.caseName)).count == 15)
        #expect(Set(S.results.map(Self.caseName)).count == 11)
    }

    @Test(arguments: [
        RemoteReply.designChanged(designID: RemoteDesignSamples.design, revision: 8, commentsRevision: nil),
        .designChanged(designID: RemoteDesignSamples.design, revision: nil, commentsRevision: 6),
        .designChanged(designID: RemoteDesignSamples.design, revision: 9, commentsRevision: 6),
        .capabilitiesChanged(capabilities: RemoteProtocol.capabilities),
        .capabilitiesChanged(capabilities: []),
    ])
    func pushedDesignRepliesRoundTrip(_ reply: RemoteReply) throws {
        #expect(try Wire.roundTrip(reply) == reply)
    }

    @Test func aDesignChangeLeavesOutWhatDidNotMove() throws {
        let object = try Wire.object(RemoteReply.designChanged(designID: S.design, revision: 8, commentsRevision: nil))
        #expect(Set(object.keys) == ["type", "designID", "revision"])
    }

    /// A client lists the capability so the host sends it pushes; the host lists it to serve.
    @Test func bothSidesListDesigns() {
        #expect(RemoteProtocol.capabilities.contains(RemoteProtocol.designsCapability))
        #expect(RemoteProtocol.clientCapabilities.contains(RemoteProtocol.designsCapability))
    }

    /// A chunk of the largest size still fits one frame once base64-encoded.
    @Test func aFullChunkFitsOneFrame() throws {
        let chunk = RemoteDesignChunk(sha256: String(repeating: "a", count: 64), offset: 0, total: RemoteProtocol.designChunkBytes,
                                      data: Data(repeating: 0xFF, count: RemoteProtocol.designChunkBytes))
        let line = try NDJSON.encode(RemoteReply.design(id: 1, result: .chunk(chunk)))
        #expect(line.count - 1 <= NDJSON.maxPayloadBytes)
        #expect(chunk.isLast)
    }

    @Test(arguments: [
        (RemoteDesignRequest.list, nil as DesignID?, false),
        (.system(namespace: "x"), nil, false),
        (.boards(designID: RemoteDesignSamples.design, paths: nil, knownShas: [:]), RemoteDesignSamples.design, false),
        (.updateIndex(designID: RemoteDesignSamples.design, patch: .null, baseRevision: nil), RemoteDesignSamples.design, true),
        (.addComment(designID: RemoteDesignSamples.design, draft: RemoteDesignSamples.draft, baseRevision: nil), RemoteDesignSamples.design, true),
    ])
    func aRequestNamesItsDesignAndWhetherItWrites(_ request: RemoteDesignRequest, _ design: DesignID?, _ writes: Bool) {
        #expect(request.designID == design)
        #expect(request.writes == writes)
    }

    /// Several boards written at once travel keyed by path and come back in the host's shape.
    @Test func aBoardsWriteKeepsItsPaths() {
        let write = DesignBoardsWrite(result: S.written, shas: [S.board: "c", S.phone: "d"], versions: [S.board: 2])
        #expect(RemoteDesignBoardsWrite(write).write == write)
    }
}
