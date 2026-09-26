import Foundation
import Testing
@testable import DesignSurfaceKit

/// What `shepherd-design://` serves, and the rules a board runs under.
@Suite struct DesignRouteTests {
    static let host = "d1"

    @Test(arguments: [
        ("shepherd-design://d1/project/support.js", DesignRoute.runtime),
        ("shepherd-design://d1/project/flows/support.js", .runtime),
        ("shepherd-design://D1/project/Main.dc.html", .project(["Main.dc.html"])),
        ("shepherd-design://d1/project/flows/Cart.dc.html?x=1#top", .project(["flows", "Cart.dc.html"])),
        ("shepherd-design://d1/project/ds/acme/tokens.css", .project(["ds", "acme", "tokens.css"])),
        ("shepherd-design://d1/_blob/3f2a_b-9", .blob("3f2a_b-9")),
    ])
    func aRequestInsideTheDesignIsServed(_ url: String, _ route: DesignRoute) {
        #expect(DesignRoute(url: URL(string: url), host: Self.host) == route)
    }

    @Test(arguments: [
        "shepherd-design://d2/project/Main.dc.html",
        "shepherd-design://d1:80/project/Main.dc.html",
        "shepherd-design://user@d1/project/Main.dc.html",
        "https://d1/project/Main.dc.html",
        "file:///project/Main.dc.html",
        "shepherd-design://d1/",
        "shepherd-design://d1/project",
        "shepherd-design://d1/project/",
        "shepherd-design://d1/canvas.json",
        "shepherd-design://d1/revision",
        "shepherd-design://d1/assets/abc.png",
        "shepherd-design://d1/project/.hidden",
        "shepherd-design://d1/project/a%2F..%2F..%2Fsecret",
        "shepherd-design://d1/project/..%5Csecret",
        "shepherd-design://d1/project/sub//Main.dc.html",
        "shepherd-design://d1/project/Main%20Board.dc.html",
        "shepherd-design://d1/_blob/",
        "shepherd-design://d1/_blob/a.png",
        "shepherd-design://d1/_blob/a/b",
    ])
    func anythingElseIsRefused(_ url: String) {
        #expect(DesignRoute(url: URL(string: url), host: Self.host) == .refused)
    }

    /// A link on a board, as WebKit resolves it against the board's URL.
    @Test(arguments: [
        ("shepherd-design://d1/project/Cart.dc.html", "Cart.dc.html"),
        ("shepherd-design://d1/project/flows/Cart.dc.html#top", "flows/Cart.dc.html"),
        // A leading `/` is the canvas root.
        ("shepherd-design://d1/Cart.dc.html", "Cart.dc.html"),
        ("shepherd-design://d1/flows/Cart.dc.html", "flows/Cart.dc.html"),
    ])
    func aLinkNamesAFileOfTheProject(_ url: String, _ path: String) {
        #expect(DesignRoute.linkedPath(URL(string: url)!, host: Self.host) == path)
    }

    @Test(arguments: [
        "shepherd-design://d2/Cart.dc.html",
        "shepherd-design://d1/",
        "shepherd-design://d1/..%2FCart.dc.html",
        "https://d1/Cart.dc.html",
    ])
    func aLinkOutsideTheProjectNamesNoFile(_ url: String) {
        #expect(DesignRoute.linkedPath(URL(string: url)!, host: Self.host) == nil)
    }

    @Test func theContentSecurityPolicyAllowsOnlyTheDesign() {
        let offline = DesignSandbox.contentSecurityPolicy(network: .none)
        let fonts = DesignSandbox.contentSecurityPolicy(network: .googleFonts)
        #expect(!offline.contains("https:") && !offline.contains("data:"))
        #expect(fonts.contains("style-src 'self' 'unsafe-inline' https://fonts.googleapis.com"))
        #expect(fonts.contains("font-src 'self' https://fonts.gstatic.com"))
        for policy in [offline, fonts] {
            let script = policy.split(separator: ";").first { $0.contains("script-src") }
            #expect(script?.contains("unsafe-inline") == false)
            #expect(policy.hasPrefix("default-src 'none'") && policy.contains("frame-src 'none'") && policy.contains("form-action 'none'"))
        }
    }

    @Test func theContentRulesBlockEverythingBeforeTheyAllowTheDesign() throws {
        for network in [DesignSandbox.Network.none, .googleFonts] {
            let rules = try #require(try JSONSerialization.jsonObject(with: Data(DesignSandbox.contentRules(network: network).utf8)) as? [[String: [String: String]]])
            #expect(rules.first?["trigger"]?["url-filter"] == ".*" && rules.first?["action"]?["type"] == "block")
            let allowed = rules.dropFirst().compactMap { $0["trigger"]?["url-filter"] }
            #expect(rules.dropFirst().allSatisfy { $0["action"]?["type"] == "ignore-previous-rules" })
            #expect(allowed.contains("^shepherd-design://"))
            #expect(allowed.count == (network == .googleFonts ? 3 : 1))
        }
    }

    @Test(arguments: [("html", "text/html; charset=utf-8"), ("HTML", "text/html; charset=utf-8"), ("js", "text/javascript; charset=utf-8"),
                      ("woff2", "font/woff2"), ("svg", "image/svg+xml"), ("exe", "application/octet-stream")])
    func servedFilesGoOutAsTheirType(_ ext: String, _ type: String) {
        #expect(DesignSandbox.contentType(forExtension: ext) == type)
    }
}
