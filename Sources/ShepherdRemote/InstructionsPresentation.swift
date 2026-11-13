import Foundation
import ShepherdProtocol

/// What a client knows about one remote host's root instructions.
public enum InstructionsHostFiles: Equatable, Sendable {
    /// Not connected now.
    case offline
    /// Connected, but its Shepherd predates Settings ▸ Instructions (no `instructions.v1`).
    case unsupported
    /// Asking it.
    case checking
    /// It answered with an error (the client's reason).
    case failed(String)
    case loaded(InstructionsSnapshot)

    public var snapshot: InstructionsSnapshot? {
        if case .loaded(let snapshot) = self { return snapshot }
        return nil
    }
}

/// A state as a dot in a tone and a word unless the dot says it all (Projects' host rows draw it too).
public struct InstructionsChip: Equatable, Sendable {
    public enum Tone: Equatable, Sendable {
        case done
        case attention
        case quiet
        /// Being asked: `running`.
        case working
        /// It answered with an error: `failed`.
        case failed
    }

    public var tone: Tone
    public var word: String?

    public init(_ tone: Tone, _ word: String? = nil) {
        self.tone = tone
        self.word = word
    }
}

/// Settings ▸ Instructions' words, shared by the Mac, the iPhone and the iPad: a save's date, a
/// file's note under its name.
public enum InstructionsPresentation {
    /// A history row's date, and when an offline host was last seen: the time on a 24-hour
    /// clock for today ("07:12"), else the day ("Sep 19").
    public static func historyDate(_ time: Double, now: Date = Date(), locale: Locale = .current,
                                   timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let date = Date(timeIntervalSince1970: time)
        return calendar.isDate(date, inSameDayAs: now) ? clock(date, timeZone: timeZone) : day(time, locale: locale, timeZone: timeZone)
    }

    /// "just now", "2m ago", "3h ago", then the day ("Sep 19").
    public static func age(_ time: Double, now: Date = Date(), locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let seconds = now.timeIntervalSince1970 - time
        if seconds < 60 { return "just now" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))h ago" }
        return day(time, locale: locale, timeZone: timeZone)
    }

    /// "Sep 19", "Sep 02": a save's day.
    public static func day(_ time: Double, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        Date(timeIntervalSince1970: time).formatted(Date.FormatStyle(locale: locale, timeZone: timeZone).month(.abbreviated).day(.twoDigits))
    }

    /// "07:12", on a 24-hour clock like the boards.
    public static func clock(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// What a file is for, as its tab says it: "how you work", "overrides everything".
    public static func role(_ file: InstructionFile) -> String {
        switch file {
        case .agents: "how you work"
        case .appendSystem: "overrides everything"
        }
    }

    /// A file's note under its name: what it is for and its length ("how you work · 1,204 characters").
    /// `sentence` starts it with a capital, as a row on the phone does.
    public static func fileNote(_ file: InstructionFile, text: String, sentence: Bool = false) -> String {
        let role = role(file)
        let count = text.count
        return "\(sentence ? role.prefix(1).uppercased() + role.dropFirst() : role) · \(count.formatted()) \(count == 1 ? "character" : "characters")"
    }
}
