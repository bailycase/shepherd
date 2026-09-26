import Foundation
import Testing
import ShepherdProtocol

/// The board path grammar: only a path that passes it names a file in a design's folder.
@Suite("Design paths")
struct DesignPathTests {
    @Test(arguments: [
        "Main.dc.html", "A_1.dc.html", "_draft.dc.html", "flows/Cart.dc.html", "a/b-c/D.e.dc.html",
        "9.dc.html", "Dashboard-v2.dc.html",
    ])
    func aPathInsideTheGrammarIsABoard(_ raw: String) throws {
        let path = try DesignPath.validate(raw)
        #expect(path.rawValue == raw)
    }

    @Test(arguments: [
        ("", DesignPath.Problem.empty),
        ("Main.html", .notABoard),
        (".dc.html", .notABoard),
        ("/Main.dc.html", .absolute),
        ("flows\\Cart.dc.html", .backslash),
        ("../Main.dc.html", .parentReference),
        ("a/../Main.dc.html", .parentReference),
        ("A..B.dc.html", .parentReference),
        ("a//Main.dc.html", .badSegment("")),
        ("-Main.dc.html", .badSegment("-Main.dc.html")),
        (".hidden/Main.dc.html", .badSegment(".hidden")),
        ("My Board.dc.html", .badSegment("My Board.dc.html")),
        ("Café.dc.html", .badSegment("Café.dc.html")),
        ("ds/acme/Card.dc.html", .reservedFolder),
        (String(repeating: "a", count: 193) + ".dc.html", .tooLong),
    ])
    func aPathOutsideTheGrammarIsRefused(_ raw: String, _ problem: DesignPath.Problem) {
        #expect(throws: problem) { try DesignPath.validate(raw) }
        #expect(DesignPath(raw) == nil)
    }

    @Test(arguments: [
        ("Main.dc.html", "Main", "Main.dc.html"),
        ("flows/Cart.dc.html", "Cart", "flows%2FCart.dc.html"),
        ("Checkout-v2.dc.html", "Checkout-v2", "Checkout-v2.dc.html"),
    ])
    func aPathHasAStemAndAViewName(_ raw: String, _ stem: String, _ viewName: String) throws {
        let path = try DesignPath.validate(raw)
        #expect(path.stem == stem)
        #expect(path.viewName == viewName)
    }

    @Test(arguments: [("acme-web", true), ("a", true), ("night_watch2", true), ("Acme", false), ("-acme", false),
                      ("_acme", false), ("", false), ("a.b", false), (String(repeating: "a", count: 65), false)])
    func aSystemFolderNameIsLowerCaseWords(_ name: String, _ valid: Bool) {
        #expect(DesignPath.isSystemNamespace(name) == valid)
    }

    @Test(arguments: [("page-1", true), ("design", true), ("A_b", true), ("", false), ("a b", false),
                      ("x.y", false), (String(repeating: "p", count: 41), false)])
    func aPageOrNoteIDIsAShortWord(_ id: String, _ valid: Bool) {
        #expect(DesignPath.isIndexID(id) == valid)
    }

    @Test func aPathDecodesOnlyInsideTheGrammar() throws {
        let decoded = try JSONDecoder().decode([DesignPath].self, from: Data(#"["Main.dc.html"]"#.utf8))
        #expect(decoded.map(\.rawValue) == ["Main.dc.html"])
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([DesignPath].self, from: Data(#"["../x.dc.html"]"#.utf8))
        }
    }
}
