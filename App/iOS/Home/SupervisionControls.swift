import SwiftUI
import ShepherdRemote
import ShepherdUI

@MainActor
extension MobileNavigator {
    func openNextNeedingYou(hosts: MobileHosts) {
        let queues = HomeFeed.of(hosts).supervisionQueues
        let selected = selectedThread.map { FleetRef(host: $0.host, agent: $0.agent) }
        guard let next = queues.nextNeedingYou(after: selected) else { return }
        // Repeated jumps replace the thread they leave, not the Home or inbox underneath it.
        if layout == .phone, case .thread? = self[path: tab].last {
            self[path: tab].removeLast()
        }
        open(.thread(next.agentRef))
    }

    func openReviewQueue(hosts: MobileHosts) {
        guard let first = HomeFeed.of(hosts).supervisionQueues.nextReview() else { return }
        openQueuedReview(first.agentRef)
    }

    /// Only advance the queue still visible in this window, and never on a cancelled or failed action.
    @discardableResult
    func finishQueuedReview(_ current: AgentRef, hosts: MobileHosts) -> Bool {
        guard queuedReview == current, selectedThread == current else { return false }
        if layout == .phone {
            guard self[path: tab].last == .review(.changes(current, file: nil)) else { return false }
        } else {
            guard sidePane.isOpen, sidePane.tab == .changes else { return false }
        }
        queuedReview = nil
        let finished = FleetRef(host: current.host, agent: current.agent)
        guard let next = HomeFeed.of(hosts).supervisionQueues.nextReview(excluding: finished) else {
            return false
        }
        openQueuedReview(next.agentRef, replacing: current)
        return true
    }

    private func openQueuedReview(_ ref: AgentRef, replacing current: AgentRef? = nil) {
        if layout == .phone {
            // Give NavigationStack one path update: its review and the thread beneath it change together.
            let target = Tab.landing(of: .thread(ref), from: tab)
            var path = self[path: target]
            if let current {
                path.removeLast()
                if path.last == .thread(current) { path.removeLast() }
            }
            if path.last != .thread(ref) { path.append(.thread(ref)) }
            path.append(.review(.changes(ref, file: nil)))
            self[path: target] = path
            tab = target
        } else {
            ReviewHooks.open(thread: ref, file: nil, navigator: self)
        }
        queuedReview = ref
    }
}

struct NextNeedingYouButton: View {
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator
    var compact = false
    var showsScope = false

    var body: some View {
        let current = navigator.selectedThread.map { FleetRef(host: $0.host, agent: $0.agent) }
        let count = HomeFeed.of(hosts).supervisionQueues.needingYouCount(excluding: current)
        if count > 0 {
            Button { navigator.openNextNeedingYou(hosts: hosts) } label: {
                if compact {
                    HStack(spacing: SH.Space.xs) {
                        SHGlyph.nextThread.image
                        Text("\(count)").monospacedDigit()
                    }
                } else {
                    VStack(spacing: SH.Space.xxs) {
                        Text("Next (\(count))")
                        if showsScope {
                            Text("Waiting, then unseen done").font(.sh(.caption)).foregroundStyle(Color.sh.textSecondary)
                        }
                    }
                }
            }
            .buttonStyle(.sh(.ghost, size: compact ? .s : .l))
            .shTouchTarget(height: SH.Height.controlL)
            .fixedSize()
            .accessibilityLabel("Next thread, \(count) available")
            .accessibilityHint("Opens waiting threads first, then unseen done threads")
        }
    }
}

struct HomeReviewQueueRow: View {
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        let count = HomeFeed.of(hosts).supervisionQueues.review.count
        if count > 0 {
            SHListCard(inset: SHListMetrics.iconInset) {
                Button { navigator.openReviewQueue(hosts: hosts) } label: {
                    SHListRow("Review queue", leading: .symbol(SHGlyph.reviewQueue.symbolName), trailing: .value("\(count) to review"))
                }
                .buttonStyle(.shRow(radius: 0))
            }
        }
    }
}
