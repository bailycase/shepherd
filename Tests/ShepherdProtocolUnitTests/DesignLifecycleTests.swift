import Foundation
import Testing
import ShepherdCore
@testable import ShepherdProtocol

/// The names Shepherd gives designs it makes from others: never a merge, never a name taken.
@Suite("Design naming")
struct DesignNamingTests {
    @Test(arguments: [
        ("Checkout funnel", [String](), "Checkout funnel"),
        ("Checkout funnel", ["Checkout funnel"], "Checkout funnel 2"),
        ("Checkout funnel", ["checkout FUNNEL", "Checkout funnel 2"], "Checkout funnel 3"),
        ("Checkout funnel", ["Checkout funnel 2"], "Checkout funnel"),
        ("  Onboarding ", ["Onboarding"], "Onboarding 2"),
    ])
    func aProjectImportedAgainTakesTheNextFreeNumber(_ name: String, _ taken: [String], _ expected: String) {
        #expect(DesignNaming.importName(name, taken: taken) == expected)
    }

    @Test(arguments: [
        ("Checkout funnel", ["Checkout funnel"], "Checkout funnel copy"),
        ("Checkout funnel", ["Checkout funnel", "Checkout funnel copy"], "Checkout funnel copy 2"),
        ("Checkout funnel", ["Checkout funnel copy", "checkout funnel copy 2"], "Checkout funnel copy 3"),
    ])
    func aDuplicateIsACopyNoDesignIsNamed(_ name: String, _ taken: [String], _ expected: String) {
        #expect(DesignNaming.duplicateName(name, taken: taken) == expected)
    }

    @Test func aDeletionRoundTripsAndItsWindowIsTenSeconds() throws {
        let deletion = DesignDeletion(designID: DesignID(rawValue: "d1"), name: "Checkout", undoUntil: 1_700_000_010_000)
        #expect(try JSONDecoder().decode(DesignDeletion.self, from: JSONEncoder().encode(deletion)) == deletion)
        #expect(DesignDeletion.undoWindow == 10)
    }
}
