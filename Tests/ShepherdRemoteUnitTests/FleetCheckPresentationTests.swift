import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdRemote

/// Fleet ▸ Check as the Mac and the phone draw it: the grid of what the fleet needs against each Mac, its counts and words, the panel's
/// command in each Mac's own package manager, the checklist an agent is given, and what Ignore and a running fix do to it.
@Suite("Fleet check presentation")
struct FleetCheckPresentationTests {
    typealias P = FleetPagePresentationTests
    static let here = P.here, mini = P.mini, studio = P.studio

    static func item(_ id: String, _ group: FleetCheckItem.Group, _ name: String, _ state: FleetCheckItem.State, _ value: String, kind: FleetCheckItem.Kind = .other,
                     why: String = "", tool: String? = nil, want: String? = nil, atLeast: Bool = false, subjects: [String] = [], sources: [String] = []) -> FleetCheckItem {
        FleetCheckItem(id: id, group: group, name: name, why: why, state: state, value: value, kind: kind, tool: tool, want: want, atLeast: atLeast, subjects: subjects, sources: sources)
    }

    static func node(_ state: FleetCheckItem.State, _ value: String, repos: [String]) -> FleetCheckItem {
        item("need:node:22", .needs, "node 22", state, value, kind: .tool, tool: "node", want: "22", subjects: repos, sources: [".nvmrc"])
    }

    /// The board's three Macs: This Mac has everything; Mac mini has node 20, no muse CLI, a muse that can't start and 38 GB free; Mac Studio (asleep) runs an
    /// older build and sleeps after 10 minutes.
    static func snapshot(ignoring: Bool = false) -> FleetSnapshot {
        var snapshot = P.snapshot()
        func report(_ items: [FleetCheckItem], pm: String) -> FleetCheckReport { FleetCheckReport(items: items, packageManager: pm) }
        let build: (String) -> FleetCheckItem = { item("build", .system, "Shepherd", .ok, "Build \($0)", kind: .build, why: "Same build on every Mac") }
        let disk: (FleetCheckItem.State, String) -> FleetCheckItem = { item("disk", .system, "Free disk", $0, $1, kind: .disk, why: "Worktrees and clones need room") }
        let sleep: (FleetCheckItem.State, String) -> FleetCheckItem = { item("sleep", .system, "Stays awake", $0, $1, kind: .sleep, why: "Auto skips a Mac while it sleeps") }
        let muse: (FleetCheckItem.State, String) -> FleetCheckItem = { item("tool:muse", .tools, "muse", $0, $1, kind: .command, tool: "muse", subjects: ["muse"]) }
        let models: (FleetCheckItem.State, String) -> FleetCheckItem = {
            item("models", .access, "Model sign-ins", $0, $1, kind: .provider, why: "Anthropic, muse", subjects: $0 == .warn ? ["muse"] : [])
        }
        snapshot.macs[0].check = report([node(.ok, "22.11", repos: ["web", "payments-api"]), muse(.ok, "Installed"), models(.ok, "All answer"), build("675"), disk(.ok, "312 GB"), sleep(.ok, "On battery")], pm: "nix")
        snapshot.macs[0].checkAge = 180
        snapshot.macs[1].check = report([node(.warn, "Has 20.18", repos: ["payments-api"]), muse(.warn, "Missing"), models(.warn, "muse can’t start"), build("675"),
                                         disk(.warn, "38 GB"), sleep(.ok, "Never sleeps"),
                                         item("need:nix:", .needs, "nix", .ok, "2.31", kind: .tool, tool: "nix", subjects: ["orders-svc"], sources: ["flake.nix"])], pm: "nix")
        snapshot.macs[1].checkAge = 170
        snapshot.macs[2].check = report([muse(.ok, "Installed"), build("671"), sleep(.warn, "Sleeps after 10 min")], pm: "brew")
        snapshot.macs[2].checkAge = 7_200
        return snapshot
    }

    static func page(_ snapshot: FleetSnapshot = snapshot(), ignored: [UUID: Set<String>] = [:], fixing: [UUID: [String: FleetCheckFixing]] = [:]) -> FleetPage {
        FleetPagePresentation.make(snapshot: snapshot, weight: { _ in .normal }, checkIgnored: { ignored[$0] ?? [] }, checkFixing: fixing, locale: P.en, calendar: P.utc)
    }

    // MARK: The grid

    @Test func theGridHasAColumnPerMacAndRowsInTheBoardsGroupsAndOrder() {
        let check = Self.page().check
        #expect(check.columns.map(\.name) == ["This Mac", "Mac mini", "Mac Studio"])
        #expect(check.groups.map(\.name) == ["Your repos need", "Tools and MCP servers", "Access", "Shepherd and the Mac"])
        #expect(check.groups.map { $0.rows.map(\.id) } == [["need:node:22", "need:nix:"], ["tool:muse"], ["models"], ["build", "disk", "sleep"]])
        #expect(check.groups.flatMap(\.rows).allSatisfy { $0.cells.count == 3 })
    }

    @Test func aRowSaysWhoAsksForItAcrossMacs() {
        let rows = Self.page().check.groups.flatMap(\.rows)
        // This Mac holds web and payments-api, Mac mini payments-api alone: the row is of both.
        #expect(rows.first { $0.id == "need:node:22" }?.why == ".nvmrc in payments-api, web")
        #expect(rows.first { $0.id == "tool:muse" }?.name == "muse CLI" && rows.first { $0.id == "tool:muse" }?.why == "muse MCP server")
    }

    @Test func eachCellSaysWhatThatMacHasInTheTonesOfTheBoard() {
        let rows = Dictionary(uniqueKeysWithValues: Self.page().check.groups.flatMap(\.rows).map { ($0.id, $0.cells) })
        #expect(rows["need:node:22"]?.map(\.text) == ["22.11", "Has 20.18", "Not needed"])
        #expect(rows["need:node:22"]?.map(\.tone) == [.ok, .warn, .none])
        #expect(rows["tool:muse"]?.map(\.text) == ["Installed", "Missing", "Installed"])
        // A Mac that is asleep is drawn from its last report, in the quiet tone, whatever it said.
        #expect(rows["tool:muse"]?.map(\.tone) == [.ok, .warn, .old])
        #expect(rows["need:nix:"]?.map(\.text) == ["Not needed", "2.31", "Not needed"])
    }

    @Test func aMacOnAnOlderBuildThanTheFleetsNewestDiffers() {
        let page = Self.page()
        let build = page.check.groups.flatMap(\.rows).first { $0.id == "build" }
        #expect(build?.cells.map(\.text) == ["Build 675", "Build 675", "Build 671"])
        // The asleep Mac's cell is quiet, but its row still needs something there.
        #expect(build?.attention == [Self.studio])
        #expect(page.check.detail(row: "build").pill == "Behind on Mac Studio")
    }

    @Test func aMacWithNoReportSaysSoInsteadOfNotNeeded() {
        var snapshot = Self.snapshot()
        snapshot.macs[2].check = nil
        let cells = Self.page(snapshot).check.groups.flatMap(\.rows).first { $0.id == "tool:muse" }?.cells
        #expect(cells?[2].text == "Not checked yet" && cells?[2].tone == FleetCheckTone.none)
    }

    // MARK: Words and counts

    @Test func theCountAndSummaryNameWhereThingsDiffer() {
        let check = Self.page().check
        // Mac mini: node, muse CLI, models, disk. Mac Studio: build, sleep.
        #expect(check.count == 6)
        #expect(check.summary == "6 things differ · 4 on Mac mini, 2 on Mac Studio")
        #expect(check.tabTitle == "Check · 6")
        #expect(check.checkedAgo == "Checked 2m ago", "the newest look at a Mac that is awake: \(check.checkedAgo ?? "nil")")
        #expect(check.footer == "Checks only read. Nothing is installed or changed until you pick a fix. Mac Studio is asleep, so its column is from 22:42.")
    }

    @Test func whenEverythingMatchesTheTabSaysSo() {
        var snapshot = Self.snapshot()
        snapshot.macs[1].check = FleetCheckReport(items: [Self.node(.ok, "22.4", repos: ["payments-api"])])
        snapshot.macs[2].check = FleetCheckReport(items: [])
        snapshot.macs[0].check = FleetCheckReport(items: [Self.node(.ok, "22.11", repos: ["web"])])
        let check = Self.page(snapshot).check
        #expect(check.count == 0 && check.tabTitle == "Check" && check.summary == "Everything matches on every Mac")
    }

    @Test func theMacCardSaysWhatItNeedsAndOffersCheck() {
        let page = Self.page()
        let mini = P.card(Self.mini, page), here = P.card(Self.here, page), studio = P.card(Self.studio, page)
        #expect(mini.ready.text == "Needs 4 · node 22, muse CLI, sign-ins" && mini.ready.tone == .warn && mini.needs == 4)
        #expect(here.ready.text == "Every model and tool" && here.needs == 0)
        // An asleep Mac catches up when it wakes, whatever its last report said.
        #expect(studio.ready.text == "Catches up when it wakes" && studio.needs == 0)
        #expect(page.check.firstRow(needing: Self.mini) == "need:node:22")
    }

    @Test func aMacThatHasNotReportedKeepsTheReadinessWords() {
        var snapshot = Self.snapshot()
        snapshot.macs[1].check = nil
        let mini = P.card(Self.mini, Self.page(snapshot))
        #expect(mini.ready.text == "muse CLI isn’t installed" && mini.needs == 0)
    }

    @Test func gitOrXcodeMissingStillLeadsTheCardsNeeds() {
        var snapshot = Self.snapshot()
        snapshot.macs[1].readiness?.missing = [FleetMissingTool(kind: .git)]
        #expect(P.card(Self.mini, Self.page(snapshot)).ready.text == "Needs 5 · git, node 22, muse CLI")
    }

    // MARK: Ignore and fixing

    @Test func whatWasSetAsideForAMacNoLongerCountsOrNeedsAnything() {
        let page = Self.page(ignored: [Self.mini: ["disk", "models"]])
        #expect(page.check.count == 4 && page.check.summary == "4 things differ · 2 on Mac mini, 2 on Mac Studio")
        let disk = page.check.groups.flatMap(\.rows).first { $0.id == "disk" }
        // The cell keeps what the Mac said, in the quiet tone, and the panel offers to stop setting it aside.
        #expect(disk?.cells[1].text == "38 GB" && disk?.cells[1].tone == FleetCheckTone.none && disk?.attention.isEmpty == true)
        let detail = page.check.detail(row: "disk", mac: Self.mini)
        #expect(detail.ignored && detail.ignorable && !detail.fixable)
        #expect(P.card(Self.mini, page).needs == 2)
    }

    @Test func aFixThatRunsShowsAsFixingWithItsThread() {
        let thread = UUID()
        let fixing = FleetCheckFixing(dispatchID: thread, threadTitle: "Install node 22 on Mac mini")
        let page = Self.page(fixing: [Self.mini: ["need:node:22": fixing]])
        let node = page.check.groups.flatMap(\.rows).first { $0.id == "need:node:22" }
        #expect(node?.cells[1] == FleetCheckCell(text: "Fixing…", tone: .fixing))
        let detail = page.check.detail(row: "need:node:22", mac: Self.mini)
        #expect(detail.fixing == fixing && detail.fixAllCount == 3, "everything else on the Mac that can be fixed: \(detail.fixAllCount)")
        #expect(page.check.fixableRows(on: Self.mini) == ["tool:muse", "models", "disk"])
    }

    @Test func aRunningFixIsReadFromTheDispatchLogAndEndsWithTheThread() {
        var snapshot = Self.snapshot()
        var record = FleetDispatchRecord(kind: .userThread, parentHostID: Self.here, parentHostName: "MacBook Pro", targetHostID: Self.mini, targetHostName: "Mac mini",
                                         state: .running, title: "Install node 22 on Mac mini", task: "", repoKey: "github.com/acme/web", fixes: ["need:node:22"], createdAt: 1)
        snapshot.dispatches = [record]
        #expect(Self.page(snapshot).check.detail(row: "need:node:22", mac: Self.mini).fixing?.dispatchID == record.id)
        // A thread that hasn't been placed yet is the Mac that was asked for.
        record.targetHostID = nil
        record.requestedHost = Self.mini.uuidString
        record.state = .waitingWake
        snapshot.dispatches = [record]
        #expect(Self.page(snapshot).check.detail(row: "need:node:22", mac: Self.mini).fixing != nil)
        for ended in [FleetDispatchState.delivering, .done, .failed, .cancelled] {
            record.state = ended
            snapshot.dispatches = [record]
            #expect(Self.page(snapshot).check.detail(row: "need:node:22", mac: Self.mini).fixing == nil, "\(ended)")
        }
    }

    // MARK: The panel

    @Test func theNodePanelSaysWhatDiffersAndWhatItChanges() {
        let detail = Self.page().check.detail(row: "need:node:22")
        #expect(detail.pill == "Differs on Mac mini" && detail.pillTone == .warn && detail.title == "node 22 on Mac mini")
        #expect(detail.body == "payments-api and web pin node 22 in .nvmrc. Mac mini has node 20.18.")
        #expect(detail.effect == "Auto still sends these repos there, but their installs and tests may fail on the older node.")
        #expect(detail.mac == Self.mini && detail.fixable && detail.fixAllCount == 4)
    }

    @Test func aRowThatMatchesEverywhereSaysSo() {
        var snapshot = Self.snapshot()
        snapshot.macs[1].check?.items.removeAll { $0.id == "need:node:22" }
        snapshot.macs[1].check?.items.append(Self.node(.ok, "22.4", repos: ["payments-api"]))
        let detail = Self.page(snapshot).check.detail(row: "need:node:22")
        #expect(detail.pill == "Matches on every Mac" && detail.pillTone == .good && !detail.fixable && detail.command == nil)
    }

    @Test func aMissingProgramNamesTheMacsOwnPackageManagersCommand() {
        let detail = Self.page().check.detail(row: "tool:muse")
        #expect(detail.pill == "Missing on Mac mini" && detail.command == "nix profile install nixpkgs#muse")
        #expect(detail.commandNote?.contains("installs tools with nix") == true)
    }

    @Test func theCommandFollowsTheMacsPackageManagerThenTheToolsOwnInstaller() {
        func command(_ tool: FleetRepoNeed.Tool, _ version: String?, _ pm: String) -> String? {
            FleetCheckPresentation.command(for: Self.item("x", .needs, "x", .warn, "Missing", kind: .tool, tool: tool.rawValue, want: version), packageManager: pm, mac: "Mac mini")?.command
        }
        #expect(command(.node, "22", "nix") == "nix profile install nixpkgs#nodejs_22")
        #expect(command(.node, "22", "brew") == "brew install node@22")
        #expect(command(.node, "22", "") == "curl -fsSL https://fnm.vercel.app/install | bash && fnm install 22")
        #expect(command(.pnpm, "9", "nix") == "nix profile install nixpkgs#pnpm_9")
        #expect(command(.pnpm, "9", "brew") == "brew install pnpm")
        #expect(command(.pnpm, "9", "") == "corepack enable pnpm && corepack prepare pnpm@9 --activate")
        #expect(command(.nix, nil, "brew") == "brew install nix")
        #expect(command(.nix, nil, "")?.contains("install.determinate.systems/nix") == true)
        #expect(command(.cargo, nil, "nix") == "nix profile install nixpkgs#cargo")
        #expect(command(.cargo, "1.75", "")?.contains("sh.rustup.rs") == true)
        #expect(command(.python, "3.12", "nix") == "nix profile install nixpkgs#python312")
        #expect(command(.python, "3.12", "brew") == "brew install python@3.12")
        #expect(command(.go, "1.22", "brew") == "brew install go")
        // No package manager installs Xcode: the App Store does, whatever the Mac uses.
        for pm in ["nix", "brew", ""] { #expect(command(.xcode, "26", pm)?.hasPrefix("open \"macappstore://") == true) }
    }

    @Test func aCommandThatNeedsNoPackageManagerIsTheSameOnEveryMac() {
        let disk = Self.item("disk", .system, "Free disk", .warn, "38 GB", kind: .disk)
        #expect(FleetCheckPresentation.command(for: disk, packageManager: "nix", mac: "m")?.command == "du -sh ~/Library/Developer/Xcode/DerivedData ~/Library/Caches")
        #expect(FleetCheckPresentation.command(for: disk, packageManager: "", mac: "m")?.note == "Shows the usual large caches. Nothing is deleted.")
        let sleep = Self.item("sleep", .system, "Stays awake", .warn, "Sleeps after 10 min", kind: .sleep)
        #expect(FleetCheckPresentation.command(for: sleep, packageManager: "brew", mac: "m")?.command == "sudo pmset -c sleep 0")
        // What has no honest command offers none: it is fixed by looking.
        for kind in [FleetCheckItem.Kind.remote, .provider, .build, .other] {
            #expect(FleetCheckPresentation.command(for: Self.item("x", .access, "x", .warn, "v", kind: kind, tool: "x"), packageManager: "nix", mac: "m") == nil)
        }
        // An MCP server's own program: the Mac's package manager by name, or nothing to guess on a Mac with neither.
        let unknown = Self.item("tool:muse", .tools, "muse", .warn, "Missing", kind: .command, tool: "muse")
        #expect(FleetCheckPresentation.command(for: unknown, packageManager: "brew", mac: "m")?.command == "brew install muse")
        #expect(FleetCheckPresentation.command(for: unknown, packageManager: "", mac: "m") == nil)
        let npx = Self.item("tool:npx", .tools, "npx", .warn, "Missing", kind: .command, tool: "npx")
        #expect(FleetCheckPresentation.command(for: npx, packageManager: "nix", mac: "m")?.command == "nix profile install nixpkgs#nodejs")
    }

    @Test func aStudioMacsPanelUsesItsOwnHomebrew() {
        let detail = Self.page().check.detail(row: "sleep")
        #expect(detail.title == "Mac Studio sleeps after 10 minutes" && detail.command == "sudo pmset -c sleep 0" && detail.commandNote == "Asks for the Mac’s password.")
    }

    // MARK: Fix with an agent

    @Test func oneRowsFixIsAThreadTitledForIt() throws {
        let fix = try #require(Self.page().check.fix(on: Self.mini, rows: ["need:node:22"]))
        #expect(fix.title == "Switch node 22 on Mac mini" && fix.items == ["need:node:22"] && fix.macName == "Mac mini" && fix.repos == ["payments-api", "web"])
        #expect(fix.prompt.contains("1. node 22: payments-api and web ask for it in .nvmrc. This Mac has 20.18."))
        #expect(fix.prompt.contains("Suggested: `nix profile install nixpkgs#nodejs_22`."))
        #expect(fix.prompt.contains("Use nix to install programs on this Mac."))
        #expect(fix.prompt.contains("Stop and ask me before anything needs a password"))
        #expect(fix.prompt.contains("Change nothing else"))
        let missing = try #require(Self.page().check.fix(on: Self.mini, rows: ["tool:muse"]))
        #expect(missing.title == "Install muse on Mac mini")
    }

    @Test func fixingEverythingIsOneThreadWithTheWholeChecklist() throws {
        let fix = try #require(Self.page().check.fix(on: Self.mini))
        #expect(fix.title == "Fix what Check found on Mac mini" && fix.items == ["need:node:22", "tool:muse", "models", "disk"])
        for number in 1...4 { #expect(fix.prompt.contains("\n\(number). ")) }
        // A build behind the fleet's newest is not something an agent fixes; and what is already being fixed is left out.
        #expect(Self.page().check.fix(on: Self.studio)?.items == ["sleep"])
        let thread = FleetCheckFixing(dispatchID: UUID(), threadTitle: "t")
        #expect(Self.page(fixing: [Self.mini: ["models": thread]]).check.fix(on: Self.mini)?.items == ["need:node:22", "tool:muse", "disk"])
        #expect(Self.page().check.fix(on: Self.here) == nil)
    }

    @Test func aMacWithNoPackageManagerIsToldToUseEachToolsOwnInstaller() throws {
        var snapshot = Self.snapshot()
        snapshot.macs[1].check?.packageManager = ""
        let fix = try #require(Self.page(snapshot).check.fix(on: Self.mini, rows: ["need:node:22"]))
        #expect(fix.prompt.contains("Use each tool's own installer"))
        #expect(fix.prompt.contains("fnm install 22"))
    }

    @Test func theTimeSinceALookIsSaidInTheBiggestUnit() {
        #expect(FleetCheckPresentation.since(5) == "just now" && FleetCheckPresentation.since(180) == "3m ago")
        #expect(FleetCheckPresentation.since(7_300) == "2h ago" && FleetCheckPresentation.since(200_000) == "2d ago")
    }
}
