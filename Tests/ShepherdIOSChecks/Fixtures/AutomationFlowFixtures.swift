import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import UIKit

// The trigger controls pressed for real, through the accessibility tree as VoiceOver presses them
// (no touches, no focus): Pause then Resume, Run now and Dismiss on waiting events, Edit with a new
// schedule preset and speed then Save, and opening an unread run. build-01 takes exactly those
// changes (`FixtureHostData.accepts`) and the check compares what it received, request by request;
// every other change is still refused as a mutation. Also the sidebar's and Home's run groups.
extension FixtureCatalog {
    static var automationFlow: [FixtureScreen] {
        let loop = AutomationKey(host: FixtureData.buildBox, automation: AutomationsFixtureData.prLoop)
        let settle: @MainActor (MobileApp) async -> Void = { app in await AutomationsStore.of(app.hosts).refresh() }
        let openGroup: @MainActor (MobileApp) async -> Void = { app in
            await settle(app)
            await HomeFeed.of(app.hosts).refresh()
            SidebarThreads.of(app.hosts).toggleRunGroup(loop)
        }
        return [
            FixtureScreen(name: "automation-trigger-flow", hosts: TriggerFlowHost.fleet(),
                          routes: [.home(.automations), .automations(.detail(host: loop.host, automation: loop.automation))],
                          prepare: { app in await settle(app); await TriggerFlowCheck.run(app) }),
            // The lower half of the editor (pins with Speed, the switch) and of the triggered detail (runs, settings).
            FixtureScreen(name: "automation-edit-schedule-lower", hosts: AutomationsFixtureData.triggeredFleet(), routes: [.home(.automations)],
                          presented: .automations(.edit(host: FixtureData.buildBox, automation: AutomationsFixtureData.standup)),
                          prepare: { app in await settle(app); await TriggerFlowCheck.scrollDown(holding: nil) }),
            FixtureScreen(name: "automation-detail-triggered-lower", hosts: AutomationsFixtureData.triggeredFleet(),
                          routes: [.home(.automations), .automations(.detail(host: loop.host, automation: loop.automation))],
                          prepare: { app in await settle(app); await TriggerFlowCheck.scrollDown(holding: "Dismiss:") }),
            // pr-loop's two run threads folded under one row, opened (iPad: run with --sidebar over a thread).
            FixtureScreen(name: "home-run-groups", hosts: AutomationsFixtureData.triggeredFleet(),
                          prepare: { app in await openGroup(app); await TriggerFlowCheck.scrollDown(holding: "pr-loop") }),
            FixtureScreen(name: "sidebar-run-groups", hosts: AutomationsFixtureData.triggeredFleet(),
                          routes: [.thread(FixtureData.ref(FixtureData.preview))],
                          prepare: { app in await openGroup(app); await RunGroupCheck.run(app) }),
        ]
    }
}

/// build-01 for the flow: pr-loop watching with two events waiting, its runs and trigger kept here
/// and changed by what the app sends.
final class TriggerFlowHost: @unchecked Sendable {
    static let shared = TriggerFlowHost()
    private let lock = NSLock()
    private var status: AutomationTriggerStatus
    private var runs: [AutomationRun]

    init() {
        let now = Date().timeIntervalSince1970
        status = AutomationTriggerStatus(state: .active, pending: AutomationsFixtureData.loopPending(now: now),
                                         lastCheckedAt: now - 90, runsToday: 3, timeZone: AutomationsFixtureData.hostZone)
        runs = AutomationsFixtureData.loopRuns(now: now)
    }

    static func fleet() -> [FixtureHostData] {
        AutomationsFixtureData.triggeredFleet().map { host in
            var host = host
            guard host.id == FixtureData.buildBox else { return host }
            let earlier = host.reply
            host.reply = { request in shared.read(request) ?? earlier?(request) }
            host.accepts = { request in shared.change(request) }
            return host
        }
    }

    private func read(_ request: RemoteRequest) -> RemoteReply? {
        guard case .automation(let id, AutomationsFixtureData.prLoop, let command) = request else { return nil }
        return lock.withLock {
            switch command {
            case .status: .automationResult(id: id, result: .status(status))
            case .runs: .automationResult(id: id, result: .runs(runs))
            default: nil
            }
        }
    }

    /// The trigger changes the flow makes, applied as a host would; anything else is not taken.
    private func change(_ request: RemoteRequest) -> RemoteReply? {
        guard case .automation(let id, let automation, let command) = request else { return nil }
        return lock.withLock {
            switch (automation, command) {
            case (AutomationsFixtureData.prLoop, .pause): status.state = .paused
            case (AutomationsFixtureData.prLoop, .resume): status.state = .active
            case (AutomationsFixtureData.prLoop, .runEvent(let event)), (AutomationsFixtureData.prLoop, .dismissEvent(let event)):
                status.pending.removeAll { $0.id == event }
            case (AutomationsFixtureData.prLoop, .markRead(let run)):
                if let index = runs.firstIndex(where: { $0.id == run }) { runs[index].unread = false }
            case (AutomationsFixtureData.standup, .update): break
            default: return nil
            }
            return .automationResult(id: id, result: .ok)
        }
    }
}

@MainActor enum TriggerFlowCheck {
    typealias A = SidebarAutomationsCheck

    static func check(_ ok: Bool, _ what: String) { FixtureCheck.report("FIXTURE CHECK \(ok ? "ok" : "FAILED"): \(what)") }

    static func element(_ label: String, prefix: Bool = false) -> NSObject? {
        A.all.first { element in
            guard let text = element.accessibilityLabel else { return false }
            return prefix ? text.hasPrefix(label) : text == label
        }
    }

    /// Presses the control VoiceOver reads as `label`, once it is drawn.
    static func press(_ label: String, prefix: Bool = false) async {
        await FixtureCheck.wait("\"\(label)\" to be drawn", seconds: 8) { element(label, prefix: prefix) != nil }
        check(element(label, prefix: prefix)?.accessibilityActivate() == true, "pressed \"\(label)\"")
    }

    static func run(_ app: MobileApp) async {
        let store = AutomationsStore.of(app.hosts)
        let loop = AutomationKey(host: FixtureData.buildBox, automation: AutomationsFixtureData.prLoop)
        let standup = AutomationKey(host: FixtureData.buildBox, automation: AutomationsFixtureData.standup)
        let host = FixtureHost.running(FixtureData.buildBox)
        let accepted = { host?.accepted.count ?? 0 }
        A.enableAccessibility()
        await FixtureCheck.wait("pr-loop's trigger and waiting events", seconds: 8) {
            store.details[loop]?.trigger?.state != nil && store.details[loop]?.trigger?.pending.count == 2
        }
        // Each press waits for the host's answer and the reread it causes before the next.
        func settled(_ count: Int, _ what: String, until: @escaping () -> Bool) async {
            await FixtureCheck.wait(what, seconds: 8) { accepted() == count && !store.busy.contains(loop) && until() }
        }
        await press("Pause")
        await settled(1, "the trigger to pause") { store.details[loop]?.trigger?.state?.paused == true }
        await press("Resume")
        await settled(2, "the trigger to resume") { store.details[loop]?.trigger?.state?.paused == false }
        let events = AutomationsFixtureData.loopPending(now: 0)
        await press("Run now: \(events[0].summary)")
        await settled(3, "the first event to leave the inbox") { store.details[loop]?.trigger?.pending.count == 1 }
        await press("Dismiss: \(events[1].summary)")
        await settled(4, "the second event to leave the inbox") { store.details[loop]?.trigger?.pending.isEmpty == true }

        // The standup's editor: Weekdays becomes Daily, Speed becomes Fast, then Save.
        app.navigator.open(.automations(.detail(host: standup.host, automation: standup.automation)))
        await FixtureCheck.wait("the standup's detail", seconds: 5) { element("Next run", prefix: true) != nil || store.details[standup] != nil }
        try? await Task.sleep(for: .seconds(1))
        await press("Edit")
        await FixtureCheck.wait("the editor", seconds: 5) { app.navigator.presented != nil }
        try? await Task.sleep(for: .seconds(1))
        await choose("Daily", in: "Repeats")
        scroll(holding: "Repeats")
        await choose("Fast", in: "Speed")
        await press("Save")
        await FixtureCheck.wait("the edit to be saved and the editor to close", seconds: 8) { accepted() == 5 && app.navigator.presented == nil }

        // An unread run opened from pr-loop's inbox: its thread opens and its dot clears.
        app.navigator.open(.automations(.detail(host: loop.host, automation: loop.automation)))
        try? await Task.sleep(for: .seconds(1))
        let unread = AutomationsFixtureData.loopRuns(now: 0)[1]
        await press("Unread, \(unread.trigger!)", prefix: true)
        await FixtureCheck.wait("the run's thread to open and its dot to clear", seconds: 8) {
            accepted() == 6 && app.navigator.selectedThread == AgentRef(host: loop.host, agent: AutomationsFixtureData.loopDone)
                && store.details[loop]?.runs.contains { $0.id == unread.id && !$0.unread } == true
        }

        // Exactly these changes, in this order, and nothing else.
        let sent = (host?.accepted ?? []).map { request -> String in
            guard case .automation(_, let automation, let command) = request else { return "other: \(request)" }
            return "\(automation.rawValue) \(command)"
        }
        guard let row = store.model.row(standup) else { return check(false, "the standup is still listed") }
        var form = AutomationTriggerForm(row.settings)
        form.scheduleKind = .daily
        form.speed = ServiceTier.fast.rawValue
        let draft = RemoteAutomationDraft(name: row.name, prompt: row.prompt, cwd: row.cwd, enabled: row.enabled, settings: form.settings)
        let expected: [(AutomationID, RemoteAutomationRequest)] = [
            (loop.automation, .pause), (loop.automation, .resume),
            (loop.automation, .runEvent(eventID: events[0].id)), (loop.automation, .dismissEvent(eventID: events[1].id)),
            (standup.automation, .update(draft: draft)), (loop.automation, .markRead(runID: unread.id)),
        ]
        let got = (host?.accepted ?? []).compactMap { request -> (AutomationID, RemoteAutomationRequest)? in
            if case .automation(_, let automation, let command) = request { return (automation, command) } else { return nil }
        }
        for (index, want) in expected.enumerated() {
            let ok = got.indices.contains(index) && got[index].0 == want.0 && got[index].1 == want.1
            check(ok, "request \(index + 1): \(want.0.rawValue) \(want.1)\(ok ? "" : " (got \(sent.indices.contains(index) ? sent[index] : "nothing"))")")
        }
        check(sent.count == expected.count, "build-01 took \(expected.count) changes and no more\(sent.count == expected.count ? "" : " (\(sent))")")
        check(form.settings.trigger == .schedule(AutomationSchedule(rrule: "FREQ=DAILY;BYHOUR=9;BYMINUTE=0")) && form.settings.serviceTier == "fast",
              "the saved trigger is Daily at 09:00, Fast")
    }

    /// Opens a form picker's menu and picks `option`: the picker then reads "Repeats, Daily". UIKit's menu cell takes
    /// no accessibility activation in the simulator, so the item's own UIAction (the handler a tap runs) is performed,
    /// then the menu is escaped as VoiceOver's two-finger scrub does.
    static func choose(_ option: String, in picker: String) async {
        await press(picker, prefix: true)
        await FixtureCheck.wait("\(picker)'s menu", seconds: 5) { A.all.contains { $0.accessibilityLabel == option && $0 is UIView } }
        try? await Task.sleep(for: .milliseconds(500))
        let item = A.all.first { $0.accessibilityLabel == option && $0.accessibilityTraits.contains(.button) } as? UIView
        var pressed = item?.accessibilityActivate() == true
        if !pressed, let item, let action = menuAction(for: item) {
            let perform = NSSelectorFromString("performWithSender:target:")
            if action.responds(to: perform) {
                _ = action.perform(perform, with: nil, with: nil)
                pressed = true
            }
            var container: UIView? = item
            while let current = container, NSStringFromClass(type(of: current)) != "_UIContextMenuContainerView" { container = current.superview }
            _ = container?.accessibilityPerformEscape()
        }
        check(pressed, "picked \"\(option)\" in \(picker)'s menu")
        await FixtureCheck.wait("\(picker) to read \(option)", seconds: 5) { element("\(picker), \(option)") != nil }
        try? await Task.sleep(for: .milliseconds(800))
    }

    /// Scrolls the list holding the control read as `label` (prefix) toward its end, as a swipe would: a form's lower
    /// rows are made only once on screen. Returns the list, to scroll again once it knows more of its length.
    @discardableResult
    static func scroll(holding label: String) -> UIScrollView? {
        guard let target = element(label, prefix: true) else { check(false, "\(label) to scroll from"); return nil }
        // SwiftUI's elements are not views: the list is the innermost scroll view under the element's frame.
        let point = CGPoint(x: target.accessibilityFrame.midX, y: target.accessibilityFrame.midY)
        var lists: [UIScrollView] = []
        func collect(_ view: UIView) {
            if let list = view as? UIScrollView, !view.isHidden, list.contentSize.height > 0 { lists.append(list) }
            view.subviews.forEach(collect)
        }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) { scene.windows.forEach(collect) }
        // Below the fold the element is outside every frame: then the longest list on screen.
        guard let list = lists.last(where: { $0.convert($0.bounds, to: nil).contains(point) })
                ?? lists.max(by: { $0.contentSize.height < $1.contentSize.height }) else { check(false, "a list holding \(label)"); return nil }
        // A lazily measured list may not know its full length yet: at least bring the element near the top.
        toEnd(list, atLeast: list.contentOffset.y + point.y - (list.window?.bounds.height ?? 0) * 0.3)
        return list
    }

    static func toEnd(_ list: UIScrollView, atLeast: CGFloat = -.greatestFiniteMagnitude) {
        let end = max(-list.adjustedContentInset.top, list.contentSize.height - list.bounds.height + list.adjustedContentInset.bottom)
        list.setContentOffset(CGPoint(x: 0, y: max(end, atLeast)), animated: false)
        list.layoutIfNeeded()
    }

    /// For a screenshot of a screen's lower half: the list holding `label`, else (nil) the longest one on screen.
    static func scrollDown(holding label: String?) async {
        A.enableAccessibility()
        let list: UIScrollView?
        if let label {
            await FixtureCheck.wait("\(label) to be drawn", seconds: 20) { element(label, prefix: true) != nil }
            list = scroll(holding: label)
        } else {
            try? await Task.sleep(for: .seconds(1))
            var lists: [UIScrollView] = []
            func collect(_ view: UIView) {
                if let list = view as? UIScrollView, !view.isHidden { lists.append(list) }
                view.subviews.forEach(collect)
            }
            for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) { scene.windows.forEach(collect) }
            list = lists.max { $0.contentSize.height < $1.contentSize.height }
            if let list { toEnd(list) } else { check(false, "a list to scroll") }
        }
        guard let list else { return }
        // A lazy list learns its length as it scrolls: again until it stops growing.
        for _ in 0..<4 {
            try? await Task.sleep(for: .milliseconds(400))
            toEnd(list)
        }
        try? await Task.sleep(for: .milliseconds(400))
    }

    /// The UIAction behind a context menu's cell (its list maps index paths to menu elements).
    static func menuAction(for item: UIView) -> NSObject? {
        var view: UIView? = item
        while let current = view, !(current is UICollectionViewCell) { view = current.superview }
        guard let cell = view as? UICollectionViewCell else { return nil }
        var list: UIView? = cell.superview
        while let current = list, !(current is UICollectionView) { list = current.superview }
        var menu: UIView? = list
        while let current = menu, NSStringFromClass(type(of: current)) != "_UIContextMenuListView" { menu = current.superview }
        let lookup = NSSelectorFromString("elementAtIndexPath:")
        guard let collection = list as? UICollectionView, let path = collection.indexPath(for: cell), let menu, menu.responds(to: lookup) else { return nil }
        return menu.perform(lookup, with: path)?.takeUnretainedValue() as? NSObject
    }
}

/// The sidebar's run group as VoiceOver reads and presses it.
@MainActor enum RunGroupCheck {
    static func run(_ app: MobileApp) async {
        func check(_ ok: Bool, _ what: String) { FixtureCheck.report("FIXTURE CHECK \(ok ? "ok" : "FAILED"): \(what)") }
        let loop = AutomationKey(host: FixtureData.buildBox, automation: AutomationsFixtureData.prLoop)
        let sidebar = SidebarThreads.of(app.hosts)
        let store = AutomationsStore.of(app.hosts)
        let groups = { sidebar.groups(HomeFeed.of(app.hosts).model, unread: store.unreadRuns, paused: store.pausedTriggers) }
        await FixtureCheck.wait("pr-loop's group with its unread run", seconds: 8) { groups().runs.first?.unread == 1 }
        let group = groups().runs.first
        check(group?.key == loop && group?.count == 2 && group?.rollup == .running && group?.paused == true,
              "pr-loop's two runs fold under one row, running and paused (\(String(describing: group)))")
        check(groups().working.allSatisfy { $0.ref.agent != AutomationsFixtureData.loopRun }
              && groups().recents.allSatisfy { $0.ref.agent != AutomationsFixtureData.loopDone }, "its runs are not loose rows")
        SidebarAutomationsCheck.enableAccessibility()
        try? await Task.sleep(for: .seconds(1))
        let header = SidebarAutomationsCheck.all.first { $0.accessibilityLabel?.hasPrefix("pr-loop · build-01, automation, 2 runs") == true }
        check(header?.accessibilityLabel?.contains("1 unread") == true && header?.accessibilityLabel?.contains("paused") == true,
              "the row reads its runs, unread and pause (\(String(describing: header?.accessibilityLabel)))")
        // Close and open it again the way VoiceOver presses it.
        check(header?.accessibilityActivate() == true && groups().runs.first?.expanded == false, "pressing the row closes it")
        _ = header?.accessibilityActivate()
        check(groups().runs.first?.expanded == true, "pressing it again opens it")
    }
}
