import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp
@testable import ShepherdSessions

/// Fleet ▸ Check in light and dark (FleetCheck, and the Mac card's Ready row and Check… in FleetA): the tab with a row of the first Mac that needs
/// something picked, an agent fixing one, a Mac asleep, and everything matching. The reports are made by the host's own check (`FleetCheck.report`) from
/// checkouts on disk with real marker files, a shell that answers as each Mac would, remotes and providers that answer, and then drawn through the
/// page's own derivation. Fixture Macs and made-up names only.
@Suite("Fleet check previews", .serialized, .mainActorExclusive, .enabled(if: Preview.enabled && !Preview.liveModel, "set SHEPHERD_PREVIEW_DIR (without SHEPHERD_LIVE_MODEL)"))
@MainActor
struct FleetCheckPreviewTests {
    typealias P = FleetPagePreviewTests

    /// A checkout with these files, made under `root`.
    static func checkout(_ root: URL, _ name: String, origin: String, _ files: [String: String]) throws -> (name: String, path: String) {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (file, text) in files { try text.write(to: folder.appendingPathComponent(file), atomically: true, encoding: .utf8) }
        for arguments in [["init", "-q"], ["remote", "add", "origin", origin]] { _ = FleetDispatchGit.run(arguments, in: folder.path) }
        return (name, folder.path)
    }

    /// What one Mac's login shell says: a program's first line of `--version`, or nil when it isn't there.
    struct Shell {
        var versions: [String: String?]
        var commands: [String: Bool]
        var packageManager: String
        var sleep: Int
        var battery = false

        func answer(_ script: String) -> LoginShell.Output {
            var out = ""
            for (tool, printed) in versions { out += "@need:\(tool)\n" + (printed.map { "=\($0)\n" } ?? "#none\n") }
            for (command, there) in commands { out += "@tool:\(command)\n" + (there ? "=yes\n" : "#none\n") }
            out += "@pm\n" + (packageManager.isEmpty ? "#none\n" : "=\(packageManager)\n")
            out += "@sleep\n=\(sleep)\n@power\nNow drawing from '\(battery ? "Battery Power" : "AC Power")'\n"
            return LoginShell.Output(status: 0, stdout: out, stderr: "")
        }
    }

    static func report(_ mac: String, _ root: URL, spaces: [(String, [String: String])], shell: Shell, build: String, freeGB: UInt64,
                       providers: [FleetCheck.ProviderAnswer], remote: Bool = true) async throws -> FleetCheckReport {
        let folders = try spaces.map { try checkout(root.appendingPathComponent(mac), $0.0, origin: "git@github.com:acme/\($0.0).git", $0.1) }
        let config = root.appendingPathComponent("mcp.json")
        try #"{"mcpServers":{"muse":{"command":"muse"},"bear":{"command":"bearcli"}}}"#.write(to: config, atomically: true, encoding: .utf8)
        let sources = FleetCheck.Sources(shell: { shell.answer($0) }, remote: { _ in remote }, providers: { providers }, freeBytes: { _ in freeGB * 1_000_000_000 })
        return await FleetCheck.report(facts: FleetLocalFacts(spaces: folders, mcpConfig: config, build: build), sources: sources)
    }

    /// The board's three Macs, each looked at by the real check.
    static func snapshot(fixing: [FleetDispatchRecord] = [], matching: Bool = false) async throws -> FleetSnapshot {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let anthropic = FleetCheck.ProviderAnswer(id: "anthropic", name: "Anthropic", outcome: .works)
        let muse = FleetCheck.ProviderAnswer(id: "muse", name: "muse", outcome: matching ? .works : .cantStart("muse"))
        let web = [".nvmrc": "22\n", "package.json": #"{"packageManager":"pnpm@9.15.0"}"#, "pnpm-lock.yaml": "lockfileVersion: '9.0'\n"]
        let payments = [".nvmrc": "v22.1\n"]
        let shepherd = ["Package.swift": "// swift-tools-version: 6.2\nimport PackageDescription\n"]
        var snapshot = P.snapshot
        snapshot.macs[0].check = try await report("here", root, spaces: [("web", web), ("payments-api", payments), ("shepherd", shepherd)],
                                                  shell: Shell(versions: ["node": "v22.11.0", "pnpm": "9.15.0", "xcode": "Xcode 26.2"], commands: ["muse": true, "bearcli": true],
                                                               packageManager: "nix", sleep: 0, battery: true),
                                                  build: "675", freeGB: 312, providers: [anthropic, .init(id: "muse", name: "muse", outcome: .works)])
        snapshot.macs[0].checkAge = 180
        snapshot.macs[1].check = try await report("mini", root, spaces: [("payments-api", payments), ("shepherd", shepherd), ("orders-svc", ["flake.nix": "{}"])],
                                                  shell: Shell(versions: ["node": matching ? "v22.11.0" : "v20.18.1", "xcode": "Xcode 26.2", "nix": "nix (Nix) 2.31.2"],
                                                               commands: ["muse": matching, "bearcli": true], packageManager: "nix", sleep: 0),
                                                  build: "675", freeGB: matching ? 640 : 38, providers: [anthropic, muse])
        snapshot.macs[1].checkAge = 170
        snapshot.macs[2].check = try await report("studio", root, spaces: [("shepherd", shepherd), ("ml-eval", [".python-version": "3.12.4\n"])],
                                                  shell: Shell(versions: ["xcode": "Xcode 26.1", "python": "Python 3.12.4"], commands: ["muse": true, "bearcli": true],
                                                               packageManager: "brew", sleep: matching ? 0 : 10),
                                                  build: matching ? "675" : "671", freeGB: 1_200, providers: [anthropic])
        snapshot.macs[2].checkAge = 7_200
        snapshot.dispatches = fixing
        return snapshot
    }

    static func card(_ id: UUID, _ page: FleetPage) -> FleetMacCard { page.cards.first { $0.id == id }! }

    static func page(_ snapshot: FleetSnapshot) -> FleetPage {
        FleetPagePresentation.make(snapshot: snapshot, weight: { _ in .normal }, locale: Locale(identifier: "en_GB"))
    }

    static func tab(_ page: FleetPage, row: String? = nil, mac: UUID? = nil, problem: String? = nil) -> some View {
        FleetPageContent(page: page, actions: P.noActions, tab: .constant(.check),
                         check: FleetCheckState(row: row, mac: mac, checking: false, problem: problem), checkActions: .none)
            .frame(width: 1208, height: 900)
    }

    // MARK: The tab

    /// The real check's findings: Mac mini has node 20 where the repos pin 22, no muse CLI, a muse that can't start and little disk; Mac Studio is asleep.
    @Test func theCheckTab() async throws {
        let snapshot = try await Self.snapshot()
        let page = Self.page(snapshot)
        let rows = page.check.groups.flatMap(\.rows)
        #expect(rows.first { $0.id == "need:node:22" }?.cells.map(\.text) == ["22.11", "Has 20.18", "Not needed"])
        #expect(rows.first { $0.id == "tool:muse" }?.cells.map(\.text) == ["Installed", "Missing", "Installed"])
        #expect(rows.first { $0.id == "models" }?.cells[1].text == "muse can’t start")
        #expect(rows.first { $0.id == "disk" }?.cells.map(\.text) == ["312 GB", "38 GB", "1.2 TB"])
        #expect(page.check.count == 6 && page.check.summary == "6 things differ · 4 on Mac mini, 2 on Mac Studio")
        #expect(Self.card(P.mini, page).ready.text == "Needs 4 · node 22, muse CLI, sign-ins")
        try await Preview.renderMatrix("fleet-check-tab", size: CGSize(width: 1208, height: 900)) { Self.tab(page) }
    }

    /// The panel for a row of Mac Studio, which is asleep (its column is from its last look).
    @Test func aRowOfTheMacThatSleeps() async throws {
        let page = Self.page(try await Self.snapshot())
        let detail = page.check.detail(row: "sleep")
        #expect(detail.title == "Mac Studio sleeps after 10 minutes" && detail.command == "sudo pmset -c sleep 0")
        try await Preview.render("fleet-check-asleep", size: CGSize(width: 1208, height: 900)) { Self.tab(page, row: "sleep") }
    }

    /// An agent on Mac mini is fixing node: the cell reads Fixing…, the panel says so with Open thread, and the other rows still offer theirs.
    @Test func aFixThatRuns() async throws {
        let record = FleetDispatchRecord(kind: .userThread, parentHostID: P.here, parentHostName: "MacBook Pro", targetHostID: P.mini, targetHostName: "Mac mini",
                                         state: .running, title: "Install node 22 on Mac mini", task: "", repoKey: "github.com/acme/payments-api",
                                         fixes: ["need:node:22"], createdAt: Date().timeIntervalSince1970 * 1000)
        let page = Self.page(try await Self.snapshot(fixing: [record]))
        let node = page.check.groups.flatMap(\.rows).first { $0.id == "need:node:22" }
        #expect(node?.cells[1] == FleetCheckCell(text: "Fixing…", tone: .fixing))
        #expect(page.check.detail(row: "need:node:22").fixing?.threadTitle == "Install node 22 on Mac mini")
        try await Preview.renderMatrix("fleet-check-fixing", size: CGSize(width: 1208, height: 900)) { Self.tab(page, row: "need:node:22") }
    }

    /// A row with a command in the Mac's own package manager, then the same on Mac Studio's Homebrew; and one that has none.
    @Test func theCommandInEachMacsOwnPackageManager() async throws {
        let page = Self.page(try await Self.snapshot())
        #expect(page.check.detail(row: "tool:muse").command == "nix profile install nixpkgs#muse")
        #expect(page.check.detail(row: "models").command == nil && page.check.detail(row: "models").fixable)
        try await Preview.render("fleet-check-muse", size: CGSize(width: 1208, height: 900)) { Self.tab(page, row: "tool:muse") }
        try await Preview.render("fleet-check-models", size: CGSize(width: 1208, height: 900)) { Self.tab(page, row: "models", problem: nil) }
    }

    /// A fix that couldn't start says why in the panel.
    @Test func aFixThatCouldNotStart() async throws {
        let page = Self.page(try await Self.snapshot())
        try await Preview.render("fleet-check-problem", size: CGSize(width: 1208, height: 900)) {
            Self.tab(page, row: "need:node:22", problem: "Start a thread in a space with a git origin first: Mac mini finds the repository there.")
        }
    }

    /// Everything matches on every Mac: the tab's count goes, and the panel says so.
    @Test func everythingMatches() async throws {
        let page = Self.page(try await Self.snapshot(matching: true))
        #expect(page.check.count == 0 && page.check.tabTitle == "Check" && page.check.summary == "Everything matches on every Mac")
        try await Preview.render("fleet-check-matching", size: CGSize(width: 1208, height: 900)) { Self.tab(page, row: "need:node:22") }
    }

    // MARK: The Mac card

    /// FleetA's Mac cards: the Ready row says what Mac mini needs and Check… opens the tab; This Mac has everything; Mac Studio catches up when it wakes.
    @Test func theMacCardsReadyRowAndCheck() async throws {
        let page = Self.page(try await Self.snapshot())
        #expect(Self.card(P.mini, page).needs == 4 && Self.card(P.here, page).needs == 0)
        try await Preview.renderMatrix("fleet-check-cards", size: CGSize(width: 1208, height: 900)) {
            FleetPageContent(page: page, actions: P.noActions).frame(width: 1208, height: 900)
        }
    }

    /// The Fleet page with the tab in the window, through the real view model.
    @Test func checkInTheWindow() async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        try await workspace.seed(ShepherdState(spaces: [Space(name: "acme-web", path: workspace.dir.path)]))
        workspace.vm.fleet.onSnapshot = nil
        workspace.vm.fleetPage.update(try await Self.snapshot())
        workspace.vm.fleetPage.openCheck(for: P.mini)
        #expect(workspace.vm.fleetPage.tab == .check && workspace.vm.fleetPage.checkRow == "need:node:22")
        let model = workspace.vm.fleetPage
        try await Preview.render("fleet-check-window", size: CGSize(width: 1440, height: 900)) {
            HStack(spacing: 0) {
                SidebarView(vm: workspace.vm).frame(width: AppLayout.sidebarDefaultWidth)
                FleetPageContent(page: model.page, actions: P.noActions, tab: .constant(.check),
                                 check: FleetCheckState(row: model.checkRow, mac: model.checkMac), checkActions: .none)
            }
            .frame(width: 1440, height: 900)
        }
    }
}
