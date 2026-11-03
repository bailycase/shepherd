import Foundation
import Observation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// Compiles the real iOS store. Only its observable host source and screen-only pause-list
// dependency are doubles; reads and dates are deterministic, with no sockets or preferences.
@main
struct AutomationsStoreCheck {
    @MainActor
    static func main() async {
        let utc = TimeZone(identifier: "UTC")!
        let t0 = 1_790_215_200.0 // Sep 24 2026, 02:00 UTC
        var now = Date(timeIntervalSince1970: t0)
        var locale = Locale(identifier: "en_US_POSIX")
        var deviceZone = utc
        let space = Space(name: "project", path: "/project")
        let runAgent = Agent(name: "run", spaceID: space.id, tabID: TabID(), status: .working)
        let destination = Agent(name: "destination", spaceID: space.id, tabID: TabID())
        let unrelated = Agent(name: "other", spaceID: space.id, tabID: TabID())
        let a = Automation(name: "manual", prompt: "work", cwd: space.path, agentID: runAgent.id)
        var b = Automation(name: "scheduled", prompt: "work", cwd: space.path)
        b.trigger = .schedule(AutomationSchedule(rrule: "FREQ=DAILY;BYHOUR=9;BYMINUTE=0"))
        b.destination = .thread(destination.id)
        let host = MobileHost(state: ShepherdState(spaces: [space], agents: [runAgent, destination, unrelated], automations: [a, b]))
        let hosts = MobileHosts(host)
        let ka = AutomationKey(host: host.id, automation: a.id)
        let kb = AutomationKey(host: host.id, automation: b.id)
        var runs = [
            a.id: [AutomationRun(startedAt: t0, settledAt: t0 + 43, result: .finished, agentID: runAgent.id)],
            b.id: [AutomationRun(startedAt: t0, settledAt: t0 + 60, result: .finished)],
        ]
        var status = AutomationTriggerStatus(state: .active, nextRunAt: t0 + 3600, timeZone: "UTC")
        var reads: [AutomationID: Int] = [:]
        var statusReads = 0
        let store = AutomationsStore(hosts: hosts, readRuns: { _, id in
            reads[id, default: 0] += 1
            return runs[id] ?? []
        }, readStatus: { _, _ in
            statusReads += 1
            return status
        }, dates: { (now, locale, deviceZone) })
        await store.refresh()
        check(store.details[ka]?.lastRun?.started == "Today 02:00", "initial dates use the injected clock")
        check(store.details[kb]?.trigger?.next == "Today 03:00", "trigger dates use the same clock")

        var counts = store.detailDerivations
        let initialReads = reads
        var revision = store.inputRevision
        host.state.spaces.append(Space(name: "unrelated", path: "/elsewhere"))
        host.state.agents[2].status = .blocked
        host.state.agents[0].checkout = AgentCheckout(branch: "other", changedFiles: 7)
        await eventually("irrelevant state observed") { store.inputRevision > revision }
        check(store.detailDerivations == counts && reads == initialReads, "irrelevant state neither derives details nor reads runs")

        // The real watch path starts one read loop and refreshes runs on relevant state pushes.
        let firstStatusReads = statusReads
        let watch = Task { await store.watch() }
        await eventually("watch starts") { statusReads > firstStatusReads }
        check(store.detailDerivations == counts, "watching unchanged data reuses all details")
        revision = store.inputRevision
        host.state.agents[2].name = "Unrelated rename while watching"
        await eventually("irrelevant watched update observed") { store.inputRevision > revision }
        check(store.detailDerivations == counts && reads == initialReads, "watching does not widen invalidation")
        revision = store.inputRevision
        runs[a.id]![0].result = .stopped
        host.state.agents[0].status = .done
        await eventually("changed run read while watching") {
            store.inputRevision > revision && store.details[ka]?.runs.first?.word == "stopped"
        }
        check(reads[a.id] == initialReads[a.id]! + 1 && reads[b.id] == initialReads[b.id], "only the changed run signature is read")
        check(store.detailDerivations[ka]! > counts[ka]! && store.detailDerivations[kb] == counts[kb], "a changed run leaves its peer detail cached")
        check(store.details[ka]?.row.status == "Finished", "agent status updates the row independently of the retained run")

        counts = store.detailDerivations
        revision = store.inputRevision
        host.state.agents[1].name = "Renamed destination"
        await eventually("destination rename observed") { store.inputRevision > revision }
        check(store.details[kb]?.row.runsOn.contains("Renamed destination") == true, "destination names invalidate the detail")
        check(store.detailDerivations[ka] == counts[ka] && store.detailDerivations[kb] == counts[kb]! + 1, "destination rename rebuilds only its automation")

        counts = store.detailDerivations
        status.state = .paused
        await store.refreshStatuses()
        check(store.details[kb]?.trigger?.state?.paused == true, "trigger status invalidates its detail")
        check(store.detailDerivations[ka] == counts[ka] && store.detailDerivations[kb] == counts[kb]! + 1, "status leaves other details cached")
        counts = store.detailDerivations
        status.runsToday = 3
        await store.refreshStatuses()
        check(store.details[kb]?.trigger?.today?.hasPrefix("3 of ") == true, "detail-only status fields invalidate even when its row is unchanged")
        check(store.detailDerivations[ka] == counts[ka] && store.detailDerivations[kb] == counts[kb]! + 1, "detail-only status changes stay local")
        counts = store.detailDerivations
        await store.refreshStatuses()
        check(store.detailDerivations == counts, "unchanged status polls do not format runs")
        watch.cancel()
        await watch.value

        // Advance explicit timestamps, never sleep through a boundary. refreshStatuses is also
        // the watch's poll path, and must age labels even when every reply is unchanged.
        now = Date(timeIntervalSince1970: t0 + 23 * 3600) // Sep 25 01:00 UTC
        await store.refreshStatuses()
        check(store.details[ka]?.lastRun?.started == "Yesterday 02:00", "cached last run ages at midnight")
        check(store.details[kb]?.trigger?.next == "Yesterday 03:00", "cached trigger dates age too")
        check(store.detailDerivations[ka] == counts[ka]! + 1 && store.detailDerivations[kb] == counts[kb]! + 1, "each changed host day invalidates once")
        counts = store.detailDerivations
        now.addTimeInterval(60)
        await store.refreshStatuses()
        check(store.detailDerivations == counts, "time within a day is not a cache invalidation")

        status.timeZone = "America/Los_Angeles"
        await store.refreshStatuses()
        check(store.details[kb]?.lastRun?.started == "Yesterday 19:00", "new host zone changes run dates")
        check(store.detailDerivations[kb] == counts[kb]! + 1 && store.detailDerivations[ka] == counts[ka]! + 1, "a host zone applies to all its automations")
        counts = store.detailDerivations
        locale = Locale(identifier: "fr_FR")
        await store.refreshStatuses()
        check(store.details[ka]?.runs.first?.started.contains("sept.") == true, "locale changes invalidate formatted runs")
        check(store.detailDerivations[ka] == counts[ka]! + 1 && store.detailDerivations[kb] == counts[kb]! + 1, "locale invalidates all cached details")

        counts = store.detailDerivations
        deviceZone = TimeZone(identifier: "Asia/Tokyo")!
        await store.refreshStatuses()
        check(store.detailDerivations == counts, "device zone does not reformat dates when the host supplied its own zone")
        now = Date(timeIntervalSince1970: t0 + 29 * 3600) // Sep 25 07:00 UTC: midnight on the host, not the device
        await store.refreshStatuses()
        check(store.details[ka]?.lastRun?.started == store.details[ka]?.runs.first?.started, "host midnight ages Yesterday to the absolute date")
        check(store.detailDerivations[ka] == counts[ka]! + 1 && store.detailDerivations[kb] == counts[kb]! + 1, "host day, not device day, invalidates details")

        counts = store.detailDerivations
        now.addTimeInterval(86_400)
        let resumed = Task { await store.watch() }
        await eventually("watch reentry refreshes dates") { store.detailDerivations[ka] == counts[ka]! + 1 }
        resumed.cancel()
        await resumed.value
        check(store.detailDerivations[kb] == counts[kb]! + 1, "reopening after an offscreen day refreshes every stale detail")
        // A host that never supplies its zone follows the device instead.
        deviceZone = utc
        let unknown = MobileHost(state: ShepherdState(agents: [runAgent], automations: [a]))
        let fallback = AutomationsStore(hosts: MobileHosts(unknown), readRuns: { _, id in runs[id] ?? [] },
                                        dates: { (now, locale, deviceZone) })
        let fallbackKey = AutomationKey(host: unknown.id, automation: a.id)
        await fallback.refresh()
        let fallbackCount = fallback.detailDerivations[fallbackKey]!
        deviceZone = TimeZone(identifier: "Asia/Tokyo")!
        await fallback.refreshStatuses()
        check(fallback.detailDerivations[fallbackKey] == fallbackCount + 1, "unknown host zone invalidates with the device zone")
        check(fallback.details[fallbackKey]?.runs.first?.started.hasSuffix("11:00") == true, "fallback dates use the changed device zone")
        print("PASS: AutomationsStore observation, per-detail reuse, watch run refresh, status, host-day, time-zone and locale invalidation")
    }

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("FAILED: \(message)") }
    }

    @MainActor
    static func eventually(_ message: String, _ ready: () -> Bool) async {
        for _ in 0..<10_000 {
            if ready() { return }
            await Task.yield()
        }
        fatalError("FAILED: bounded wait for \(message)")
    }
}

// These doubles retain MobileHosts' observable value-state/session/capability contract, without
// connecting a transport. The real store owns all projection, run signatures and caching.
@MainActor @Observable
final class MobileHost {
    let id = UUID()
    var name = "Host"
    var state: ShepherdState
    var phase: RemoteHostPhase = .connected
    var session: UUID? = UUID()
    let connectedClient: RemoteHostClient? = RemoteHostClient()
    func supports(_ capability: String) -> Bool {
        [RemoteProtocol.automationsCapability, RemoteProtocol.automationTriggersCapability].contains(capability)
    }
    init(state: ShepherdState) { self.state = state }
}

@MainActor @Observable
final class MobileHosts {
    var hosts: [MobileHost]
    init(_ host: MobileHost) { hosts = [host] }
    func host(_ id: UUID) -> MobileHost? { hosts.first { $0.id == id } }
}

// Screen-only Pause all host-list presentation is outside this store-cache check.
enum AutomationsPauseAll {
    struct Host: Equatable {}
    static func hosts(_ rows: [AutomationListRow]) -> [Host] { [] }
}
