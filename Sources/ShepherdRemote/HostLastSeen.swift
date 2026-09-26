import Foundation

/// When this device last had a host connected, as the phone words it for a host it cannot reach
/// now (MobileMore's "Last seen today 07:12", MobileWorkspace's "last seen 07:12"). The client
/// keeps the moment a connection ended; the host reports nothing.
public enum HostLastSeen {
    /// "today 7:12 AM", "yesterday 6:40 PM", or the day ("Sep 20").
    public static func text(_ seen: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let time = seen.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar,
                                                   timeZone: calendar.timeZone))
        if calendar.isDate(seen, inSameDayAs: now) { return "today \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(seen, inSameDayAs: yesterday) {
            return "yesterday \(time)"
        }
        return day(seen, now: now, calendar: calendar, locale: locale)
    }

    /// The same, without "today": a row's detail after "unreachable ·" ("last seen 7:12 AM").
    public static func short(_ seen: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        guard calendar.isDate(seen, inSameDayAs: now) else { return text(seen, now: now, calendar: calendar, locale: locale) }
        return seen.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar,
                                               timeZone: calendar.timeZone))
    }

    private static func day(_ seen: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .month(.abbreviated).day()
        if !calendar.isDate(seen, equalTo: now, toGranularity: .year) { style = style.year() }
        return seen.formatted(style)
    }
}
