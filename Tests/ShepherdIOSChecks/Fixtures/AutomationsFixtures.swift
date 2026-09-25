import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// Automations track's screens: the list with runs (iPhone; the iPad's list beside a detail),
// one automation with its chart and runs, one whose run is going, one whose run finished with
// its thread still there (Run now again, Open run to read it), one whose run was cut short by
// the host quitting, the form, and a host from before automations over the remote protocol
// (read-only). Hosts answer `runs` from here; the fixture host refuses every change.
extension FixtureCatalog {
    static var automations: [FixtureScreen] {
        let fleet = AutomationsFixtureData.fleet()
        let settle: @MainActor (MobileApp) async -> Void = { app in await AutomationsStore.of(app.hosts).refreshRuns() }
        let bump = AutomationKey(host: FixtureData.buildBox, automation: AutomationsFixtureData.bump)
        let choose: (AutomationKey) -> @MainActor (MobileApp) async -> Void = { key in
            { app in
                await AutomationsStore.of(app.hosts).refreshRuns()
                AutomationsStore.of(app.hosts).chosen = key
            }
        }
        return [
            FixtureScreen(name: "automations-list", hosts: fleet, routes: [.home(.automations)], prepare: choose(bump)),
            FixtureScreen(name: "automations-running", hosts: fleet, routes: [.home(.automations)],
                          prepare: choose(AutomationKey(host: FixtureData.studio, automation: AutomationsFixtureData.merge))),
            FixtureScreen(name: "automation-detail", hosts: fleet,
                          routes: [.home(.automations), .automations(.detail(host: FixtureData.buildBox, automation: AutomationsFixtureData.bump))],
                          prepare: settle),
            FixtureScreen(name: "automation-detail-running", hosts: fleet,
                          routes: [.home(.automations), .automations(.detail(host: FixtureData.studio, automation: AutomationsFixtureData.merge))],
                          prepare: settle),
            FixtureScreen(name: "automation-detail-finished", hosts: AutomationsFixtureData.fleet(bumpLatest: .finished),
                          routes: [.home(.automations), .automations(.detail(host: FixtureData.buildBox, automation: AutomationsFixtureData.bump))],
                          prepare: settle),
            FixtureScreen(name: "automation-detail-interrupted", hosts: AutomationsFixtureData.fleet(bumpLatest: .interrupted),
                          routes: [.home(.automations), .automations(.detail(host: FixtureData.buildBox, automation: AutomationsFixtureData.bump))],
                          prepare: settle),
            FixtureScreen(name: "automation-edit", hosts: fleet, routes: [.home(.automations)],
                          presented: .automations(.edit(host: FixtureData.buildBox, automation: AutomationsFixtureData.bump)), prepare: settle),
            FixtureScreen(name: "automation-new", hosts: fleet, routes: [.home(.automations)],
                          presented: .automations(.edit(host: nil, automation: nil)), prepare: settle),
            FixtureScreen(name: "automations-readonly", hosts: AutomationsFixtureData.fleet(olderStudio: true), routes: [.home(.automations)],
                          prepare: settle),
        ]
    }
}

/// Home's fleet, with the runs each host kept.
enum AutomationsFixtureData {
    static let merge = AutomationID(rawValue: "auto-merge")
    static let cleanup = AutomationID(rawValue: "auto-cleanup")
    static let triage = AutomationID(rawValue: "auto-triage")
    static let bump = AutomationID(rawValue: "auto-bump")
    static let bumpRun = AgentID(rawValue: "agent-bump")

    /// `olderStudio`: Studio answers `hello` as a host from before automations.v1.
    /// `bumpLatest`: the weekly bump ran again a few minutes ago. A finished run's thread is still
    /// open; a stopped or interrupted one has gone.
    static func fleet(olderStudio: Bool = false, bumpLatest: AutomationRunResult? = nil) -> [FixtureHostData] {
        let now = Date().timeIntervalSince1970
        var kept = runs(now: now)
        let bumpFinished = bumpLatest == .finished
        if let bumpLatest {
            let id = UUID(uuidString: "A0000000-0000-4000-8000-000000000099")!
            kept[bump, default: []].append(bumpFinished
                ? AutomationRun(id: id, startedAt: now - 340, settledAt: now - 60, result: .finished, agentID: bumpRun)
                : AutomationRun(id: id, startedAt: now - 340, endedAt: now - 60, result: bumpLatest))
        }
        let runs = kept
        return HomeFixtureData.fleet().map { host in
            var host = host
            if bumpFinished, host.id == FixtureData.buildBox {
                host.state.agents.append(FixtureData.agent(bumpRun, "Weekly dependency bump", .done, space: HomeFixtureData.hiddenSpace))
                if let index = host.state.automations.firstIndex(where: { $0.id == bump }) {
                    host.state.automations[index].agentID = bumpRun
                }
            }
            let older = olderStudio && host.id == FixtureData.studio
            host.reply = { request in
                switch request {
                case .hello(let id, _, _, _, _) where older:
                    return .helloOk(id: id, protocolVersion: RemoteProtocol.version,
                                    capabilities: RemoteProtocol.capabilities.filter { $0 != RemoteProtocol.automationsCapability })
                case .automation(let id, let automation, .runs):
                    return .automationResult(id: id, result: .runs(runs[automation] ?? []))
                default:
                    return nil
                }
            }
            return host
        }
    }

    /// Weekly bumps for fourteen weeks, a merge watch going now after three earlier ones, a triage
    /// run waiting on you, and two cleanups before it was switched off.
    static func runs(now: Double) -> [AutomationID: [AutomationRun]] {
        let day = 86_400.0
        let monday = floor(now / day) * day + 9 * 3600 - 7 * day
        var weekly: [AutomationRun] = []
        for week in 0..<14 {
            let start = monday - Double(13 - week) * 7 * day
            let id = UUID(uuidString: String(format: "A0000000-0000-4000-8000-%012d", week))!
            switch week {
            case 5: weekly.append(AutomationRun(id: id, startedAt: start, endedAt: start + 1_320, result: .interrupted))
            case 10: weekly.append(AutomationRun(id: id, startedAt: start, settledAt: start + 900, endedAt: start + 960, result: .finished))
            case 11: weekly.append(AutomationRun(id: id, startedAt: start, endedAt: start + 240, result: .stopped))
            default:
                let took = Double(260 + (week * 37) % 120)
                weekly.append(AutomationRun(id: id, startedAt: start, settledAt: start + took, endedAt: start + took + 30, result: .finished))
            }
        }
        let mergeRuns = (0..<3).map { index in
            let start = now - Double(3 - index) * day
            return AutomationRun(id: UUID(uuidString: String(format: "B0000000-0000-4000-8000-%012d", index))!, startedAt: start,
                                 settledAt: start + 1_500, endedAt: start + 1_600, result: .finished)
        } + [AutomationRun(id: UUID(uuidString: "B0000000-0000-4000-8000-000000000099")!, startedAt: now - 240, result: .running,
                           agentID: HomeFixtureData.merge)]
        return [
            bump: weekly,
            merge: mergeRuns,
            triage: [AutomationRun(id: UUID(uuidString: "C0000000-0000-4000-8000-000000000001")!, startedAt: now - 3_700, result: .needsYou,
                                   agentID: HomeFixtureData.triage)],
            cleanup: [
                AutomationRun(id: UUID(uuidString: "D0000000-0000-4000-8000-000000000001")!, startedAt: now - 14 * day,
                              settledAt: now - 14 * day + 50, endedAt: now - 14 * day + 60, result: .finished),
                AutomationRun(id: UUID(uuidString: "D0000000-0000-4000-8000-000000000002")!, startedAt: now - 7 * day,
                              endedAt: now - 7 * day + 30, result: .stopped),
            ],
        ]
    }
}
