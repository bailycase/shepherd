import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdRemote

/// What the @ picker says under an element's title (RefAtElements): a kind noun, then what it
/// repeats counted, its place among like siblings, or its chips' words; read from the source.
@Suite("Design element summaries")
struct DesignElementSummaryTests {
    static func board(_ template: String) -> String {
        "<!doctype html>\n<html><head></head><body>\n<x-dc>\n<helmet><style>body{margin:0}</style></helmet>\n\(template)\n</x-dc>\n</body></html>\n"
    }

    /// RefAtElements' board A, as a board draws it: filters, four KPI tiles, the funnel card and
    /// the exit reasons.
    static let funnelFirst = board("""
        <div style="padding: 32px">\
        <nav data-el="bar" style="display: flex; gap: 6px">\
        <button style="background: #eef">All platforms</button><button>Web</button><button>iOS</button><button>Android</button></nav>\
        <div data-el="KPI" style="display: grid; gap: 14px">\
        <div data-el="tile" style="background: #fff"><div>Sessions with cart</div><div>48,210</div><div>vs previous 30 days</div></div>\
        <div data-el="tile" style="background: #fff"><div>Reached checkout</div><div>26.8%</div><div>12,904 people</div></div>\
        <div data-el="tile" style="background: #fff"><div>Placed order</div><div>34.0%</div><div>of checkouts</div></div>\
        <div data-el="tile" style="background: #fff"><div>Overall conversion</div><div>9.1%</div><div>cart → order</div></div></div>\
        <div data-el="card" style="background: #fff"><h3>Checkout funnel</h3>\
        <div data-el="funnel bars">\
        <div data-el="step"><span>Cart viewed</span><div style="background: #4f46e5; width: 100%"></div></div>\
        <div data-el="step"><span>Checkout started</span><div style="background: #4f46e5; width: 27%"></div></div>\
        <div data-el="step"><span>Shipping entered</span><div style="background: #4f46e5; width: 20%"></div></div>\
        <div data-el="step"><span>Payment entered</span><div style="background: #4f46e5; width: 13%"></div></div>\
        <div data-el="step"><span>Order placed</span><div style="background: #4f46e5; width: 9%"></div></div></div></div>\
        <div data-el="card" style="background: #fff"><h3>Top exit reasons</h3>\
        <ul><li>Shipping cost shown 31%</li><li>Account required 22%</li><li>Payment failed 14%</li><li>Promo code field 9%</li><li>Other 24%</li></ul></div>\
        </div>
        """)

    static let others = board("""
        <div style="display: flex"><div style="background: #eee; height: 8px"></div><div style="background: #eee; height: 8px"></div>\
        <div style="background: #eee; height: 8px"></div></div>\
        <div data-el="steps"><sc-for list="{{steps}}" as="step"><div><span>{{step.label}}</span></div></sc-for></div>\
        <table><tr><td>a</td></tr><tr><td>b</td></tr></table>\
        <section><h2>Totals</h2><p>All the numbers in one place.</p><div><span>one</span><em>two</em></div></section>\
        <div data-el="tabs"><a href="#">Overview</a><a href="#">Funnels</a><a href="#">Cohorts</a><a href="#">Events</a><a href="#">Paths</a><a href="#">Help</a></div>
        """)

    /// The summary of the `index`th element `selector` picks: a tag, or "@name" for a `data-el`.
    static func summary(_ source: String, _ selector: String, _ index: Int) throws -> String {
        let summary = try #require(DesignElementSummary(source: source))
        let template = try #require(DesignTemplate(board: source))
        let names = DesignStyleEdit.attributes("data-el", in: source)
        let picked = template.elements.filter { selector.hasPrefix("@") ? names[$0.tid] == String(selector.dropFirst()) : $0.name == selector }
        let element = try #require(picked.dropFirst(index).first)
        return summary.detail(element.tid)
    }

    @Test(arguments: [
        ("@bar", 0, "chips · All platforms, Web, iOS, Android"),
        ("@tile", 0, "KPI tile · 1 of 4"),
        ("@tile", 3, "KPI tile · 4 of 4"),
        ("@card", 0, "funnel bars · 5 steps"),
        ("@card", 1, "list · 5 rows"),
        ("ul", 0, "list · 5 rows"),
        ("@funnel bars", 0, "list · 5 steps"),
        ("@step", 0, "funnel bars step · 1 of 5"),
        ("@KPI", 0, "grid · 4 tiles"),
    ] as [(String, Int, String)])
    func anElementSaysWhatItIsAndHoldsAsTheBoardDoes(selector: String, index: Int, summary: String) throws {
        #expect(try Self.summary(Self.funnelFirst, selector, index) == summary)
    }

    @Test(arguments: [
        ("div", 0, "bars · 3 bars"),
        ("@steps", 0, "list · repeated steps"),
        ("table", 0, "table · 2 rows"),
        ("h2", 0, "heading"),
        ("p", 0, "paragraph"),
        ("section", 0, "group · 5 inside"),
        ("@tabs", 0, "chips · Overview, Funnels, Cohorts, Events, +2"),
    ] as [(String, Int, String)])
    func otherShapesSayWhatTheyAre(selector: String, index: Int, summary: String) throws {
        #expect(try Self.summary(Self.others, selector, index) == summary)
    }

    @Test(arguments: [("step", "steps"), ("box", "boxes"), ("entry", "entries"), ("day", "days"), ("funnel bar", "funnel bars")])
    func nounsTakeAnEnglishPlural(noun: String, plural: String) {
        #expect(DesignElementSummary.plural(noun) == plural)
    }

    /// The catalog carries each element's summary, and a board's element count is what the
    /// picker lists under it.
    @Test func theCatalogCarriesEachElementsSummary() throws {
        let design = Design(id: DesignID(rawValue: "d1"), name: "Checkout funnel dashboard", createdAt: 1)
        var index = DesignIndex(title: nil)
        let path = DesignPath("A.dc.html")!
        index.boards[path] = DesignIndex.Board(x: 0, y: 0, w: 1280, h: 800, title: "A · Funnel first")
        index.order = [path]
        let snapshot = DesignSnapshot(designID: design.id, revision: 7, index: index, boards: [:])
        let entries = try #require(DesignMentionCatalog.entries(design: design, snapshot: snapshot, sources: [path: Self.funnelFirst], system: nil))
        let board = try #require(entries.boards.first)
        let elements = try #require(entries.elements[board.id])
        #expect(board.elementCount == elements.count && board.revision == 7)
        #expect(elements.allSatisfy { $0.detail?.isEmpty == false && $0.revision == 7 })
        #expect(elements.contains { $0.detail == "funnel bars · 5 steps" })
    }
}
