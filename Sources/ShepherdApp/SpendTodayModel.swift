import Foundation
import Observation
import ShepherdCore

/// What the threads this Mac sees spent today, as the Fleet page's header says it: derived once when a thread's spend changes and again
/// when the day does (a timer at the next midnight, with no state push to wake it), never in a view's body.
@MainActor
@Observable
final class SpendTodayModel {
    private(set) var summary: SpendSummary?
    @ObservationIgnored private let read: @MainActor () -> [AgentSpend]
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var spends: [AgentSpend] = []
    @ObservationIgnored private var midnight: Task<Void, Never>?

    /// `read` lists every spend the Mac sees; it is read under observation tracking, so a change in what it reads derives again.
    init(now: @escaping () -> Date = Date.init, read: @escaping @MainActor () -> [AgentSpend]) {
        self.now = now
        self.read = read
        track()
    }

    private func track() {
        let next = withObservationTracking { read() } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.track() }
        }
        if next != spends {
            spends = next
            refresh()
        }
    }

    /// Derives for the day it is now and arms the timer for the next day change.
    func refresh() {
        let value = SpendSummary(spends, now: now())
        if value != summary { summary = value }
        midnight?.cancel()
        let current = now()
        guard let next = SpendDay.nextChange(of: spends, after: current) else { return }
        midnight = Task { [weak self] in
            try? await Task.sleep(for: .seconds(next.timeIntervalSince(current) + 1))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }
}
