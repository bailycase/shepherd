import SwiftUI

/// Durations as the boards write them: short ("48s", "37m", "2h", "3d") for rows, ledgers,
/// sidebar times and waits; long ("48s", "4m 02s", "1h 02m") where a precise figure helps.
public enum SHDuration {
    public enum Style: Sendable { case short, long }

    public static func text(_ seconds: TimeInterval, _ style: Style = .short) -> String {
        let whole = Int(max(0, seconds))
        switch style {
        case .short:
            if whole < 60 { return "\(whole)s" }
            if whole < 3600 { return "\(whole / 60)m" }
            if whole < 86_400 { return "\(whole / 3600)h" }
            return "\(whole / 86_400)d"
        case .long:
            if whole < 60 { return "\(whole)s" }
            if whole < 3600 { return String(format: "%dm %02ds", whole / 60, whole % 60) }
            return String(format: "%dh %02dm", whole / 3600, (whole % 3600) / 60)
        }
    }

    /// How long the text for `seconds` stays the same: the step between its changes.
    static func step(at seconds: TimeInterval, _ style: Style) -> TimeInterval {
        switch style {
        case .short: seconds < 60 ? 1 : seconds < 3600 ? 60 : seconds < 86_400 ? 3600 : 86_400
        case .long: seconds < 3600 ? 1 : 60
        }
    }
}

/// Ticks exactly when an elapsed figure's text changes, anchored to the moment it counts from:
/// every second for the first minute, then on each whole minute (or hour) since `start`.
///
/// `aligned` moves each tick to the next whole second of the clock, so figures counting from
/// different moments tick together and one update redraws them all; a figure then changes up to a
/// second late. `paused` gives the moment the timeline starts (the figure is current) and nothing
/// after, for a clock nobody can see; the timeline starts over when it is false again.
public struct SHElapsedSchedule: TimelineSchedule, Sendable, Equatable {
    public let start: Date
    public let style: SHDuration.Style
    public let aligned: Bool
    public let paused: Bool

    public init(start: Date, style: SHDuration.Style = .short, aligned: Bool = false, paused: Bool = false) {
        self.start = start
        self.style = style
        self.aligned = aligned
        self.paused = paused
    }

    public func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        Entries(schedule: self, upcoming: startDate)
    }

    /// The first moment after `date` at which the text changes (aligned: the whole second at or
    /// after it).
    public func boundary(after date: Date) -> Date {
        let elapsed = max(0, date.timeIntervalSince(start))
        let step = SHDuration.step(at: elapsed, style)
        let next = start.addingTimeInterval((floor(elapsed / step) + 1) * step)
        guard aligned else { return next }
        return Date(timeIntervalSinceReferenceDate: next.timeIntervalSinceReferenceDate.rounded(.up))
    }

    public struct Entries: Sequence, IteratorProtocol, Sendable {
        let schedule: SHElapsedSchedule
        var upcoming: Date
        var exhausted = false

        public mutating func next() -> Date? {
            guard !exhausted else { return nil }
            let current = upcoming
            if schedule.paused { exhausted = true } else { upcoming = schedule.boundary(after: current) }
            return current
        }
    }
}

/// An elapsed figure ("2m", "37m 21s"). While `until` is nil it counts live, and only this text
/// re-renders, on `SHElapsedSchedule`'s ticks; once `until` is set it is static.
public struct SHElapsedText: View {
    let since: Date
    let until: Date?
    let style: SHDuration.Style

    public init(since: Date, until: Date? = nil, style: SHDuration.Style = .short) {
        self.since = since
        self.until = until
        self.style = style
    }

    public var body: some View {
        if let until {
            label(until)
        } else {
            TimelineView(SHElapsedSchedule(start: since, style: style)) { context in
                label(context.date)
            }
        }
    }

    private func label(_ now: Date) -> some View {
        Text(SHDuration.text(now.timeIntervalSince(since), style)).monospacedDigit()
    }
}
