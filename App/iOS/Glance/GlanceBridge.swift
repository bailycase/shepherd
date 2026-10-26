import ActivityKit
import Foundation
import Observation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI
import WidgetKit

/// Publishes every host's work to the glance surfaces (docs/design/notifications.md › Glance):
/// the widgets' snapshot, the Watch Live Activity and any thread being followed. It reads Home's
/// feed while the app is in front and stops when it leaves; what it published last then goes
/// stale on its own (`SHGlance.staleAfter`), so no surface shows a frozen spinner as live.
/// It also runs the surfaces' buttons (`GlanceActions`) and their links.
@MainActor
final class GlanceBridge {
    private let hosts: MobileHosts
    private let windows: MobileWindows
    private let feed: HomeFeed
    private var glance: SHGlance?
    private var poll: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    /// The person swiped the Watch away: it stays gone until nothing runs.
    private var watchDismissed = false
    /// A forced publish waits for the hosts to settle (back in front, a heartbeat): what the
    /// surfaces show must be marked fresh even when nothing in it changed.
    private var forcePending = false

    /// While in front, the snapshot is republished this often so its stale time moves on.
    static let heartbeatInterval: Duration = .seconds(60)
    /// How long a Watch with nothing left running stays on the Lock Screen.
    static let quietLinger: TimeInterval = 15 * 60

    init(hosts: MobileHosts, windows: MobileWindows) {
        self.hosts = hosts
        self.windows = windows
        feed = HomeFeed.of(hosts)
        glance = GlanceStore.read()
        GlanceActions.handler = { [weak self] command in
            guard let self else { throw GlanceFailure("Open Shepherd and try again.") }
            try await self.perform(command)
        }
        hosts.onForegroundChanged = { [weak self] active in self?.setForeground(active) }
        for activity in Activity<WatchActivity>.activities { watchDismissal(activity) }
        track()
    }

    // MARK: Publishing

    private func setForeground(_ active: Bool) {
        poll?.cancel()
        heartbeat?.cancel()
        poll = nil
        heartbeat = nil
        guard active else { return }
        // Home's feed reads the threads that run or wait only while someone watches it.
        poll = Task { [feed] in await feed.watch() }
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.heartbeatInterval)
                self?.publish(force: true)
            }
        }
        publish(force: true)
    }

    private func track() {
        withObservationTracking {
            _ = feed.model
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.track() }
        }
        publish(force: false)
    }

    /// Writes the snapshot and updates the activities, when something changed or `force`. Only
    /// in front: in the background the hosts are disconnected and Home's model is empty, which
    /// is not news.
    private func publish(force: Bool) {
        guard hosts.foreground else { return }
        if force { forcePending = true }
        // A host still connecting (the app just came to the front, or just launched) is no news:
        // its threads would read as gone and end the Watch.
        let model = feed.model
        guard !model.hosts.contains(where: { $0.phase == .connecting || $0.phase == .disconnected }) else { return }
        let next = Self.glance(model, now: Date())
        let changed = glance.map { $0.items != next.items || $0.hosts != next.hosts } ?? true
        guard changed || forcePending else { return }
        forcePending = false
        glance = next
        GlanceStore.write(next)
        WidgetCenter.shared.reloadAllTimelines()
        Task { await syncActivities(next) }
    }

    private func syncActivities(_ glance: SHGlance) async {
        let stale = glance.updated.addingTimeInterval(SHGlance.staleAfter)
        let content = ActivityContent(state: glance.forActivity(), staleDate: stale,
                                      relevanceScore: glance.count(.needsYou) > 0 ? 100 : 50)
        let watches = Activity<WatchActivity>.activities.filter { $0.activityState == .active || $0.activityState == .stale }
        if glance.isQuiet {
            watchDismissed = false
            for watch in watches { await watch.end(content, dismissalPolicy: .after(Date().addingTimeInterval(Self.quietLinger))) }
        } else if let watch = watches.first {
            await watch.update(content)
            // One Watch: any other (a launch before this one started its own) goes.
            for extra in watches.dropFirst() { await extra.end(nil, dismissalPolicy: .immediate) }
        } else if !watchDismissed, hosts.foreground, ActivityAuthorizationInfo().areActivitiesEnabled,
                  let watch = try? Activity.request(attributes: WatchActivity(), content: content) {
            watchDismissal(watch)
        }
        for follow in Activity<FollowActivity>.activities where follow.activityState == .active || follow.activityState == .stale {
            guard let item = followed(follow.attributes.item) else {
                await follow.end(nil, dismissalPolicy: .immediate)
                continue
            }
            let one = ActivityContent(state: SHGlance(items: [item], hosts: glance.hosts, updated: glance.updated).forActivity(kept: 1),
                                      staleDate: stale)
            if item.state == .done || item.state == .failed {
                await follow.end(one, dismissalPolicy: .default)
            } else {
                await follow.update(one)
            }
        }
    }

    /// Notices the person swiping the Watch away while work still runs.
    private func watchDismissal(_ activity: Activity<WatchActivity>) {
        Task { [weak self] in
            for await state in activity.activityStateUpdates where state == .dismissed {
                guard let self, self.glance?.isQuiet == false else { continue }
                self.watchDismissed = true
            }
        }
    }

    // MARK: Follow

    func isFollowing(_ ref: AgentRef) -> Bool {
        Activity<FollowActivity>.activities.contains { $0.attributes.item == Self.id(ref) && $0.activityState == .active }
    }

    /// Puts one thread on the Lock Screen, in full, until it ends or the person stops following.
    func follow(_ ref: AgentRef) {
        guard !isFollowing(ref), let item = followed(Self.id(ref)) else { return }
        let glance = SHGlance(items: [item], hosts: glance?.hosts ?? [], updated: Date())
        _ = try? Activity.request(attributes: FollowActivity(item: item.id),
                                  content: ActivityContent(state: glance.forActivity(kept: 1),
                                                           staleDate: glance.updated.addingTimeInterval(SHGlance.staleAfter)))
    }

    func unfollow(_ ref: AgentRef) {
        let id = Self.id(ref)
        Task {
            for follow in Activity<FollowActivity>.activities where follow.attributes.item == id {
                await follow.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    /// The followed thread as Home last read it, whatever its state.
    private func followed(_ id: String) -> SHGlance.Item? {
        let model = feed.model
        if let asking = model.needsYou.first(where: { Self.id($0.ref) == id }) { return Self.item(asking) }
        return model.recents.first { Self.id($0.ref) == id }.map(Self.item)
    }

    // MARK: Buttons and links

    private func perform(_ command: GlanceCommand) async throws {
        switch command {
        case .answer(let host, let agent, let dialogID, let session, let option, let confirms):
            let answer: NativeDialogAnswer = confirms ? .confirm(value: option == "Yes") : .select(value: option)
            try await send(host: host, agent: agent, .answer(expectedSessionID: session.piSessionID, generation: session.generation,
                                                             operationID: UUID(), dialogID: dialogID, answer: answer))
        case .stop(let host, let agent, let session):
            try await send(host: host, agent: agent, .abort(expectedSessionID: session.piSessionID, generation: session.generation,
                                                            operationID: UUID()))
        case .open(let url):
            guard let navigator = windows.open.first?.navigator else { throw GlanceFailure("Open Shepherd and try again.") }
            Self.open(url, navigator: navigator)
        }
    }

    /// Sends to the thread's own host: over its connection while the app is in front, else over
    /// one made for this request and closed after it.
    private func send(host: String, agent: String, _ request: NativeThreadRequest) async throws {
        guard let id = UUID(uuidString: host), let mobile = hosts.host(id) else {
            throw GlanceFailure("That host is no longer on this device.")
        }
        let client: RemoteHostClient
        var owned = false
        if let connected = mobile.connectedClient {
            client = connected
        } else {
            guard let token = try hosts.token(for: id), !token.isEmpty else {
                throw GlanceFailure("Open Shepherd to reconnect to \(mobile.name).")
            }
            client = RemoteHostClient()
            owned = true
            do {
                _ = try await client.connect(host: mobile.record.address, port: mobile.record.port, token: token, clientName: "Shepherd iOS")
            } catch {
                client.disconnect()
                throw GlanceFailure("\(mobile.name) is unreachable.")
            }
        }
        defer { if owned { client.disconnect() } }
        let result = try await client.nativeThread(agentID: AgentID(rawValue: agent), request: request)
        if case .failure(_, let message) = result { throw GlanceFailure(message) }
        if hosts.foreground { Task { await feed.refresh() } }
    }

    /// Opens what a `shepherd://` link names in `navigator`'s window. False for any other link.
    @discardableResult
    static func open(_ url: URL, navigator: MobileNavigator) -> Bool {
        switch GlanceLink(url) {
        case .thread(let host, let agent): navigator.open(.thread(AgentRef(host: host, agent: AgentID(rawValue: agent))))
        case .review(let host, let agent): navigator.open(.review(.changes(AgentRef(host: host, agent: AgentID(rawValue: agent)), file: nil)))
        case .needsYou: navigator.open(.home(.needsYou))
        case .newThread: NewThreadHooks.open(navigator: navigator)
        case nil: return false
        }
        return true
    }

    // MARK: From Home's model

    static func id(_ ref: FleetRef) -> String { "\(ref.host.uuidString)/\(ref.agent.rawValue)" }
    static func id(_ ref: AgentRef) -> String { "\(ref.host.uuidString)/\(ref.agent.rawValue)" }

    /// Every host's work as the glance surfaces draw it: what needs you, what failed or finished
    /// today, what runs (threads and automation runs), and which hosts this device reaches.
    static func glance(_ model: FleetModel, now: Date, calendar: Calendar = .current) -> SHGlance {
        var items = model.needsYou.map(item)
        var ids = Set(items.map(\.id))
        func today(_ date: Date?) -> Bool { date.map(calendar.isDateInToday) ?? false }
        for row in model.recents where !row.offline && row.design == nil && !ids.contains(id(row.ref)) {
            let item = item(row)
            if item.state == .running || today(item.since) {
                items.append(item)
                ids.insert(item.id)
            }
        }
        for automation in model.automationsRunning where automation.runStatus == .working {
            guard let run = automation.run, !ids.contains(id(run)) else { continue }
            items.append(SHGlance.Item(host: run.host.uuidString, agent: run.agent.rawValue, title: automation.name,
                                       state: .running, hostName: automation.hostName, automation: automation.name))
        }
        return SHGlance(items: items, hosts: model.hosts.map { .init(name: $0.name, online: $0.phase.isConnected) }, updated: now)
    }

    static func item(_ attention: FleetAttention) -> SHGlance.Item {
        var options: [String] = []
        var confirms = false
        if attention.origin != .project {
            switch attention.reply {
            case .choose(let choices): options = choices
            case .confirm:
                options = ["Yes", "No"]
                confirms = true
            case .open: break
            }
        }
        let title: String = if case .automation(let name) = attention.origin { name } else { attention.thread }
        return SHGlance.Item(
            host: attention.ref.host.uuidString, agent: attention.ref.agent.rawValue, title: title, state: .needsYou,
            hostName: attention.hostName, since: attention.since.map(date), tag: attention.reason, question: attention.question,
            options: options, confirms: confirms, dialogID: attention.dialogID,
            session: attention.session.map { SHGlance.Session(piSessionID: $0.piSessionID, generation: $0.generation) })
    }

    static func item(_ row: FleetThreadRow) -> SHGlance.Item {
        let state: SHGlance.State = switch row.status {
        case .working: .running
        case .blocked: .needsYou
        case .idle, .done: row.failed ? .failed : .done
        }
        let since: Date? = switch row.clock {
        case .elapsed(let at): date(at)
        case .ago(let at): date(at)
        case nil: nil
        }
        let subagents = row.subagents + row.subagentsDone > 0
            ? SHGlance.Subagents(running: row.subagents - row.subagentsAsking, waiting: row.subagentsAsking, done: row.subagentsDone)
            : nil
        return SHGlance.Item(
            host: row.ref.host.uuidString, agent: row.ref.agent.rawValue, title: row.title, state: state, hostName: row.hostName,
            since: since, session: row.session.map { SHGlance.Session(piSessionID: $0.piSessionID, generation: $0.generation) },
            command: state == .running ? row.activity : nil, result: state == .running ? nil : row.result, subagents: subagents,
            changes: row.changes.map { SHGlance.Changes(files: $0.files, added: $0.added, removed: $0.removed) },
            queued: row.queued, goal: row.goal)
    }

    /// Milliseconds since 1970 as a date.
    private static func date(_ milliseconds: Double) -> Date { Date(timeIntervalSince1970: milliseconds / 1000) }
}
