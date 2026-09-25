import Foundation
import UIKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// Terminal track's screens: the iPad panel under a thread (a tab, a split tab, maximized, no
// terminals yet) and the iPhone's full-screen panes. The host's layout carries the panes; every
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
            FixtureScreen(name: "terminal-split", hosts: TerminalFixture.hosts(split: true), routes: [thread],
                          prepare: { _ in await TerminalFixture.show(ref) }),
            FixtureScreen(name: "terminal-maximized", hosts: TerminalFixture.hosts(), routes: [thread],
                          prepare: { _ in await TerminalFixture.show(ref, maximized: true) }),
            FixtureScreen(name: "terminal-empty", hosts: TerminalFixture.hosts(terminals: false), routes: [thread],
                          prepare: { _ in await TerminalFixture.show(ref) }),
            FixtureScreen(name: "terminal-phone", hosts: TerminalFixture.hosts(), routes: [thread, .terminal(.panes(ref))],
                          prepare: { _ in await TerminalFixture.show(ref) }),
            FixtureScreen(name: "terminal-phone-keys", hosts: TerminalFixture.hosts(), routes: [thread, .terminal(.panes(ref))],
                          prepare: { _ in await TerminalFixture.show(ref, focus: true) }),
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

    /// Studio's hosts, with the preview agent's layout holding its thread and, unless
    /// `terminals` is false, two terminal tabs (the first split in two with `split`).
    static func hosts(terminals: Bool = true, split: Bool = false) -> [FixtureHostData] {
        var hosts = FixtureData.hosts()
        guard let index = hosts.firstIndex(where: { $0.id == FixtureData.studio }) else { return hosts }
        var state = hosts[index].state
        let tabID = TabID(rawValue: "tab-" + FixtureData.preview.rawValue)
        var layout = PaneNode.leaf(LeafPane(id: threadPane, cwd: "/Users/dev/Shepherd", agentID: FixtureData.preview))
        if terminals {
            let first: PaneNode = split
                ? .split(axis: .vertical, ratio: 0.5,
                         first: .leaf(LeafPane(id: shell, sessionID: shellSession, cwd: "/Users/dev/Shepherd")),
                         second: .leaf(LeafPane(id: beside, sessionID: besideSession, cwd: "/Users/dev/Shepherd")))
                : .leaf(LeafPane(id: shell, sessionID: shellSession, cwd: "/Users/dev/Shepherd"))
            // Opened with + twice: each split off the thread, the newer nearer it.
            layout = .split(axis: .horizontal, ratio: 0.6,
                            first: .split(axis: .horizontal, ratio: 0.6, first: layout,
                                          second: .leaf(LeafPane(id: psql, sessionID: psqlSession, cwd: "/Users/dev/payments"))),
                            second: first)
        }
        state.tabs.append(Tab(id: tabID, spaceID: FixtureData.shepherdSpace.id, order: 0, layout: layout))
        if let agent = state.agents.firstIndex(where: { $0.id == FixtureData.preview }) {
            state.agents[agent].paneID = threadPane
        }
        hosts[index].state = state
        // What the host says runs in each (a read, answered like a Mac's server would).
        let activity: [RemoteTerminalActivity] = terminals ? [
            RemoteTerminalActivity(paneID: shell, sessionID: shellSession, process: "zsh", command: nil, outputSequence: 12),
            RemoteTerminalActivity(paneID: psql, sessionID: psqlSession, process: "psql", command: "psql payments", outputSequence: 7),
        ] + (split ? [RemoteTerminalActivity(paneID: beside, sessionID: besideSession, process: "tail",
                                            command: "tail -f build.log", outputSequence: 30)] : []) : []
        hosts[index].reply = { request in
            guard case .agentQuery(let id, FixtureData.preview, .terminals) = request else { return nil }
            return .agentResult(id: id, result: .terminals(activity))
        }
        return hosts
    }

    /// Opens the panel on the first tab with canned screens, optionally focused (the key row
    /// shows) or maximized.
    @MainActor static func show(_ ref: AgentRef, focus: Bool = false, maximized: Bool = false) async {
        let terminals = MobileTerminals.shared
        terminals.cannedScreens = [shellSession: shellScreen, besideSession: logsScreen, psqlSession: psqlScreen]
        terminals.update(ref) {
            $0.shown = true
            $0.maximized = maximized
            $0.chosenTab = shell
            $0.chosenPanes = [shell, beside]
            $0.focusedPane = shell
        }
        guard focus else { return }
        let session = terminals.session(host: ref.host, id: shellSession)
        let deadline = Date().addingTimeInterval(5)
        while session.surface?.window == nil, Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        // As with a hardware keyboard: the key row without the software keyboard over the shot.
        session.surface?.inputView = UIView(frame: .zero)
        _ = session.surface?.becomeFirstResponder()
    }

    private static let esc = "\u{1B}"
    private static func prompt(_ command: String) -> String {
        "\(esc)[32mdev@studio\(esc)[0m \(esc)[34m~/Shepherd\(esc)[0m \(esc)[33m(terminal-panes)\(esc)[0m \(esc)[90m$\(esc)[0m \(command)\r\n"
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
        "\(esc)[32mdev@studio\(esc)[0m \(esc)[34m~/Shepherd\(esc)[0m \(esc)[33m(terminal-panes)\(esc)[0m \(esc)[90m$\(esc)[0m "
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
