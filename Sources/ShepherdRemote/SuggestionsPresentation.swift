import Foundation
import ShepherdProtocol

/// Settings ▸ Experiments ▸ Suggested instructions' words, shared by the Mac, the iPhone and the
/// iPad: where a suggestion came from and when, since when the experiment has been on, and what
/// was added.
public enum SuggestionsPresentation {
    /// "on since Sep 12": the experiment's tag while it is on.
    public static func sinceTag(_ settings: SuggestedInstructionsSettings, locale: Locale = .current,
                                timeZone: TimeZone = .current) -> String? {
        guard settings.enabled, let since = settings.since else { return nil }
        return "on since \(InstructionsPresentation.day(since, locale: locale, timeZone: timeZone))"
    }

    /// "Waiting for you · 3".
    public static func waitingTitle(_ count: Int) -> String {
        count > 0 ? "Waiting for you · \(count)" : "Waiting for you"
    }

    /// Where a suggestion came from and when: "thread · Sep 19", "automation · 2h ago",
    /// "thread · yesterday".
    public static func origin(_ suggestion: InstructionSuggestion, now: Date = Date(), locale: Locale = .current,
                              timeZone: TimeZone = .current) -> String {
        "\(suggestion.source.kind.rawValue) · \(when(suggestion.suggestedAt, now: now, locale: locale, timeZone: timeZone))"
    }

    /// Under an added line: "Sep 18 · from Ledger cleanup".
    public static func addedNote(_ added: AddedSuggestion, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        "\(InstructionsPresentation.day(added.addedAt, locale: locale, timeZone: timeZone)) · from \(added.sourceName)"
    }

    /// A line as a list shows it, without its Markdown bullet: "Prefer table-driven tests in Go."
    public static func plainLine(_ line: String) -> String {
        let item = InstructionsText.listItem(line)
        guard let space = item.firstIndex(of: " ") else { return item }
        return String(item[item.index(after: space)...])
    }

    /// The add button, which names the file it writes: "Add to AGENTS.md".
    public static func addTitle(_ file: InstructionFile) -> String {
        "Add to \(file.fileName)"
    }

    /// Which hosts an added line reaches: every host while Settings ▸ Instructions keeps them the
    /// same, else This Mac alone.
    public static func hostsWord(sameEverywhere: Bool) -> String {
        sameEverywhere ? "every host" : "This Mac"
    }

    /// "just now", "2h ago", "yesterday", then the day ("Sep 19").
    public static func when(_ time: Double, now: Date = Date(), locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let seconds = now.timeIntervalSince1970 - time
        if seconds < 86_400 { return InstructionsPresentation.age(time, now: now, locale: locale, timeZone: timeZone) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(Date(timeIntervalSince1970: time), inSameDayAs: yesterday) {
            return "yesterday"
        }
        return InstructionsPresentation.day(time, locale: locale, timeZone: timeZone)
    }
}
