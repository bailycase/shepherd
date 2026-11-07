import Foundation
import Testing
@testable import ShepherdSessions
import ShepherdProtocol

/// Settings › Apps' `apps.json`: an older or hand-written file keeps loading, and an app runs
/// in the folder it names.
@Suite("Apps file")
struct AppsFileTests {
    @Test func aFileWithOnlyNamesAndCommandsLoadsWithDefaults() throws {
        let json = #"{"apps":[{"name":"Worker","command":"go run ./cmd/worker"},{"name":"Docs","command":"pnpm docs","opens":"hologram"}]}"#
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("apps-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let apps = try AppsFile.load(url)
        #expect(apps == [AppDefinition(name: "Worker", command: "go run ./cmd/worker"),
                         AppDefinition(name: "Docs", command: "pnpm docs")], "an unknown opening runs in a terminal")
        #expect(apps[0].folder == "" && apps[0].opens == .terminal && !apps[0].quickAction && apps[0].address == nil)
    }

    @Test func savingThenLoadingKeepsEveryField() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("apps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = AppsFile.url(in: dir.path)
        #expect(try AppsFile.load(url).isEmpty, "no file is no apps")
        let apps = [AppDefinition(name: "Web app", command: "npm run dev", folder: "web", opens: .browser,
                                  address: "http://localhost:3000", quickAction: true)]
        try AppsFile.save(apps, to: url)
        #expect(url.path.hasSuffix(".shepherd/apps.json"))
        #expect(try AppsFile.load(url) == apps)
        #expect(try String(contentsOf: url, encoding: .utf8).contains("\"address\" : \"http://localhost:3000\""))
    }

    @Test func aBrokenFileThrowsRatherThanReadingAsEmpty() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("apps-\(UUID().uuidString).json")
        try Data("{\"apps\": [".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: (any Error).self) { try AppsFile.load(url) }
    }

    @Test func aSpaceAppRunsUnderTheThreadsFolderAndAMacAppFromHome() {
        let web = AppDefinition(name: "Web", command: "npm run dev", folder: "apps/web")
        #expect(web.directory(root: "/work/payments-wt", home: "/Users/a") == "/work/payments-wt/apps/web")
        #expect(AppDefinition(name: "Root", command: "make").directory(root: "/work/p", home: "/Users/a") == "/work/p")
        #expect(AppDefinition(name: "Pg", command: "postgres").directory(root: nil, home: "/Users/a") == "/Users/a")
        #expect(AppDefinition(name: "Pg", command: "postgres", folder: "~/pg").directory(root: nil, home: "/Users/a") == "/Users/a/pg")
        #expect(AppDefinition(name: "Pg", command: "postgres", folder: "/opt/pg").directory(root: nil, home: "/Users/a") == "/opt/pg")
    }

    @Test func onlyAnHTTPAddressOpensInTheBrowser() {
        func url(_ address: String, _ opens: AppDefinition.Opens = .browser) -> URL? {
            AppDefinition(name: "a", command: "c", opens: opens, address: address).url
        }
        #expect(url("http://localhost:3000")?.port == 3000)
        #expect(url("https://staging.acme.dev") != nil)
        #expect(url("file:///etc/passwd") == nil)
        #expect(url("javascript:alert(1)") == nil)
        #expect(url("localhost:3000") == nil)
        #expect(url("http://localhost:3000", .terminal) == nil, "a terminal app opens no page")
    }
}
