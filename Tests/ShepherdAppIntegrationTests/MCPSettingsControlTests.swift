import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// Settings ▸ MCP servers, pressed the way VoiceOver presses (`ControlPress`): every control the
/// page and its sheets draw, in the states they appear in, runs what it should. Each scenario
/// runs in its own process (SwiftUI draws the accessibility tree only for an attached client).
///
/// A control's effect is read where it lands: the file the user owns, the pi subcommands the page
/// ran, the pasteboard, the setting. Pressing "Edit…" or "Remove" opens a sheet, which is a window
/// of its own that the page's tree doesn't hold, so those are pressed and the entry is shown
/// untouched; what the sheets do is pressed from the sheets themselves below.
@Suite("MCP settings controls", .integrationTimeLimit)
struct MCPSettingsControlTests {
    @Test func theRowAndDetailControlsDoWhatTheyDraw() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.pressingTheServersPage() }
        }
    }

    @Test func aFileThatDoesNotParseTurnsEditingOffAndTheOtherControlsStay() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.pressingWithAnInvalidFile() }
        }
    }

    @Test func theSignInSheetCopiesOpensCancelsAndTriesAgain() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.pressingTheSignInSheet() }
        }
    }

    @Test func theAddSheetSavesTheServerAndStartsItsSignIn() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.pressingTheAddSheet() }
        }
    }

    // MARK: Fixtures

    /// pi's `mcp` subcommands, scripted: `list --json` answers `list`, `login` streams its address
    /// and, with `blocksLogin`, waits to be cancelled as pi waits for a browser.
    final class RecordingCLI: MCPCLI, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [[String]] = []
        var list = ""
        var blocksLogin = false
        var loginStatus: Int32 = 0

        var calls: [[String]] { lock.withLock { recorded } }
        /// How many times the page asked pi for the servers' state.
        var lists: Int { calls.filter { $0.first == "list" }.count }

        func run(_ arguments: [String], environment: [String: String], timeout: TimeInterval,
                 onLine: (@Sendable (String) -> Void)?) async -> MCPCLIResult {
            lock.withLock { recorded.append(arguments) }
            switch arguments.first {
            case "list":
                return MCPCLIResult(status: 0, stdout: list, stderr: "")
            case "login":
                onLine?("https://mcp.example.com/authorize?server=\(arguments.dropFirst().first ?? "")")
                if blocksLogin {
                    while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
                    return MCPCLIResult(status: 143, stdout: "", stderr: "")
                }
                return MCPCLIResult(status: loginStatus, stdout: "", stderr: loginStatus == 0 ? "" : "Sign-in to MCP server \"x\" failed: boom")
            default:
                return MCPCLIResult(status: 0, stdout: "", stderr: "")
            }
        }
    }

    static func listJSON(_ servers: [(String, String, [String])]) -> String {
        let items = servers.map { ["name": $0.0, "state": $0.1, "tools": $0.2, "enabled": true, "exposure": "deferred", "transport": "x", "scope": "global"] as [String: Any] }
        return String(decoding: (try? JSONSerialization.data(withJSONObject: ["servers": items, "errors": [String]()])) ?? Data(), as: UTF8.self)
    }

    final class Pasteboard: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        private var opened: [URL] = []
        var copied: [String] { lock.withLock { items } }
        var urls: [URL] { lock.withLock { opened } }
        func copy(_ text: String) { lock.withLock { items.append(text) } }
        func open(_ url: URL) { lock.withLock { opened.append(url) } }
    }

    @MainActor
    static func store(config: String, cli: RecordingCLI, pasteboard: Pasteboard, secrets: InMemorySecretStore = InMemorySecretStore(),
                      auth: Data? = nil) throws -> MCPStore {
        let directory = try makeScratchDirectory()
        let file = directory.appendingPathComponent("mcp.json")
        try Data(config.utf8).write(to: file)
        return MCPStore(dependencies: .init(
            file: MCPConfigFile(url: file), secrets: secrets, http: URLSessionHTTP(), cli: cli, preparePi: { nil }, authData: { auth },
            openURL: { pasteboard.open($0) }, copy: { pasteboard.copy($0) }, now: { Date() }))
    }

    @MainActor
    static func labelStarting(_ prefix: String, in window: OffscreenWindow) throws -> String {
        try #require(window.controls().compactMap(\.label).first { $0.hasPrefix(prefix) }, "no control starts \"\(prefix)\"")
    }

    static let config = """
    { "mcpServers": {
      "linear": { "type": "http", "url": "https://mcp.linear.app/mcp" },
      "sentry": { "type": "http", "url": "https://mcp.sentry.dev/mcp" },
      "notion": { "type": "http", "url": "https://mcp.notion.com/mcp" },
      "postgres": { "command": "uvx", "args": ["postgres-mcp"] }
    }}
    """

    @MainActor
    static func fileSettings(_ store: MCPStore, _ name: String) throws -> MCPShepherdSettings {
        guard case .document(let document) = store.dependencies.file.read() else { throw Failure("unreadable") }
        return try #require(document.server(name)).settings
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    // MARK: Scenarios

    @MainActor
    static func pressingTheServersPage() async throws {
        AccessibilityNode.enable()
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await app.start()
        let cli = RecordingCLI()
        cli.list = listJSON([("linear", "connected", ["a", "b", "c"]), ("sentry", "needs-auth", []), ("notion", "needs-auth", []), ("postgres", "connected", ["q"])])
        let pasteboard = Pasteboard()
        let auth = Data(#"{"mcp__linear|https://mcp.linear.app/mcp": {}}"#.utf8)
        let store = try store(config: config, cli: cli, pasteboard: pasteboard, auth: auth)
        store.refresh()
        await store.settle()
        let settings = AppSettings.shared
        let window = OffscreenWindow(size: CGSize(width: 1200, height: 1000), dark: true, MCPSettings(vm: vm, store: store, initiallyExpanded: "linear"))
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(300))

        // Tool exposure: Direct and back to Search, each reaching the user's file.
        let search = try labelStarting("Search, ", in: window), direct = try labelStarting("Direct, ", in: window)
        #expect(window.element(search)?.isSelected == true && window.element(direct)?.isSelected == false)
        try window.press(direct)
        try await eventuallyOnMain("Direct to reach the file") { (try? fileSettings(store, "linear").exposure) == .direct }
        #expect(store.details["linear"]?.direct == true)
        #expect(window.element(try labelStarting("Direct, ", in: window))?.isSelected == true)
        try window.press(try labelStarting("Search, ", in: window))
        try await eventuallyOnMain("Search to reach the file") { (try? fileSettings(store, "linear").exposure) == .proxy }
        #expect(try Self.fileSettings(store, "linear").tools == nil, "no tools are chosen by it")
        #expect(cli.calls.map { $0.first } == ["list"], "choosing an exposure asks pi nothing: it takes effect at the next launch")
        // Each choice is as big as a pointer needs, whatever its label's size.
        let options = window.controls().filter { ($0.label ?? "").hasPrefix("Search, ") || ($0.label ?? "").hasPrefix("Direct, ") }
        #expect(options.count == 2)
        #expect(ControlPress.undersized(options, minimum: .desktop).isEmpty, "\(ControlPress.undersized(options, minimum: .desktop))")

        // The detail's other controls.
        try window.press("Choose which tools…")
        try window.press("Edit…")
        try window.press("Remove")
        #expect(store.entry("linear") != nil, "Remove asks first")
        try window.press("Copy JSON")
        let copied = try #require(pasteboard.copied.last)
        #expect(copied.contains("https://mcp.linear.app/mcp") && !copied.contains("shepherd"), "the entry as other tools read it")
        try window.press("Reconnect")
        try await eventuallyOnMain("Reconnect to ask pi again") { cli.lists >= 2 }
        await store.settle()
        #expect(cli.lists == 2, "Reconnect asks pi once")

        // Sign-in: out of linear, and into the first server that needs it.
        try window.press("Sign out")
        try await eventuallyOnMain("Sign out to run pi's logout and ask again") { cli.calls.contains(["logout", "linear"]) && cli.lists >= 3 }
        await store.settle()
        #expect(cli.lists == 3, "Sign out asks pi once more, after its logout")
        try window.press("Sign in", nth: 0)
        try await eventuallyOnMain("the sign-in to start") { store.signIn?.server == "sentry" }
        try await eventuallyOnMain("pi's login to run") { cli.calls.contains(["login", "sentry", "--timeout", "300"]) }
        // A sign-in that succeeds asks pi again, and closing the sheet before it does would cancel that: so let it finish and
        // settle before counting, or the count below depends on how fast this machine is.
        try await eventuallyOnMain("the sign-in to finish") { store.signIn?.succeeded == true }
        await store.settle()
        store.closeSignIn()
        #expect(cli.lists == 4, "the sign-in asked pi once more")

        // The row's switch, off and on, which asks pi again only when it comes on.
        let before = cli.lists
        try window.press("sentry", role: ControlRole.checkBox)
        try await eventuallyOnMain("the switch to reach the file") { (try? fileSettings(store, "sentry").enabled) == false }
        #expect(store.rows.first { $0.name == "sentry" }?.status == .off)
        #expect(cli.lists == before)
        try window.press("sentry", role: ControlRole.checkBox)
        try await eventuallyOnMain("the switch to come back") { (try? fileSettings(store, "sentry").enabled) == true }
        try await eventuallyOnMain("pi to be asked") { cli.lists >= before + 1 }
        await store.settle()
        #expect(cli.lists == before + 1, "switching a server on asks pi once")

        // The rail's switches.
        let repo = settings.mcpProjectConfig
        try window.press("Also use a repo’s .mcp.json", role: ControlRole.checkBox)
        try await eventuallyOnMain("the setting to follow") { settings.mcpProjectConfig == !repo }
        try window.press("Also use a repo’s .mcp.json", role: ControlRole.checkBox)
        try await eventuallyOnMain("the setting to go back") { settings.mcpProjectConfig == repo }
        let same = settings.mcpSameEverywhere
        try window.press("Same servers on every host", role: ControlRole.checkBox)
        try await eventuallyOnMain("the setting to follow") { settings.mcpSameEverywhere == !same }
        try window.press("Same servers on every host", role: ControlRole.checkBox)

        // Toolbar: Add server opens its sheet (a window of its own), and a filter narrows the list.
        try window.press("Add server")
        try window.press("Needs you 2", role: ControlRole.radioButton)
        try await eventuallyOnMain("the filter to narrow the rows") { store.rows(filter: .needsYou, query: "").count == 2 }
    }

    @MainActor
    static func pressingWithAnInvalidFile() async throws {
        AccessibilityNode.enable()
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await app.start()
        let cli = RecordingCLI()
        let store = try store(config: "{ nope", cli: cli, pasteboard: Pasteboard())
        let window = OffscreenWindow(size: CGSize(width: 1200, height: 800), dark: true, MCPSettings(vm: vm, store: store))
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(300))
        func refusal(_ body: () throws -> Void) -> ControlPressError? {
            do { try body() } catch let error as ControlPressError { return error } catch {}
            return nil
        }
        let add = try #require(refusal { try window.press("Add server") }, "Add server takes no press while the file doesn't parse")
        #expect(add.reason == .disabled, "\(add)")
        // Open mcp.json would hand the file to another app; it is drawn, enabled and big enough.
        let open = try #require(window.controls().first { $0.label == "Open mcp.json" }, "the page offers the file")
        #expect(open.isEnabled)
        #expect(store.invalidMessage == "mcp.json isn’t valid JSON (line 1)")
        #expect(try String(contentsOf: store.dependencies.file.url, encoding: .utf8) == "{ nope", "nothing was written over it")
    }

    @MainActor
    static func pressingTheSignInSheet() async throws {
        AccessibilityNode.enable()
        let cli = RecordingCLI()
        cli.blocksLogin = true
        let pasteboard = Pasteboard()
        let store = try store(config: config, cli: cli, pasteboard: pasteboard)
        store.beginSignIn("notion")
        let flow = try #require(store.signIn)
        try await eventuallyOnMain("pi to print its address") { flow.authorizationURL != nil }
        var closed = 0
        let window = OffscreenWindow(size: CGSize(width: NWMCPMetrics.sheetWidth, height: 380), dark: true,
                                     MCPSignInSheetHost(flow: flow) { closed += 1; store.closeSignIn() })
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(300))
        try window.press("Copy link")
        #expect(pasteboard.copied == ["https://mcp.example.com/authorize?server=notion"])
        try window.press("Open browser again")
        #expect(pasteboard.urls.map(\.absoluteString) == ["https://mcp.example.com/authorize?server=notion"])
        try window.press("Cancel")
        #expect(closed == 1 && store.signIn == nil, "Cancel closes the sheet and ends pi's login")

        // Failed: Try again runs pi's login again; Details and Close stay available.
        cli.blocksLogin = false
        cli.loginStatus = 1
        store.beginSignIn("notion")
        let failing = try #require(store.signIn)
        try await eventuallyOnMain("the sign-in to fail") { failing.model.phase == .failed }
        let failed = OffscreenWindow(size: CGSize(width: NWMCPMetrics.sheetWidth, height: 420), dark: true,
                                     MCPSignInSheetHost(flow: failing) { closed += 1 })
        defer { failed.close() }
        try await Task.sleep(for: .milliseconds(300))
        let logins = { cli.calls.filter { $0.first == "login" }.count }
        let before = logins()
        try failed.press("Try again")
        try await eventuallyOnMain("pi's login to run again") { logins() == before + 1 }
        try failed.press("Details")
        try failed.press("Close")
        #expect(closed == 2)

        // Done: the sheet closes itself, and Done closes it too.
        cli.loginStatus = 0
        store.beginSignIn("notion")
        let done = try #require(store.signIn)
        try await eventuallyOnMain("the sign-in to finish") { done.succeeded }
        let finished = OffscreenWindow(size: CGSize(width: NWMCPMetrics.sheetWidth, height: 380), dark: true,
                                       MCPSignInSheetHost(flow: done) { closed += 1 })
        defer { finished.close() }
        try await Task.sleep(for: .milliseconds(300))
        try finished.press("Done")
        #expect(closed == 3)
    }

    @MainActor
    static func pressingTheAddSheet() async throws {
        AccessibilityNode.enable()
        let cli = RecordingCLI()
        cli.blocksLogin = true
        let store = try store(config: "{}", cli: cli, pasteboard: Pasteboard())
        var closed = 0
        // A pasted URL that answered and wants OAuth, as the sheet's check leaves it.
        let draft = AddMCPServerSheet.Draft(name: "notion", url: "https://mcp.notion.com/mcp", check: .oauth(name: "Notion MCP", provider: "Notion", registers: true))
        let window = OffscreenWindow(size: CGSize(width: 720, height: 700), dark: true,
                                     AddMCPServerSheet(store: store, initialKind: .remote, editing: nil, draft: draft) { closed += 1 })
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(400))
        // The kinds and sign-in choices are segments; Header shows its fields.
        try window.press("Header", role: ControlRole.radioButton)
        #expect(window.controls().compactMap(\.label).contains { $0.hasPrefix("Add") })
        try window.press("OAuth · found", role: ControlRole.radioButton)
        try window.press("Advanced: client ID, scopes, extra headers, timeout", role: "AXDisclosureTriangle")
        try window.press("Close")
        try window.press("Cancel")
        #expect(closed == 2 && store.entry("notion") == nil, "Close and Cancel save nothing")

        try window.press("Add and sign in")
        try await eventuallyOnMain("the server to be saved") { store.entry("notion")?.url == "https://mcp.notion.com/mcp" }
        #expect(closed == 3)
        try await eventuallyOnMain("pi's login to start for it") { cli.calls.contains(["login", "notion", "--timeout", "300"]) }
        #expect(store.signIn?.server == "notion")
        let text = try String(contentsOf: store.dependencies.file.url, encoding: .utf8)
        #expect(text.contains("\"notion\"") && !text.contains("start"), "the entry carries nothing of the old start modes")
        store.closeSignIn()

        // Local and Paste JSON: the primary button follows what is typed (JSON is empty here).
        try window.press("Local", role: ControlRole.radioButton)
        try window.press("Paste JSON", role: ControlRole.radioButton)
        let add = try #require(window.controls().first { $0.label == "Add" })
        #expect(!add.isEnabled, "Add takes no press until the JSON holds servers")
    }
}
