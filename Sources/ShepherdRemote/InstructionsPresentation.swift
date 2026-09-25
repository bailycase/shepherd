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

/// A host chip's state on Settings ▸ Instructions: a dot in a tone, and a word unless the dot
/// says it all.
public struct InstructionsChip: Equatable, Sendable {
    public enum Tone: Equatable, Sendable {
        /// Synced, or the same as This Mac: `done`.
        case done
        /// Differs from This Mac: `lanternText`.
        case attention
        /// Offline, kept different, or too old to sync: `textTertiary`.
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

/// A machine's row in Settings ▸ Instructions' "Files on each host" list: when its files last
/// changed (or when it was last seen), over a note on how the open file compares with This Mac's.
public struct InstructionsHostRow: Equatable, Sendable {
    /// "edited 2m ago", "edited Sep 19", "last seen 07:12", "needs update".
    public var detail: String
    /// "AGENTS · APPEND", "2 lines differ", "matched This Mac"; nil when there is nothing to say.
    public var note: String?
    public var noteTone: InstructionsChip.Tone

    public init(detail: String, note: String? = nil, noteTone: InstructionsChip.Tone = .quiet) {
        self.detail = detail
        self.note = note
        self.noteTone = noteTone
    }
}

/// Settings ▸ Instructions' rules for hosts, shared by the Mac, the iPhone and the iPad: what a
/// chip says, when a file last changed, and which files a host holds.
public enum InstructionsPresentation {
    /// This Mac's chip. With Same on every host on it reports the sync ("synced" once every
    /// connected host matches); per host, it is the reference and shows its dot alone.
    public static func localChip(sameEverywhere: Bool, allSynced: Bool) -> InstructionsChip {
        guard sameEverywhere else { return InstructionsChip(.done) }
        return allSynced ? InstructionsChip(.done, "synced") : InstructionsChip(.quiet, "not synced")
    }

    /// A remote host's chip against This Mac's saved `local` files. With Same on every host on it
    /// reports the sync of both files ("synced 2m ago", "offline · will sync"); per host, how
    /// the open `file` compares ("differs · 2 lines", or the dot alone when it matches).
    public static func hostChip(
        _ files: InstructionsHostFiles,
        local: InstructionsSnapshot?,
        file: InstructionFile,
        sameEverywhere: Bool,
        pending: Bool,
        keptDifferent: Bool,
        syncedAt: Date?,
        now: Date = Date()
    ) -> InstructionsChip {
        switch files {
        case .offline: return InstructionsChip(.quiet, sameEverywhere && pending ? "offline · will sync" : "offline")
        case .unsupported: return InstructionsChip(.quiet, "needs update")
        case .checking: return InstructionsChip(.working, "checking…")
        case .failed: return InstructionsChip(.failed, "couldn't read")
        case .loaded(let snapshot):
            guard let local else { return InstructionsChip(.working, "checking…") }
            if sameEverywhere {
                let lines = InstructionFile.allCases.map { InstructionsText.differingLineCount(local[$0], snapshot[$0]) }.reduce(0, +)
                if lines == 0 {
                    return InstructionsChip(.done, syncedAt.map { "synced \(age($0.timeIntervalSince1970, now: now))" } ?? "synced")
                }
                return InstructionsChip(.attention, "differs · \(lineCount(lines))")
            }
            let lines = InstructionsText.differingLineCount(local[file], snapshot[file])
            if lines == 0 { return InstructionsChip(.done) }
            return keptDifferent ? InstructionsChip(.quiet, "kept different") : InstructionsChip(.attention, "differs · \(lineCount(lines))")
        }
    }

    /// This Mac's row: when either file was last saved, over the files it holds.
    public static func localRow(_ local: InstructionsSnapshot, now: Date = Date(), locale: Locale = .current,
                                timeZone: TimeZone = .current) -> InstructionsHostRow {
        InstructionsHostRow(detail: edited(local, now: now, locale: locale, timeZone: timeZone), note: filesHeld(local))
    }

    /// A remote host's row. `lastKnown` is what it held when last read (an offline host's files);
    /// `lastConnected` when its connection last dropped.
    public static func hostRow(
        _ files: InstructionsHostFiles,
        lastKnown: InstructionsSnapshot?,
        local: InstructionsSnapshot?,
        file: InstructionFile,
        keptDifferent: Bool,
        lastConnected: Date?,
        now: Date = Date(),
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> InstructionsHostRow {
        switch files {
        case .unsupported: return InstructionsHostRow(detail: "needs update", note: "its Shepherd predates Instructions")
        case .checking: return InstructionsHostRow(detail: "checking…")
        case .failed: return InstructionsHostRow(detail: "couldn't read", noteTone: .failed)
        case .offline:
            let seen = lastConnected.map {
                "last seen \(historyDate($0.timeIntervalSince1970, now: now, locale: locale, timeZone: timeZone))"
            } ?? "offline"
            guard let lastKnown, let local else { return InstructionsHostRow(detail: seen) }
            let lines = InstructionsText.differingLineCount(local[file], lastKnown[file])
            return InstructionsHostRow(detail: seen, note: lines == 0 ? "matched This Mac" : "\(lineCount(lines)) differed")
        case .loaded(let snapshot):
            let detail = edited(snapshot, now: now, locale: locale, timeZone: timeZone)
            guard let local else { return InstructionsHostRow(detail: detail) }
            let lines = InstructionsText.differingLineCount(local[file], snapshot[file])
            if lines == 0 { return InstructionsHostRow(detail: detail, note: "matches This Mac") }
            if keptDifferent { return InstructionsHostRow(detail: detail, note: "kept different") }
            return InstructionsHostRow(detail: detail, note: "\(lineCount(lines)) differ", noteTone: .attention)
        }
    }

    /// With Same on every host on, the hosts whose files drifted from This Mac's: "build-01
    /// differs from This Mac.", "build-01 and horizon differ from This Mac."
    public static func drifted(_ names: [String]) -> String {
        "\(list(names)) \(names.count == 1 ? "differs" : "differ") from This Mac."
    }

    /// The other file's status in one line, under its name: how This Mac's copy compares with
    /// every host's. `hosts` holds each remote host's name and copy (nil while it can't be read).
    public static func otherFileLine(local: String, hosts: [(name: String, text: String?)]) -> String {
        let differing = hosts.filter { host in host.text.map { InstructionsText.differingLineCount(local, $0) > 0 } ?? false }
        if !differing.isEmpty { return "Differs on \(list(differing.map(\.name)))." }
        let unknown = hosts.filter { $0.text == nil }.map(\.name)
        guard unknown.isEmpty else {
            let known = ["This Mac"] + hosts.filter { $0.text != nil }.map(\.name)
            let verb = unknown.count == 1 ? "isn't" : "aren't"
            return "Same on \(list(known)); \(list(unknown)) \(verb) connected."
        }
        switch hosts.count {
        case 0: return "Only on This Mac."
        case 1: return "Same on both hosts."
        default:
            let words = ["three", "four", "five", "six", "seven", "eight", "nine", "ten"]
            let count = hosts.count + 1
            return "Same on all \(count - 3 < words.count ? words[count - 3] : String(count)) hosts."
        }
    }

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

    /// Which files a host holds: "AGENTS · APPEND", "AGENTS", "APPEND", or "no files".
    public static func filesHeld(_ snapshot: InstructionsSnapshot) -> String {
        let held = [(InstructionFile.agents, "AGENTS"), (.appendSystem, "APPEND")]
            .filter { !snapshot[$0.0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map(\.1)
        return held.isEmpty ? "no files" : held.joined(separator: " · ")
    }

    /// Two versions of a file, kept apart on purpose: remembered by this fingerprint so the same
    /// difference is never flagged again, while any change to either side is. FNV-1a, stable
    /// across launches.
    public static func fingerprint(host: String, local: String) -> String {
        var bytes = Array(host.utf8)
        bytes.append(0)
        bytes.append(contentsOf: local.utf8)
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }

    private static func lineCount(_ lines: Int) -> String {
        lines == 1 ? "1 line" : "\(lines) lines"
    }

    /// "edited 2m ago", "edited Sep 19", or "no saves yet": the newer of the two files' saves.
    private static func edited(_ snapshot: InstructionsSnapshot, now: Date, locale: Locale, timeZone: TimeZone) -> String {
        let saves = InstructionFile.allCases.compactMap { snapshot.lastSaved($0) }
        guard let newest = saves.max() else { return "no saves yet" }
        return "edited \(age(newest, now: now, locale: locale, timeZone: timeZone))"
    }

    /// "horizon", "build-01 and horizon", "build-01, horizon and studio".
    private static func list(_ names: [String]) -> String {
        guard let last = names.last else { return "" }
        let rest = names.dropLast()
        return rest.isEmpty ? last : "\(rest.joined(separator: ", ")) and \(last)"
    }
}
