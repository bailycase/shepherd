import Foundation
import ShepherdCore
import ShepherdProtocol

// What a touch client's composer and thread header draw, derived from a thread store's values:
// the header's meta line, the Up next rows, the slash-command matches, the model choices, the
// thinking levels, and a question's options. Pure, so every rule is a unit test; the Mac keeps
// its own (keyboard-first) derivations in ShepherdApp.

// MARK: Header

/// The running turn's elapsed time in the iPad header's status pill ("Running · 21s"; iPadThread
/// board). The turn and context counts left the headers for the branch chip.
public struct NativeThreadMeta: Equatable, Sendable {
    /// How long the running turn has run: "21s", "5m 02s".
    public var elapsed: String?

    public init(elapsed: String? = nil) {
        self.elapsed = elapsed
    }

    /// `runningSince` (ms) is the prompt that opened the running turn, nil at rest; `now` in ms.
    public init(runningSince: Double?, now: Double) {
        elapsed = runningSince.map { nativeDurationText(max(0, now - $0) / 1000, live: true) }
    }
}

// MARK: Up next

/// A message deleted from the queue, or the queue cleared, kept for an Undo row where the
/// messages were.
public struct NativeQueueUndo: Equatable, Identifiable, Sendable {
    public let id: String
    public let messages: [NativeQueuedMessage]
    /// Where the messages return among the queued ones.
    public let index: Int
    public let cleared: Bool

    public init(messages: [NativeQueuedMessage], index: Int, cleared: Bool) {
        id = cleared ? "cleared:" + (messages.first?.id.uuidString ?? "") : messages.first?.id.uuidString ?? UUID().uuidString
        self.messages = messages
        self.index = index
        self.cleared = cleared
    }
}

/// One row of the touch Up next stack.
public struct NativeQueueStackRow: Equatable, Identifiable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Handed to pi, to read once its current tool calls finish.
        case steering
        /// Waiting; `number` is its place in the order it goes (1 is next).
        case queued(number: Int)
        /// Undo, where a message was deleted.
        case deleted
        /// Undo, where the queue was cleared of this many messages.
        case cleared(count: Int)
    }

    /// A message's id, or its Undo row's: a message and the Undo row it leaves are one row.
    public var id: String
    public var kind: Kind
    public var message: UUID?
    public var text: String
    /// Its images' names ("Image" when the sender gave none).
    public var images: [String]
    /// An editor is open on it (here or on another device).
    public var held: Bool

    public var isQueued: Bool {
        if case .queued = kind { return true }
        return false
    }

    /// Move to top would move it: a queued message that is not already next.
    public var canMoveToTop: Bool {
        if case .queued(let number) = kind { return number > 1 }
        return false
    }
}

public enum NativeQueueStack {
    /// Steering messages first, then the queued ones numbered in the order they go, with each
    /// Undo row back where its messages were (an Undo whose messages are back in the queue is
    /// dropped).
    public static func rows(_ queue: [NativeQueuedMessage], undo: [NativeQueueUndo] = []) -> [NativeQueueStackRow] {
        func row(_ message: NativeQueuedMessage, _ kind: NativeQueueStackRow.Kind) -> NativeQueueStackRow {
            NativeQueueStackRow(id: message.id.uuidString, kind: kind, message: message.id, text: message.text,
                                images: message.images.map { $0.name ?? "Image" }, held: message.held)
        }
        func placeholder(_ undo: NativeQueueUndo) -> NativeQueueStackRow {
            NativeQueueStackRow(id: undo.id, kind: undo.cleared ? .cleared(count: undo.messages.count) : .deleted,
                                message: nil, text: undo.cleared ? "" : undo.messages.first?.text ?? "", images: [], held: false)
        }
        var rows = queue.filter { $0.state == .steering }.map { row($0, .steering) }
        let present = Set(queue.map(\.id))
        var pending = undo.enumerated()
            .filter { !$0.element.messages.contains { present.contains($0.id) } }
            .sorted { ($0.element.index, $0.offset) < ($1.element.index, $1.offset) }
            .map(\.element)
        for (index, message) in queue.filter({ $0.state == .queued }).enumerated() {
            while let next = pending.first, next.index <= index {
                rows.append(placeholder(next))
                pending.removeFirst()
            }
            rows.append(row(message, .queued(number: index + 1)))
        }
        return rows + pending.map(placeholder)
    }

    /// What a paused queue's header says about why it waits (the Mac's tooltip, the touch
    /// header's hint): the host's reason, or what resumes it. nil while the queue goes on its own.
    public static func pausedReason(paused: Bool, notice: String?) -> String? {
        paused ? notice ?? pausedHelp : nil
    }

    public static let pausedHelp = "The queue waits for you: send it, steer it in, or send a new message."

    /// A queued row's first action: Steer now while pi works, Send now while it is idle (a
    /// paused queue).
    public static func steerLabel(running: Bool) -> String {
        running ? "Steer now" : "Send now"
    }

    /// The options menu's delivery choices, in order, with their menu titles.
    public static let modes: [(mode: NativeQueueMode, title: String)] = [
        (.oneAtATime, "One message per turn"),
        (.all, "Everything at once"),
    ]
}

// MARK: Slash commands

/// The commands a draft of "/…" matches, and what was typed after the slash.
public struct NativeSlashMatches: Equatable, Sendable {
    public var query: String
    public var commands: [NativeCommand]
    /// Every command pi reports ("4 of 23").
    public var total: Int

    /// nil unless the draft is a single "/word" still being typed (no space or newline yet), or
    /// pi reports no commands. Commands whose name starts with the query come first, then those
    /// that contain it, each in pi's order.
    public init?(draft: String, commands: [NativeCommand]) {
        guard !commands.isEmpty, draft.hasPrefix("/"), !draft.contains(where: \.isWhitespace) else { return nil }
        let query = String(draft.dropFirst()).lowercased()
        let prefixed = commands.filter { query.isEmpty || $0.name.lowercased().hasPrefix(query) }
        let containing = query.isEmpty ? [] : commands.filter {
            let name = $0.name.lowercased()
            return !name.hasPrefix(query) && name.contains(query)
        }
        self.query = query
        self.commands = prefixed + containing
        total = commands.count
    }

    /// The draft a chosen command leaves: its name and a space, ready for arguments.
    public static func completion(_ command: NativeCommand) -> String {
        "/" + command.name + " "
    }

    /// A command's tag: its source for prompt templates and skills, none for extension commands.
    public static func tag(_ command: NativeCommand) -> String? {
        guard let source = command.source, source != "extension", !source.isEmpty else { return nil }
        return source
    }
}

// MARK: Model and thinking

/// A model a picker offers.
public struct NativeModelChoice: Equatable, Identifiable, Sendable {
    /// "provider/id", what `setModel` takes.
    public var id: String
    /// "claude-opus" for "anthropic/claude-opus".
    public var title: String
    /// The row's second line: the thinking levels the model takes (`NativeThinkingLevel.line`),
    /// nil when the host's catalog does not say.
    public var thinking: String?
    public var isCurrent: Bool
}

/// One provider's models, in the host's order.
public struct NativeModelSection: Equatable, Identifiable, Sendable {
    public var id: String { title }
    public var title: String
    public var models: [NativeModelChoice]
}

public enum NativeModelChoices {
    /// "provider/model" → "model".
    public static func shortName(_ model: String) -> String {
        guard let slash = model.firstIndex(of: "/") else { return model }
        return String(model[model.index(after: slash)...])
    }

    /// "provider/model" → "provider" ("Other" without one).
    public static func provider(_ model: String) -> String {
        guard let slash = model.firstIndex(of: "/") else { return "Other" }
        return String(model[..<slash])
    }

    /// One section per provider in the host's order, the models matching `query` (a
    /// case-insensitive part of the id), each with its line from `thinking` (`thinkingLines`).
    /// The current model is marked, and listed even when the host's catalog lacks it.
    public static func sections(_ models: [String], current: String?, query: String = "",
                                thinking: [String: String] = [:]) -> [NativeModelSection] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var ids = models
        if let current, !ids.contains(current) { ids.insert(current, at: 0) }
        var order: [String] = []
        var byProvider: [String: [NativeModelChoice]] = [:]
        var seen: Set<String> = []
        for id in ids where seen.insert(id).inserted && (q.isEmpty || id.lowercased().contains(q)) {
            let provider = provider(id)
            if byProvider[provider] == nil { order.append(provider) }
            byProvider[provider, default: []].append(NativeModelChoice(id: id, title: shortName(id), thinking: thinking[id],
                                                                       isCurrent: id == current))
        }
        return order.map { NativeModelSection(title: $0, models: byProvider[$0] ?? []) }
    }

    /// Each model's thinking line (`NativeThinkingLevel.line`), derived once per catalog: the
    /// levels the New thread sheet offers it (`ThinkingLevel.offered`), and for the thread's
    /// `current` model the ones pi reports for it (`currentLevels`, the snapshot's), when it does.
    public static func thinkingLines(_ listing: ModelListing, hostTakesAllLevels: Bool, current: String? = nil,
                                     currentLevels: [String]? = nil) -> [String: String] {
        let plain = Set(listing.withoutThinking ?? [])
        // Without `withoutThinking`, so that one set lookup says whether each model reasons.
        let configured = ModelListing(models: [], defaultModel: nil, thinkingLevels: listing.thinkingLevels)
        var lines: [String: String] = [:]
        for id in listing.models where lines[id] == nil {
            let levels = plain.contains(id) ? [] : ThinkingLevel.offered(model: id, listing: configured, hostTakesAllLevels: hostTakesAllLevels)
            lines[id] = NativeThinkingLevel.line(levels.map(\.rawValue))
        }
        if let current, let currentLevels, !currentLevels.isEmpty { lines[current] = NativeThinkingLevel.line(currentLevels) }
        return lines
    }
}

/// A thinking level `setThinking` takes.
public struct NativeThinkingLevel: Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var note: String?

    /// Every level pi has, in pi's order, with the menu's notes (NWComposer: Low "quick",
    /// Medium "default", High "slower, deeper").
    public static let all = [
        NativeThinkingLevel(id: "off", title: "Off"),
        NativeThinkingLevel(id: "minimal", title: "Minimal", note: "fastest"),
        NativeThinkingLevel(id: "low", title: "Low", note: "quick"),
        NativeThinkingLevel(id: "medium", title: "Medium", note: "default"),
        NativeThinkingLevel(id: "high", title: "High", note: "slower, deeper"),
        NativeThinkingLevel(id: "xhigh", title: "Extra high", note: "deeper still"),
        NativeThinkingLevel(id: "max", title: "Max", note: "slowest, deepest"),
    ]

    /// Off, Low, Medium, High: what a host that does not say which levels its model takes is
    /// offered (all an older host accepts).
    public static let fallback = all.filter { ["off", "low", "medium", "high"].contains($0.id) }

    /// The menu for the levels pi reports, in its order (a level this client does not know as
    /// pi spells it); `fallback` when it reports none.
    public static func levels(_ ids: [String]?) -> [NativeThinkingLevel] {
        guard let ids, !ids.isEmpty else { return fallback }
        return ids.map { id in all.first { $0.id == id } ?? NativeThinkingLevel(id: id, title: title(id)) }
    }

    /// "Medium" for "medium", "Extra high" for "xhigh"; an unknown level as pi spelled it,
    /// capitalized.
    public static func title(_ level: String) -> String {
        all.first { $0.id == level }?.title ?? level.prefix(1).uppercased() + level.dropFirst()
    }

    /// A model picker row's second line: the levels a model takes (pi's spellings, in pi's
    /// order), titled as the thinking menu titles them ("Off · Minimal · Low · Medium · High"),
    /// or "No thinking" when it takes none but Off.
    public static func line(_ levels: [String]) -> String {
        guard levels.contains(where: { $0 != "off" }) else { return "No thinking" }
        return levels.map(title).joined(separator: " · ")
    }

    /// Whether a menu of `levels` offers any thinking: pi reports only Off for a model without
    /// reasoning.
    public static func reasons(_ levels: [NativeThinkingLevel]) -> Bool {
        levels.contains { $0.id != "off" }
    }

    /// The thinking chip shows while pi reports a level it can set, the levels pi offers the
    /// model are more than Off, and the host's catalog does not say the thread's model takes none
    /// (DESIGN › Composer). A catalog still loading, an older host's, or one that does not know
    /// the model keeps it.
    public static func offered(thinking: String?, supportedActions: Set<String>, model: String?, listing: ModelListing?,
                               levels: [NativeThinkingLevel] = fallback) -> Bool {
        guard thinking != nil, supportedActions.contains("setThinking"), reasons(levels) else { return false }
        guard let model, let listing else { return true }
        return listing.takesThinking(model)
    }
}

extension ThinkingLevel {
    /// The levels a new agent's sheet offers before its pi starts (no session to ask yet): the
    /// target's listing says which the model takes (`ModelListing.offeredThinkingLevels`; none
    /// without reasoning). While it loads, the standard set. A host without
    /// `RemoteProtocol.thinkingLevelsCapability` accepts only `legacy`.
    public static func offered(model: String?, listing: ModelListing?, hostTakesAllLevels: Bool) -> [ThinkingLevel] {
        let levels = listing?.offeredThinkingLevels(model) ?? supported(reasoning: true)
        return hostTakesAllLevels ? levels : levels.filter(legacy.contains)
    }
}

// MARK: Questions

/// One answer a select question offers, as a touch panel draws it: its title, the lines after
/// the first as a description, and whether the asker marked it recommended. `value` is the
/// option exactly as offered: the answer sent back.
public struct NativeQuestionOption: Equatable, Identifiable, Sendable {
    public var id: Int { number }
    /// 1-based, the number drawn beside it.
    public var number: Int
    public var value: String
    public var title: String
    public var detail: String?
    public var recommended: Bool

    /// The options of `dialog`, parsed. An option is recommended only when the asker said so:
    /// "(Recommended)" (any case) at the end of its first line, which the title drops.
    public static func options(_ dialog: NativeThreadDialog) -> [NativeQuestionOption] {
        options(dialog.options ?? [])
    }

    /// Answers as offered, parsed the same way (a subagent's question carries them bare).
    public static func options(_ values: [String]) -> [NativeQuestionOption] {
        values.enumerated().map { index, value in
            let lines = value.split(separator: "\n", omittingEmptySubsequences: false)
            var title = String(lines.first ?? "").trimmingCharacters(in: .whitespaces)
            var recommended = false
            if let range = title.range(of: "(recommended)", options: [.caseInsensitive, .anchored, .backwards]) {
                recommended = true
                title = String(title[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                if title.hasSuffix("—") || title.hasSuffix("-") || title.hasSuffix(":") {
                    title = String(title.dropLast()).trimmingCharacters(in: .whitespaces)
                }
            }
            let rest = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return NativeQuestionOption(number: index + 1, value: value, title: title.isEmpty ? value : title,
                                        detail: rest.isEmpty ? nil : rest, recommended: recommended)
        }
    }
}

/// Which of pi's questions the user hid (Hide the question: the Mac's panel, the iPad's card).
/// Only that one stays hidden: the next question pi asks arrives open. Keys name a question in
/// its thread ("<session>:<dialog id>").
public struct NativeQuestionHiding: Equatable, Sendable {
    public private(set) var hiddenKey: String?

    public init() {}

    public func isHidden(_ key: String?) -> Bool { key != nil && key == hiddenKey }
    public mutating func hide(_ key: String) { hiddenKey = key }
    public mutating func show() { hiddenKey = nil }
}

/// A confirm question's two answers. pi's confirm takes yes or no; the asker words only the
/// question, so the buttons say Yes and No (never an approval the asker did not offer).
public enum NativeConfirmAnswers {
    public static let yes = "Yes"
    public static let no = "No"
}
