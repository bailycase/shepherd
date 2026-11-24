import Foundation
import Testing
@testable import ShepherdSessions

/// A saved account's title and email. Usage itself is read by provider extensions
/// (`Tests/Extensions/shepherd-usage.test.mjs`, and `PiAuthStoreUsageTests` for saving it).
@Suite("Saved account titles")
struct PiAccountTitleTests {
    @Test func accountsShowTheirEmailInPlaceOfAnAutomaticName() {
        let claims = Data(#"{"https://api.openai.com/profile":{"email":"me@example.com"}}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        #expect(PiAccounts.tokenEmail(["access": "h.\(claims).s"]) == "me@example.com")
        #expect(PiAccounts.tokenEmail(["access": "sk-ant-oat-opaque"]) == nil)

        let automatic = PiAccount(id: "1", name: "Account 2", email: "a@b.co")
        #expect(automatic.title == "a@b.co" && automatic.detail == nil)
        let named = PiAccount(id: "2", name: "Work", email: "a@b.co")
        #expect(named.title == "Work" && named.detail == "a@b.co")
        #expect(PiAccount(id: "3", name: "Account 1").title == "Account 1")
    }
}
