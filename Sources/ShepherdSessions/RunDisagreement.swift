/// How long a thread has served `running` while its agent's status says it is not working (`SessionServer.logRunDisagreement`).
/// A new run's first moments look like this too, so only a disagreement that lasts is worth a warning. Any status or run change
/// starts the count over: two sampled mismatches are one disagreement only if nothing moved between them.
struct RunDisagreement {
    static let threshold: Duration = .seconds(5)
    private(set) var since: ContinuousClock.Instant?
    private var warned = false

    mutating func reset() {
        since = nil
        warned = false
    }

    /// True once per disagreement, when it has lasted past the threshold.
    mutating func shouldWarn(disagrees: Bool, now: ContinuousClock.Instant = .now) -> Bool {
        guard disagrees else {
            reset()
            return false
        }
        let start = since ?? now
        since = start
        guard !warned, start.duration(to: now) > Self.threshold else { return false }
        warned = true
        return true
    }

    func seconds(now: ContinuousClock.Instant = .now) -> Int { since.map { Int($0.duration(to: now).components.seconds) } ?? 0 }
}
