import Foundation
import Testing
@testable import ShepherdApp

/// Capture a page on New design (DZStartPlanned): what the address field takes, and a draft
/// that refuses anything else without starting a capture.
@Suite("Page capture address")
@MainActor
struct PageCaptureAddressTests {
    @Test(arguments: [
        ("https://staging.acme.dev/checkout", "https://staging.acme.dev/checkout"),
        ("  staging.acme.dev  ", "https://staging.acme.dev"),
        ("http://localhost:3000", "http://localhost:3000"),
    ])
    func takesWebAddresses(_ typed: String, _ url: String) {
        #expect(PageCapture.address(typed)?.absoluteString == url)
    }

    @Test(arguments: ["", "file:///etc/hosts", "javascript:alert(1)", "about:blank", "acme dev", "https://"])
    func refusesTheRest(_ typed: String) {
        #expect(PageCapture.address(typed) == nil)
    }

    @Test func aDraftRefusesABadAddress() {
        let draft = NewDesignState()
        draft.capture("file:///etc/hosts")
        #expect(draft.capturing == nil)
        #expect(draft.error == "Enter a web address, like https://staging.acme.dev.")
    }

    @Test func anImageIsAttachedAsItIs() {
        let url = URL(fileURLWithPath: "/tmp/acme/shot.png")
        #expect(PageCapture.imageFile(url) == url)
    }
}
