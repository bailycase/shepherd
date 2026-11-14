import Foundation

/// The CPU readings of the last `FleetRoom.cpuWindow` seconds, averaged: one reading is 200 ms of a Mac that a build or a test run
/// can spike for a few seconds, and a dispatch is a decision that lasts for minutes. A plain mean of the readings in the window
/// (they come every five seconds while anything wants them, so they are evenly spread); a reading is dropped when it falls out.
public struct FleetCPUAverage: Sendable, Equatable {
    private var readings: [(at: Date, share: Double)] = []
    public let window: TimeInterval

    public init(window: TimeInterval = FleetRoom.cpuWindow) { self.window = window }

    public static func == (a: FleetCPUAverage, b: FleetCPUAverage) -> Bool {
        a.window == b.window && a.readings.count == b.readings.count && zip(a.readings, b.readings).allSatisfy { $0.at == $1.at && $0.share == $1.share }
    }

    /// Takes a reading (clamped to 0...1) and answers the average of the window it ends.
    @discardableResult
    public mutating func add(_ share: Double, at now: Date) -> Double {
        readings.removeAll { now.timeIntervalSince($0.at) >= window || $0.at > now }
        readings.append((now, share.isFinite ? min(1, max(0, share)) : 0))
        return readings.reduce(0) { $0 + $1.share } / Double(readings.count)
    }

    public var count: Int { readings.count }
}

/// What a provider's rate limit is, said by pi's error text: when to try again, and how long a Mac holds new work for that provider.
public enum FleetProviderLimits {
    /// How long new work for a provider waits when the error names no time.
    public static let defaultHold: TimeInterval = 60
    /// The longest a limit is held for, whatever the error says (a provider's daily cap is not a reason to stop a fleet for hours; the
    /// next error marks it again).
    public static let maxHold: TimeInterval = 15 * 60
    /// The shortest (a "retry in 0s" is no limit at all).
    public static let minHold: TimeInterval = 1

    /// How long to hold for: what the error asks for, kept within the bounds; `defaultHold` when it names no time.
    public static func hold(retryAfter: TimeInterval?) -> TimeInterval {
        guard let retryAfter, retryAfter.isFinite else { return defaultHold }
        return min(maxHold, max(minHold, retryAfter))
    }

    /// The wait an error asks for, in seconds: "retry-after: 30", "retry after 30 seconds", "try again in 1m 40s", "retry in 8s",
    /// `"retryDelay": "20s"`. A bare number after the label is seconds. Nil when the text names none.
    public static func retryAfter(in text: String) -> TimeInterval? {
        let ns = text as NSString
        guard let label = labelPattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        var cursor = NSString(string: String(ns.substring(from: NSMaxRange(label.range)).prefix(60)))
        var total: TimeInterval = 0
        var found = false
        // The parts of one span ("1m 40s", "1 minute and 40 seconds") follow each other; anything else ends it.
        while let part = durationPattern.firstMatch(in: cursor as String, options: .anchored, range: NSRange(location: 0, length: cursor.length)),
              let value = Double(cursor.substring(with: part.range(at: 1))) {
            let unit = part.range(at: 2).location == NSNotFound ? "" : cursor.substring(with: part.range(at: 2)).lowercased()
            total += value * seconds(perUnit: unit)
            found = true
            cursor = NSString(string: cursor.substring(from: NSMaxRange(part.range)))
        }
        return found ? total : nil
    }

    private static func seconds(perUnit unit: String) -> Double {
        switch unit {
        case "ms", "millisecond", "milliseconds": 0.001
        case "m", "min", "mins", "minute", "minutes": 60
        case "h", "hr", "hrs", "hour", "hours": 3600
        default: 1
        }
    }

    private static let labelPattern = try! NSRegularExpression(
        pattern: #"(?:retry[-_ ]?after|retry[-_ ]?delay|try again in|retry(?:ing)? in|resets? in)["':=\s]*"#, options: [.caseInsensitive])
    private static let durationPattern = try! NSRegularExpression(
        pattern: #"\s*(?:and\s+)?(\d+(?:\.\d+)?)\s*(ms|milliseconds?|seconds?|secs?|minutes?|mins?|hours?|hrs?|h|m|s)?\b"#, options: [.caseInsensitive])
}
