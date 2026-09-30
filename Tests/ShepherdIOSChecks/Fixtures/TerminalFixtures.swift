import Foundation
import UIKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// Terminal track's screens: the iPad panel under a thread (a tab, keys, maximized) and the
// iPhone's full-screen terminals. The host's layout carries the terminals, one tab each; every
// session shows a canned screen (`MobileTerminals.cannedScreens`) and never attaches, so no
// screenshot resizes or types into a host terminal.
extension FixtureCatalog {
    static var terminal: [FixtureScreen] {
        let ref = FixtureData.ref(FixtureData.preview)
        let thread = MobileRoute.thread(ref)
        return [
            FixtureScreen(name: "terminal", hosts: TerminalFixture.hosts(), routes: [thread],
                          prepare: { _ in await TerminalFixture.show(ref) }),
            FixtureScreen(name: "terminal-keys", hosts: TerminalFixture.hosts(), routes: [thread],
                          prepare: { _ in await TerminalFixture.show(ref, focus: true) }),
            FixtureScreen(name: "terminal-maximized", hosts: TerminalFixture.hosts(), routes: [thread],
                          prepare: { _ in await TerminalFixture.show(ref, maximized: true) }),
            FixtureScreen(name: "terminal-phone", hosts: TerminalFixture.hosts(), routes: [thread, .terminal(.panes(ref))],
                          prepare: { _ in await TerminalFixture.show(ref) }),
            FixtureScreen(name: "terminal-phone-keys", hosts: TerminalFixture.hosts(), routes: [thread, .terminal(.panes(ref))],
                          prepare: { _ in await TerminalFixture.show(ref, focus: true) }),
            // Closing a tab: its title and the shell that stops.
            FixtureScreen(name: "terminal-close", hosts: TerminalFixture.hosts(), routes: [thread],
                          prepare: { _ in await TerminalFixture.show(ref, closing: true) }),
            FixtureScreen(name: "terminal-phone-close", hosts: TerminalFixture.hosts(), routes: [thread, .terminal(.panes(ref))],
                          prepare: { _ in await TerminalFixture.show(ref, closing: true) }),
            // The host relaunched: the terminal on screen has a new shell, which must get its own view.
            FixtureScreen(name: "terminal-relaunched", hosts: TerminalFixture.hosts(), routes: [thread],
                          prepare: { _ in await TerminalFixture.relaunch(ref) }),
            FixtureScreen(name: "terminal-phone-relaunched", hosts: TerminalFixture.hosts(), routes: [thread, .terminal(.panes(ref))],
                          prepare: { _ in await TerminalFixture.relaunch(ref) }),
        ]
    }
}

enum TerminalFixture {
    static let threadPane = PaneID(rawValue: "pane-thread")
    static let shell = PaneID(rawValue: "pane-zsh")
    static let beside = PaneID(rawValue: "pane-logs")
    static let psql = PaneID(rawValue: "pane-psql")
    static let shellSession = SessionID(rawValue: "session-zsh")
    static let besideSession = SessionID(rawValue: "session-logs")
    static let psqlSession = SessionID(rawValue: "session-psql")
    /// The shell pane's session after the host relaunched (`terminal-relaunched`).
    static let relaunchedSession = SessionID(rawValue: "session-zsh-relaunched")

    /// Studio's hosts, with the preview agent's layout holding its thread and three terminal tabs.
    static func hosts() -> [FixtureHostData] {
        var hosts = FixtureData.hosts()
        guard let index = hosts.firstIndex(where: { $0.id == FixtureData.studio }) else { return hosts }
        var state = hosts[index].state
        let tabID = TabID(rawValue: "tab-" + FixtureData.preview.rawValue)
        var layout = PaneNode.leaf(LeafPane(id: threadPane, cwd: "/Users/dev/Shepherd", agentID: FixtureData.preview))
        // Opened with + three times: each beside the thread, the newer nearer it.
        for terminal in [
            LeafPane(id: beside, sessionID: besideSession, cwd: "/Users/dev/Shepherd"),
            LeafPane(id: psql, sessionID: psqlSession, cwd: "/Users/dev/payments"),
            LeafPane(id: shell, sessionID: shellSession, cwd: "/Users/dev/Shepherd"),
        ] {
            layout = .split(axis: .horizontal, ratio: 0.5, first: layout, second: .leaf(terminal))
        }
        state.tabs.append(Tab(id: tabID, spaceID: FixtureData.shepherdSpace.id, order: 0, layout: layout))
        if let agent = state.agents.firstIndex(where: { $0.id == FixtureData.preview }) {
            state.agents[agent].paneID = threadPane
        }
        hosts[index].state = state
        // What the host says runs in each (a read, answered like a Mac's server would).
        let activity: [RemoteTerminalActivity] = [
            RemoteTerminalActivity(paneID: shell, sessionID: shellSession, process: "zsh", command: nil, outputSequence: 12),
            RemoteTerminalActivity(paneID: psql, sessionID: psqlSession, process: "psql", command: "psql payments", outputSequence: 7),
            RemoteTerminalActivity(paneID: beside, sessionID: besideSession, process: "tail",
                                   command: "tail -f build.log", outputSequence: 30),
        ]
        hosts[index].reply = { request in
            guard case .agentQuery(let id, FixtureData.preview, .terminals) = request else { return nil }
            return .agentResult(id: id, result: .terminals(activity))
        }
        return hosts
    }

    /// Opens the panel on the first tab with canned screens, optionally focused (the key row
    /// shows), maximized, or asking to close that tab.
    @MainActor static func show(_ ref: AgentRef, focus: Bool = false, maximized: Bool = false, closing: Bool = false) async {
        let terminals = MobileTerminals.shared
        terminals.cannedScreens = [shellSession: shellScreen, besideSession: logsScreen, psqlSession: psqlScreen,
                                   relaunchedSession: relaunchedScreen]
        terminals.update(ref) {
            $0.shown = true
            $0.maximized = maximized
            $0.chosenTab = shell
        }
        if closing {
            // As a person taps × on a tab whose title shows: once the host said what runs in it.
            await wait { terminals.activity[ref]?.isEmpty == false }
            terminals.cannedClose = shell
        }
        guard focus else { return }
        let session = terminals.session(host: ref.host, id: shellSession)
        await FixtureWindows.wait("terminal surface mounted", seconds: 5) { session.surface?.window != nil }
        // As with a hardware keyboard: the key row without the software keyboard over the shot.
        session.surface?.inputView = UIView(frame: .zero)
        _ = session.surface?.becomeFirstResponder()
    }

    /// Shows the shell's screen, then has the host push the layout it has after a relaunch: the
    /// same terminal with a new session. The terminal must drop the old screen for the new session's own
    /// (checked, and printed as a FIXTURE CHECK).
    @MainActor static func relaunch(_ ref: AgentRef) async {
        await show(ref)
        let terminals = MobileTerminals.shared
        let old = terminals.session(host: ref.host, id: shellSession)
        await wait { old.surface?.window != nil }
        guard let host = FixtureHost.running(ref.host) else {
            FixtureCheck.report("FIXTURE CHECK FAILED: no running host for \(ref.host)")
            return
        }
        var state = host.data.state
        for index in state.tabs.indices {
            state.tabs[index].layout = state.tabs[index].layout.updatingLeaf(shell) { $0.sessionID = relaunchedSession }
        }
        host.push(state)
        await wait { terminals.existingSession(host: ref.host, id: relaunchedSession)?.surface?.window != nil }
        let new = terminals.existingSession(host: ref.host, id: relaunchedSession)
        if new?.surface?.window != nil, old.surface?.window == nil {
            print("FIXTURE CHECK ok: the relaunched shell has its own screen")
        } else {
            FixtureCheck.report("FIXTURE CHECK FAILED: the terminal kept the old shell's screen (new on screen: \(new?.surface?.window != nil), old on screen: \(old.surface?.window != nil))")
        }
        fflush(stdout)
    }

    @MainActor private static func wait(file: StaticString = #fileID, line: UInt = #line, until condition: () -> Bool) async {
        await FixtureWindows.wait("terminal readiness", seconds: 5, file: file, line: line, until: condition)
    }

    private static let esc = "\u{1B}"
    private static func prompt(_ command: String) -> String {
        "\(esc)[32mdev@studio\(esc)[0m \(esc)[34m~/Shepherd\(esc)[0m \(esc)[33m(terminal-tabs)\(esc)[0m \(esc)[90m$\(esc)[0m \(command)\r\n"
    }

    static let shellScreen = Data((
        "\(esc)]0;zsh\u{07}" +
        prompt("swift test --filter TerminalPanel") +
        "\(esc)[90mBuilding for debugging...\(esc)[0m\r\n" +
        "\(esc)[32m✔\(esc)[0m Suite \"Terminal panel\" passed after 0.002 seconds.\r\n" +
        "\(esc)[32m✔\(esc)[0m Suite \"Terminal keys\" passed after 0.003 seconds.\r\n" +
        "\(esc)[32m✔\(esc)[0m Test run with 21 tests in 4 suites passed.\r\n" +
        prompt("git status --short") +
        "\(esc)[31m M\(esc)[0m App/iOS/Terminal/TerminalPanelView.swift\r\n" +
        "\(esc)[32m??\(esc)[0m Tests/ShepherdIOSChecks/Fixtures/TerminalFixtures.swift\r\n" +
        "\(esc)[32mdev@studio\(esc)[0m \(esc)[34m~/Shepherd\(esc)[0m \(esc)[33m(terminal-tabs)\(esc)[0m \(esc)[90m$\(esc)[0m "
    ).utf8)

    static let relaunchedScreen = Data((
        "\(esc)]0;zsh\u{07}" +
        "\(esc)[90mLast login: Fri Sep 25 12:47:43 on ttys004\(esc)[0m\r\n" +
        "\(esc)[32mdev@studio\(esc)[0m \(esc)[34m~/Shepherd\(esc)[0m \(esc)[33m(terminal-tabs)\(esc)[0m \(esc)[90m$\(esc)[0m "
    ).utf8)

    static let logsScreen = Data((
        "\(esc)]0;tail\u{07}" +
        prompt("tail -f build.log") +
        "\(esc)[90m02:14:07\(esc)[0m compiling ShepherdRemote\r\n" +
        "\(esc)[90m02:14:09\(esc)[0m compiling ShepherdUI\r\n" +
        "\(esc)[90m02:14:12\(esc)[0m linking Shepherd iOS\r\n" +
        "\(esc)[90m02:14:13\(esc)[0m \(esc)[32mbuild succeeded\(esc)[0m\r\n"
    ).utf8)

    static let psqlScreen = Data((
        "\(esc)]0;psql payments\u{07}" +
        prompt("psql payments") +
        "payments=# select count(*) from refunds;\r\n count \r\n-------\r\n    42\r\n(1 row)\r\n\r\npayments=# "
    ).utf8)
}
