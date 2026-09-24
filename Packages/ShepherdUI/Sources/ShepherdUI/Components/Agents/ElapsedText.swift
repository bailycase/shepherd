import SwiftUI

/// Durations as the boards write them: short ("48s", "37m", "2h", "3d") for rows, ledgers,
/// sidebar times and waits; long ("48s", "4m 02s", "1h 02m") where a precise figure helps.
public enum NWDuration {
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
public struct NWElapsedSchedule: TimelineSchedule, Sendable {
    public let start: Date
    public let style: NWDuration.Style

    public init(start: Date, style: NWDuration.Style = .short) {
        self.start = start
        self.style = style
    }

    public func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        Entries(start: start, style: style, upcoming: startDate)
    }

    /// The first moment after `date` at which the text changes.
    public func boundary(after date: Date) -> Date {
        let elapsed = max(0, date.timeIntervalSince(start))
        let step = NWDuration.step(at: elapsed, style)
        return start.addingTimeInterval((floor(elapsed / step) + 1) * step)
    }

    public struct Entries: Sequence, IteratorProtocol, Sendable {
        let start: Date
        let style: NWDuration.Style
        var upcoming: Date

        public mutating func next() -> Date? {
            let current = upcoming
            upcoming = NWElapsedSchedule(start: start, style: style).boundary(after: current)
            return current
        }
    }
}

/// An elapsed figure ("2m", "37m 21s"). While `until` is nil it counts live, and only this text
/// re-renders, on `NWElapsedSchedule`'s ticks; once `until` is set it is static.
public struct NWElapsedText: View {
    let since: Date
    let until: Date?
    let style: NWDuration.Style

    public init(since: Date, until: Date? = nil, style: NWDuration.Style = .short) {
        self.since = since
        self.until = until
        self.style = style
    }

    public var body: some View {
        if let until {
            label(until)
        } else {
            TimelineView(NWElapsedSchedule(start: since, style: style)) { context in
                label(context.date)
            }
        }
    }

    private func label(_ now: Date) -> some View {
        Text(NWDuration.text(now.timeIntervalSince(since), style)).monospacedDigit()
    }
}
