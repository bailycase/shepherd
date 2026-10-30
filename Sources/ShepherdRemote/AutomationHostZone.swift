import Foundation

/// The time zone a host's schedules run in, as a client shows them: the host's own
/// (`AutomationTriggerStatus.timeZone`) when it said, else this device's as a stand-in, said so.
public struct AutomationHostZone: Equatable, Sendable {
    public var timeZone: TimeZone
    /// The host named its zone; else `timeZone` is this device's.
    public var known: Bool

    /// `identifier`: the host's zone as its status (or the last one read from that host) gave it.
    public init(identifier: String?, device: TimeZone = .current) {
        if let identifier, let zone = TimeZone(identifier: identifier) {
            (timeZone, known) = (zone, true)
        } else {
            (timeZone, known) = (device, false)
        }
    }

    /// The calendar schedules are worked out in: Gregorian, in the host's zone.
    public var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// "Eastern Time", the zone's everyday name.
    public func name(locale: Locale = .current) -> String {
        timeZone.localizedName(for: .generic, locale: locale) ?? timeZone.identifier
    }

    /// The editor's line under a schedule. Known and the same as this device's: just the time; known and
    /// another zone: which; unknown: the times are previewed here but run in the host's zone.
    public func footnote(next: String, hostName: String, device: TimeZone = .current, locale: Locale = .current) -> String {
        guard known else { return "Next run \(next). Times are \(hostName)'s time zone." }
        guard timeZone.identifier != device.identifier else { return "Next run \(next)." }
        return "Next run \(next) (\(name(locale: locale)), \(hostName)'s time zone)."
    }

    /// Under a detail's times, when they are another zone's than this device's; nil when they read as local.
    public func note(hostName: String, device: TimeZone = .current, locale: Locale = .current) -> String? {
        guard known, timeZone.identifier != device.identifier else { return nil }
        return "Times are \(name(locale: locale)), \(hostName)'s time zone."
    }
}
