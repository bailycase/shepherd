import Foundation
import SwiftUI
import Testing
@testable import ShepherdUI

/// Thread links in prose (ThreadLinkA): which links resolve to a chip, which stay words, and that the internal scheme never reaches
/// the conversation's (or the system's) opener.
@Suite("Thread links")
@MainActor
struct ThreadLinkTests {
    static let known = "3f9c2a1e-6b1d-4c3e-9a51-0c7d1e2f4a10"
    static let mini = "9a0b1c2d-3e4f-4a5b-8c6d-7e8f9a0b1c2d"

    static func table(open: @escaping (String) -> Void = { _ in }) -> SHThreadLinks {
        SHThreadLinks([
            SHThreadLink(id: known, title: "Migrate orders to Postgres 17", state: .running, location: "This Mac", project: "orders-db",
                         branch: "agent/pg17-orders"),
            SHThreadLink(id: mini, title: "Fix flaky payment test", state: .running, host: "mini", location: "mini", project: "payments-api"),
        ], open: open)
    }

    @Test func aWellFormedLinkNamesItsAgent() throws {
        #expect(SHThreadLinks.id(in: try #require(URL(string: "shepherd-thread://\(Self.known)"))) == Self.known)
        #expect(SHThreadLinks.id(in: try #require(URL(string: "SHEPHERD-THREAD://\(Self.known)"))) == Self.known, "the scheme ignores case")
        for malformed in ["shepherd-thread://", "shepherd-thread:\(Self.known)", "shepherd-thread://\(Self.known)/turns",
                          "shepherd-thread://\(Self.known)?q=1", "shepherd-thread://\(Self.known)#x", "shepherd-thread://u@\(Self.known)",
                          "https://\(Self.known)", "shepherd-project-task://p/\(Self.known)"] {
            #expect(SHThreadLinks.id(in: try #require(URL(string: malformed))) == nil, "\(malformed) names no thread")
        }
    }

    @Test func aKnownIDResolvesWithItsCurrentTitleAndAnUnknownOneDoesNot() throws {
        let links = Self.table()
        let upper = try #require(URL(string: "shepherd-thread://\(Self.known.uppercased())"))
        #expect(links.link(upper)?.title == "Migrate orders to Postgres 17", "ids compare without case")
        #expect(links.link(try #require(URL(string: "shepherd-thread://\(UUID().uuidString)"))) == nil, "a stale id")
        links.update([])
        #expect(links.link(upper) == nil, "a thread that went no longer resolves")
    }

    /// The chip shows the owner's title, never the words the model wrote; an unresolved link is its words, with no link left.
    @Test func aParagraphDrawsChipsOnlyForThreadsThatResolve() {
        let source = SHProseInline.styled("[the pg thread](shepherd-thread://\(Self.known)) and [gone](shepherd-thread://\(UUID().uuidString)) "
            + "and [it](shepherd-thread://\(Self.mini)/x) and [site](https://example.com).")
        #expect(SHThreadLinks.hasReference(source))
        let built = SHThreadChipText.text(source, links: Self.table(), size: .regular)
        #expect(built.mentions.map(\.title) == ["Migrate orders to Postgres 17"], "only the resolving link is a chip")
        let inert = SHThreadLinks.inert(source)
        #expect(!SHThreadLinks.hasReference(inert))
        #expect(String(inert.characters) == "the pg thread and gone and it and site.")
        #expect(inert.runs.contains { $0.link?.scheme == "https" }, "an ordinary link is left alone")
    }

    @Test func aPressedThreadLinkOpensItsThreadAndNeverReachesTheOpener() throws {
        var opened: [String] = []
        var handedOn: [URL] = []
        let router = SHProseLinkRouter()
        router.outer = OpenURLAction { url in handedOn.append(url); return .handled }
        router.threads = Self.table { opened.append($0) }
        router.open(try #require(URL(string: "shepherd-thread://\(Self.known)")))
        #expect(opened == [Self.known])
        router.open(try #require(URL(string: "shepherd-thread://\(UUID().uuidString)")))   // a stale link does nothing
        router.open(try #require(URL(string: "shepherd-thread://\(Self.known)/extra")))      // a malformed one neither
        router.threads = nil
        router.open(try #require(URL(string: "shepherd-thread://\(Self.known)")))           // no table: nothing opens
        #expect(handedOn.isEmpty, "the internal scheme is never handed on")
        router.open(try #require(URL(string: "https://example.com")))
        #expect(handedOn.map(\.absoluteString) == ["https://example.com"], "ordinary links still reach the conversation's opener")
        #expect(opened == [Self.known])
    }

    /// Copy link copies a Markdown link that any composer can take and that parses back to the same thread.
    @Test func copyLinkIsAMarkdownLinkWithTheCurrentTitle() throws {
        let link = try #require(Self.table().links[Self.known])
        #expect(link.markdown == "[Migrate orders to Postgres 17](shepherd-thread://\(Self.known))")
        let odd = SHThreadLink(id: Self.known, title: "Fix [WIP] \\ parser", state: .idle, location: "This Mac")
        #expect(odd.markdown == "[Fix \\[WIP\\] \\\\ parser](shepherd-thread://\(Self.known))")
        let parsed = SHProseInline.styled(odd.markdown)
        #expect(String(parsed.characters) == "Fix [WIP] \\ parser")
        #expect(parsed.runs.compactMap(\.link).map { SHThreadLinks.id(in: $0) } == [Self.known])
    }

    /// A sent message reads its thread links and nothing else: what the @ picker wrote becomes a chip, an unknown one its words,
    /// and every other character (Markdown included) stays as typed.
    @Test func aSentMessageReadsOnlyItsThreadLinks() throws {
        #expect(SHThreadLinks.linkingThreads(in: "Check **this** [site](https://example.com) and `code`.") == nil, "no thread link: as typed")
        let pg = try #require(Self.table().links[Self.known])
        let typed = "Before you touch **orders**, check \(pg.markdown) and [gone](shepherd-thread://\(UUID().uuidString)) "
            + "and [Fix \\[WIP\\]](SHEPHERD-THREAD://\(Self.mini)) and [x](https://example.com)."
        let linked = try #require(SHThreadLinks.linkingThreads(in: typed))
        #expect(String(linked.characters) == "Before you touch **orders**, check Migrate orders to Postgres 17 and gone and Fix [WIP] "
            + "and [x](https://example.com).", "only thread links are read; the rest stays as typed")
        let ids = linked.runs.compactMap(\.link).map { SHThreadLinks.id(in: $0)?.lowercased() }
        #expect(ids.count == 3 && ids[0] == Self.known && ids[2] == Self.mini)
        let built = SHThreadChipText.text(linked, links: Self.table(), size: .regular)
        #expect(built.mentions.map(\.title) == ["Migrate orders to Postgres 17", "Fix flaky payment test"],
                "the known two are chips with their current titles; the gone one is its words")
        #expect(SHThreadLinks.linkingThreads(in: "[half](shepherd-thread://\(Self.known)") == nil, "an unclosed link is words")
    }

    @Test func thePeekSaysTheStatusAndHowLong() {
        let now = Date(timeIntervalSince1970: 100_000)
        var link = SHThreadLink(id: Self.known, title: "t", state: .running, location: "This Mac", since: now.addingTimeInterval(-18 * 60))
        #expect(link.statusLine(now: now) == "Working · 18m")
        link.state = .attention
        #expect(link.statusLine(now: now) == "Needs you · 18m")
        link.state = .done
        #expect(link.statusLine(now: now) == "Done", "a finished thread has no clock")
        #expect(SHThreadLink.elapsed(20) == "1m")
        #expect(SHThreadLink.elapsed(3_600) == "1h")
        #expect(SHThreadLink.elapsed(3_840) == "1h 4m")
        #expect(SHThreadLink.elapsed(3 * 86_400) == "3d")
        #expect(SHThreadLink(id: "a", title: "t", state: .idle, location: "x", project: "web", branch: "main").place == "web · main")
        #expect(SHThreadLink(id: "a", title: "t", state: .idle, location: "x").place == nil)
    }
}
