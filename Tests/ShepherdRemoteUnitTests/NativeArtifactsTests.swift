import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdRemote

/// Artifacts (docs/design/side-pane-artifacts.md): the files a thread's successful `write` calls made, once each, newest first, with a kind
/// from the extension and a coarse age; and the client's fetching of one.
@Suite("Artifacts")
struct NativeArtifactsTests {
    private func write(_ path: String, status: String = "complete", error: Bool = false, at time: Double? = nil, id: String = UUID().uuidString) -> NativeActivityCall {
        let args = #"{"content":"x","path":"\#(path)"}"#
        return NativeActivityCall(Fixture.tool("write", args: args, error: error, status: status, id: "e-\(id)", callID: id, startedAt: time.map { $0 - 500 }, timestamp: time))
    }

    @Test func everySuccessfulWriteIsAnArtifactOnceNewestFirst() {
        let made = nativeArtifacts([write("docs/plan.md", at: 1_000), write("report.html", at: 2_000), write("docs/plan.md", at: 3_000), write("a.svg", at: 4_000)])
        #expect(made.map(\.path) == ["a.svg", "docs/plan.md", "report.html"], "a rewrite is the same artifact, now the second newest")
        #expect(made.map(\.name) == ["a.svg", "plan.md", "report.html"])
        #expect(made.map(\.createdAt) == [4_000, 3_000, 2_000], "its age is its latest write's")
    }

    @Test func aFailedStoppedOrRunningWriteMadeNothing() {
        let stopped = write("stopped.md", status: "aborted", error: true)
        #expect(stopped.stopped)
        #expect(nativeArtifacts([write("failed.md", error: true), stopped, write("running.md", status: "running"), write("ok.md", at: 5)]).map(\.path) == ["ok.md"])
    }

    @Test func otherToolsAndWriteWithoutAPathMakeNothing() {
        let read = NativeActivityCall(Fixture.tool("read", args: #"{"path":"a.md"}"#, output: "x"))
        let edit = NativeActivityCall(Fixture.tool("edit", args: #"{"path":"b.md","oldText":"a","newText":"b"}"#))
        let bare = NativeActivityCall(Fixture.tool("write", args: "{}"))
        #expect(nativeArtifacts([read, edit, bare]).isEmpty)
    }

    @Test func derivesFromMessagesToo() {
        let messages = [Fixture.tool("write", args: #"{"path":"x/y.md","content":"a"}"#, id: "1", callID: "c1", timestamp: 10),
                        Fixture.tool("bash", args: #"{"command":"ls"}"#, id: "2", callID: "c2")]
        #expect(nativeArtifacts(messages).map(\.path) == ["x/y.md"])
    }

    @Test(arguments: [
        ("a.md", NativeArtifactKind.markdown), ("A.MARKDOWN", .markdown), ("notes.mdx", .markdown),
        ("page.html", .html), ("page.HTM", .html), ("logo.svg", .svg),
        ("main.swift", .text), ("Makefile", .text), ("data.json", .text), ("archive.tar.gz", .text), (".md", .text), ("dir.md/readme", .text),
    ] as [(String, NativeArtifactKind)])
    func theKindComesFromTheExtension(path: String, kind: NativeArtifactKind) {
        #expect(NativeArtifactKind(path: path) == kind)
    }

    @Test func aKindSaysWhetherItPreviewsAndWhetherTheThreadDrawsACard() {
        #expect(NativeArtifactKind.allCases.filter(\.hasPreview) == [.markdown, .html, .svg])
        #expect(NativeArtifactKind.allCases.filter(\.showsCard) == [.markdown, .html, .svg])
        #expect(NativeArtifactKind.html.label == "HTML" && NativeArtifactKind.markdown.label == "Markdown")
    }

    @Test(arguments: [(0.0, "just now"), (59.0, "just now"), (60.0, "1m ago"), (360.0, "6m ago"), (3_599.0, "59m ago"), (3_600.0, "1h ago"),
                      (86_399.0, "23h ago"), (86_400.0, "1d ago"), (-30.0, "just now")] as [(Double, String)])
    func theAgeIsCoarse(seconds: Double, text: String) {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(NativeArtifactAge.text((now.timeIntervalSince1970 - seconds) * 1000, now: now) == text)
    }

    @Test func theDetailLineIsKindAndAgeWithNoVersion() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let artifact = NativeArtifact(path: "r.html", createdAt: (now.timeIntervalSince1970 - 360) * 1000)
        #expect(artifact.detail(now: now) == "HTML · 6m ago")
        #expect(NativeArtifact(path: "r.html").detail(now: now) == "HTML")
    }

    /// A Markdown log of thousands of items laid out as prose hung the window; past the limit it reads as source.
    @Test func aHugeMarkdownFileIsShownAsSource() {
        let artifact = NativeArtifact(path: "log.md")
        let small = Data("# Plan\n\n- one\n".utf8)
        guard case .markdown(let blocks, _) = NativeArtifactDocument(artifact, data: small) else { Issue.record("not prose"); return }
        #expect(!blocks.isEmpty)
        let huge = Data(String(repeating: "- line\n", count: NativeArtifactDocument.markdownPreviewBytes / 7 + 1).utf8)
        #expect(NativeArtifactDocument(artifact, data: huge) == .text(String(decoding: huge, as: UTF8.self)))
    }
}

/// Where a thread says it: the "Made an artifact" line, its card, and the "Edited N files" count that must not change.
@Suite("Artifacts in the thread")
struct ArtifactThreadTests {
    private func write(_ path: String, _ id: String, status: String = "complete", error: Bool = false, at time: Double = 1_000) -> NativeThreadMessage {
        Fixture.tool("write", args: #"{"content":"x","path":"\#(path)"}"#, error: error, status: status, id: "e-\(id)", callID: id, startedAt: time - 500, timestamp: time)
    }
    private func prose(_ text: String, id: String) -> NativeThreadMessage {
        NativeThreadMessage(entryID: id, role: "assistant", blocks: [NativeThreadBlock(kind: .text, text: text)], status: "stop")
    }
    private func tool(_ name: String, _ args: String, id: String) -> NativeThreadMessage { Fixture.tool(name, args: args, id: "e-\(id)", callID: id, timestamp: 900) }

    @Test func aWrittenReportIsItsOwnLineWithItsNameAndNoVersion() throws {
        let presentation = nativeTurnPresentation([write("out/Load test report.html", "a")], live: false)
        guard case .activity(_, let bursts)? = presentation.items.first else { Issue.record("no line"); return }
        let burst = try #require(bursts.first)
        #expect(burst.label == "Made an artifact" && burst.meta == "Load test report.html")
        #expect(burst.artifact?.path == "out/Load test report.html")
        #expect(!burst.accessibilityLabel.contains(" v2") && !burst.meta.contains(" v"))
        #expect(burst.expandable, "its calls are still there to expand where no pane can open it")
    }

    @Test func theCardComesAfterTheWordsThatFollowTheLineOrAtTheTurnsEnd() {
        let withWords = nativeTurnPresentation([write("r.html", "a"), prose("The report has the chart.", id: "p"), prose("More.", id: "q")], live: false)
        #expect(withWords.items.map(\.id).count == 4)
        let kinds = withWords.items.map { item -> String in
            switch item {
            case .activity: "line"
            case .prose: "prose"
            case .artifact: "card"
            default: "other"
            }
        }
        #expect(kinds == ["line", "prose", "card", "prose"], "\(kinds)")
        let atTheEnd = nativeTurnPresentation([write("r.html", "a")], live: false)
        #expect(atTheEnd.items.count == 2)
        if case .artifact(_, let artifact)? = atTheEnd.items.last { #expect(artifact.name == "r.html") } else { Issue.record("no card") }
    }

    @Test func aFileWrittenTwiceInATurnHasOneCardAtItsLatestWrite() {
        let presentation = nativeTurnPresentation([write("r.md", "a", at: 1_000), write("r.md", "b", at: 2_000)], live: false)
        let cards = presentation.items.compactMap { item -> NativeArtifact? in if case .artifact(_, let artifact) = item { artifact } else { nil } }
        #expect(cards.count == 1 && cards[0].createdAt == 2_000)
    }

    @Test func sourceFilesAndFailedWritesGetNoLineOrCard() {
        let presentation = nativeTurnPresentation([write("a.swift", "a"), write("b.md", "b", error: true), write("c.md", "c", status: "running")], live: false)
        #expect(presentation.items.allSatisfy { if case .artifact = $0 { false } else { true } })
        guard case .activity(_, let bursts)? = presentation.items.first else { Issue.record("no line"); return }
        #expect(bursts.allSatisfy { $0.artifact == nil })
    }

    @Test func aReportBreaksUpAnEditBurstSoItsLineIsItsOwn() {
        let presentation = nativeTurnPresentation([tool("edit", #"{"path":"a.swift","oldText":"a","newText":"b"}"#, id: "e1"), write("r.md", "w"),
                                                   tool("edit", #"{"path":"b.swift","oldText":"a","newText":"b"}"#, id: "e2")], live: false)
        guard case .activity(_, let bursts)? = presentation.items.first else { Issue.record("no line"); return }
        #expect(bursts.map(\.label) == ["Edited 1 file", "Made an artifact", "Edited 1 file"])
    }

    @Test func theEditedFilesCardStillCountsTheWrittenReport() throws {
        let changes = try #require(nativeTurnChanges([NativeActivityCall(write("r.md", "w")), NativeActivityCall(tool("edit", #"{"path":"a.swift","oldText":"a","newText":"b"}"#, id: "e"))]))
        #expect(changes.files.map(\.path) == ["r.md", "a.swift"], "a report is still a changed file in the repository")
    }

    @Test func aStoppedWriteIsNotAnArtifactLine() {
        let stopped = write("r.md", "a", status: "aborted", error: true)
        let presentation = nativeTurnPresentation([stopped], live: false)
        guard case .activity(_, let bursts)? = presentation.items.first else { Issue.record("no line"); return }
        #expect(bursts.first?.artifact == nil && bursts.first?.label == "Write stopped")
    }

    @Test func aWritesLineCountSurvivesTheHostCuttingItsContent() {
        let cut = NativeActivityCall(Fixture.tool("write", args: #"{"content":"line","contentLines":5000,"path":"big.html"}"#, id: "e", callID: "c"))
        #expect(cut.added == 5000 && cut.path == "big.html")
        let whole = NativeActivityCall(Fixture.tool("write", args: #"{"content":"a\nb\nc\n","path":"x.md"}"#, id: "f", callID: "d"))
        #expect(whole.added == 3)
    }
}

/// The client's fetching of one artifact: pieces in order into one file, a host that answers wrongly is not believed.
@MainActor
@Suite("Artifact fetching")
struct NativeThreadArtifactsTests {
    @MainActor final class Host {
        var files: [String: Data]
        var asked: [(path: String, offset: Int)] = []
        var chunk = NativeImage.chunkBytes
        var lie: ((NativeArtifactChunk) -> NativeArtifactChunk)?
        var failure: NativeThreadResult?
        init(_ files: [String: Data]) { self.files = files }

        func answer(_ request: NativeThreadRequest) async throws -> NativeThreadResult {
            guard case .artifact(_, let path, let offset) = request else { return .failure(code: "invalid", message: "") }
            asked.append((path, offset))
            if let failure { return failure }
            guard let data = files[path], offset <= data.count else { return .failure(code: NativeArtifactCode.unknown, message: "") }
            let end = min(data.count, offset + chunk)
            let piece = NativeArtifactChunk(path: path, totalBytes: data.count, offset: offset, data: data[offset..<end])
            return .artifactChunk(value: lie?(piece) ?? piece)
        }
    }

    private static let artifact = NativeArtifact(path: "r.md", createdAt: 1)

    private func client(_ host: Host) -> NativeThreadArtifacts {
        let client = NativeThreadArtifacts()
        client.configure(sessionID: "s") { try await host.answer($0) }
        return client
    }

    @Test func piecesInOrderMakeTheFileAndItIsKept() async {
        let data = Data((0..<700_000).map { UInt8(truncatingIfNeeded: $0) })
        let host = Host(["r.md": data])
        let client = client(host)
        #expect(await client.load(Self.artifact) == .file(data))
        #expect(host.asked.map(\.offset) == [0, 262_144, 524_288], "256 KiB at a time")
        #expect(await client.load(Self.artifact) == .file(data))
        #expect(host.asked.count == 3 && client.started == 1, "kept: no second fetch")
    }

    @Test func anEmptyFileIsOneEmptyPiece() async {
        let host = Host(["r.md": Data()])
        #expect(await client(host).load(Self.artifact) == .file(Data()))
        #expect(host.asked.count == 1)
    }

    @Test func aRewriteIsAFreshFetch() async {
        let host = Host(["r.md": Data("one".utf8)])
        let client = client(host)
        #expect(await client.load(Self.artifact) == .file(Data("one".utf8)))
        host.files["r.md"] = Data("two".utf8)
        #expect(await client.load(NativeArtifact(path: "r.md", createdAt: 2)) == .file(Data("two".utf8)))
    }

    @Test func aNewSessionDropsWhatWasHeld() async {
        let host = Host(["r.md": Data("one".utf8)])
        let client = client(host)
        _ = await client.load(Self.artifact)
        client.configure(sessionID: "t") { try await host.answer($0) }
        #expect(client.cached(Self.artifact) == nil)
    }

    @Test func theHostsRefusalsAreUnavailableAndAConnectionIsAFailure() async {
        let host = Host([:])
        #expect(await client(host).load(Self.artifact) == .unavailable)
        host.failure = .failure(code: NativeArtifactCode.unavailable, message: "gone")
        #expect(await client(host).load(Self.artifact) == .unavailable)
        host.failure = .failure(code: "stale_session", message: "")
        #expect(await client(host).load(Self.artifact) == .failed("The thread changed. Open it again."))
        let broken = NativeThreadArtifacts()
        broken.configure(sessionID: "s") { _ in throw URLError(.notConnectedToInternet) }
        #expect(await broken.load(Self.artifact) == .failed(NativeThreadArtifacts.connectionMessage))
    }

    @Test(arguments: ["path", "offset", "total", "size", "empty"])
    func aHostThatAnswersWronglyIsNotBelieved(lie: String) async {
        let host = Host(["r.md": Data(repeating: 7, count: 300_000)])
        host.lie = { piece in
            var piece = piece
            switch lie {
            case "path": piece.path = "other.md"
            case "offset": piece.offset += 1
            case "total": piece.totalBytes = NativeArtifactChunk.maxBytes + 1
            case "size": piece.data = Data(repeating: 7, count: NativeImage.chunkBytes + 1)
            default: piece.data = Data()
            }
            return piece
        }
        #expect(await client(host).load(Self.artifact) == .unavailable)
    }

    @Test func aSizeThatMovesBetweenPiecesIsNotBelieved() async {
        let host = Host(["r.md": Data(repeating: 7, count: 300_000)])
        host.lie = { piece in
            var piece = piece
            if piece.offset > 0 { piece.totalBytes += 10 }
            return piece
        }
        #expect(await client(host).load(Self.artifact) == .unavailable)
    }

    @Test func withoutASessionNothingIsAsked() async {
        #expect(await NativeThreadArtifacts().load(Self.artifact) == .failed("The thread is not ready."))
    }
}
