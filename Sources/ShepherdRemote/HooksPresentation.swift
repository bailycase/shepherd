import Foundation
import ShepherdProtocol

// Settings › Hooks' rows, on the Mac (its own catalog) and on the iPhone and iPad (a host's, over
// `hooks.v1`): derived once per load from a catalog snapshot, so views only draw them.

/// One hook as Settings' rows draw it.
public struct HookRowValue: Equatable, Identifiable, Sendable {
    public var id: String
    public var hash: String
    /// The matcher, or "every tool" / "always" when it has none (`matcherIsAny`).
    public var matcher: String
    public var matcherIsAny: Bool
    public var command: String
    public var source: String
    /// The source by folder ("This Mac · ~/.claude", "payments · .shepherd"): the iPad's column.
    public var shortSource: String
    public var on: Bool
    /// The switch can't change it: a type Shepherd doesn't run.
    public var locked: Bool
    public var lockHelp: String?
}

public struct HookEventGroup: Equatable, Identifiable, Sendable {
    public var event: String
    public var label: String
    public var rows: [HookRowValue]
    public var id: String { event }
}

/// A hooks file as Sources and a space's Hooks tab draw it.
public struct HookFileRow: Equatable, Identifiable, Sendable {
    public enum Tone: Equatable, Sendable { case ok, off, failed }
    public enum Action: Equatable, Sendable { case openFile }
    public var id: String
    public var path: String
    public var shownPath: String
    public var format: String
    public var count: String
    public var state: String
    public var tone: Tone
    public var action: Action?
    public var dimmed: Bool
}

public struct HookScopeSection: Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var note: String
    public var root: String?
    public var files: [HookFileRow]
}

/// Where Add and Edit can save: This Mac's Shepherd file, then each space's.
public struct HookSaveTarget: Equatable, Hashable, Sendable {
    public var path: String
    public var label: String
    /// The space's folder; nil for This Mac.
    public var root: String?
    public init(path: String, label: String, root: String?) { self.path = path; self.label = label; self.root = root }
}

public enum HooksPresentation {
    /// Events with hooks, Shepherd's twelve in Settings order, then any others by name.
    public static func events(_ entries: [HookEntry]) -> [String] {
        let present = Set(entries.map(\.event))
        let known = HookEvent.allCases.map(\.rawValue)
        return known.filter(present.contains) + present.filter { !known.contains($0) }.sorted()
    }

    /// The hooks grouped by event, each group in file order.
    public static func groups(_ entries: [HookEntry], home: String, showScope: Bool = true) -> [HookEventGroup] {
        let byEvent = Dictionary(grouping: entries, by: \.event)
        return events(entries).map { event in
            HookEventGroup(event: event, label: HookEvent(rawValue: event)?.label ?? event,
                           rows: (byEvent[event] ?? []).map { row($0, home: home, showScope: showScope) })
        }
    }

    public static func row(_ entry: HookEntry, home: String, showScope: Bool) -> HookRowValue {
        let event = entry.hookEvent
        let anyLabel = [.preToolUse, .postToolUse, .permissionRequest].contains(event) ? "every tool" : "always"
        let lockHelp: String? = entry.handler.canRun ? nil : "Shepherd lists \(entry.handler.type) hooks but doesn't run them"
        let any = entry.matcher.isEmpty || entry.matcher == "*"
        return HookRowValue(id: entry.slot, hash: entry.hash, matcher: any ? anyLabel : entry.matcher, matcherIsAny: any,
                            command: command(entry.handler),
                            source: showScope ? sourceLabel(entry, home: home) : folderLabel(entry.file),
                            shortSource: shortSourceLabel(entry, home: home),
                            on: entry.runs, locked: lockHelp != nil, lockHelp: lockHelp)
    }

    /// What a handler runs: its command, else "server › tool".
    public static func command(_ handler: HookHandler) -> String {
        if let command = handler.command { return command.replacingOccurrences(of: "\n", with: " ") }
        if let server = handler.server, let tool = handler.tool { return "\(server) › \(tool)" }
        return handler.type
    }

    /// "This Mac · ~/.shepherd/hooks.json", "payments · .claude/settings.json".
    public static func sourceLabel(_ entry: HookEntry, home: String) -> String {
        switch entry.scope {
        case .mac: "This Mac · " + tilde(entry.file, home: home)
        case .space(let root): (root as NSString).lastPathComponent + " · " + relative(entry.file, to: root)
        }
    }

    /// "This Mac · ~/.claude", "payments · .shepherd".
    public static func shortSourceLabel(_ entry: HookEntry, home: String) -> String {
        switch entry.scope {
        case .mac: "This Mac · " + tilde((entry.file as NSString).deletingLastPathComponent, home: home)
        case .space(let root): (root as NSString).lastPathComponent + " · " + folderLabel(entry.file)
        }
    }

    /// ".shepherd", ".claude": a space row's short source.
    public static func folderLabel(_ file: String) -> String {
        ((file as NSString).deletingLastPathComponent as NSString).lastPathComponent
    }

    public static func tilde(_ path: String, home: String) -> String {
        guard !home.isEmpty else { return path }
        return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    public static func relative(_ path: String, to root: String) -> String {
        path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
    }

    /// Sources: This Mac's files, then each space with a file, without the files that aren't there.
    public static func sections(_ snapshot: HookCatalogSnapshot, home: String) -> [HookScopeSection] {
        var order: [HookScope] = []
        for source in snapshot.sources where !order.contains(source.scope) { order.append(source.scope) }
        return order.compactMap { scope in
            let sources = snapshot.sources.filter { $0.scope == scope && $0.state != .notFound }
            let root = scope.root
            if root != nil && sources.isEmpty { return nil }
            let name = root.map { ($0 as NSString).lastPathComponent } ?? "This Mac"
            let note = root.map { tilde($0, home: home) } ?? "Run in every space"
            return HookScopeSection(id: root ?? "", name: name, note: note, root: root, files: sources.map { fileRow($0, home: home) })
        }
    }

    public static func fileRow(_ source: HookSource, home: String) -> HookFileRow {
        let shown = source.scope.root.map { relative(source.path, to: $0) } ?? tilde(source.path, home: home)
        var row = HookFileRow(id: source.path, path: source.path, shownPath: shown, format: source.format.name, count: "–",
                              state: "", tone: .ok, action: nil, dimmed: false)
        switch source.state {
        case .loaded(let count):
            row.count = count == 1 ? "1 hook" : "\(count) hooks"
            row.state = "Loaded"
        case .notFound:
            row.state = "Not found"; row.tone = .off; row.dimmed = true
        case .readerOff:
            row.state = "Not read: switched off above"; row.tone = .off; row.dimmed = true
        case .unreadable:
            row.state = source.state.label; row.tone = .failed; row.action = .openFile
        }
        return row
    }

    /// Files that exist (Sources' count).
    public static func fileCount(_ snapshot: HookCatalogSnapshot) -> Int { snapshot.sources.count { $0.state != .notFound } }

    /// "1 hook", "8 hooks".
    public static func hooks(_ count: Int) -> String { count == 1 ? "1 hook" : "\(count) hooks" }
    /// "1 file", "6 files".
    public static func files(_ count: Int) -> String { count == 1 ? "1 file" : "\(count) files" }

    /// Where Add and Edit can save: This Mac's Shepherd file, then each space's.
    public static func saveTargets(_ snapshot: HookCatalogSnapshot, home: String) -> [HookSaveTarget] {
        let mac = HookSaveTarget(path: home + "/.shepherd/hooks.json", label: "This Mac · ~/.shepherd/hooks.json", root: nil)
        let roots = snapshot.sources.compactMap(\.scope.root).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return [mac] + roots.map { HookSaveTarget(path: $0 + "/.shepherd/hooks.json", label: ($0 as NSString).lastPathComponent + " · .shepherd/hooks.json", root: $0) }
    }

    /// The save targets for editing `entry`: its own file too, when it is none of them.
    public static func saveTargets(_ snapshot: HookCatalogSnapshot, home: String, editing entry: HookEntry) -> [HookSaveTarget] {
        var targets = saveTargets(snapshot, home: home)
        if !targets.contains(where: { $0.path == entry.file }) {
            targets.append(HookSaveTarget(path: entry.file, label: sourceLabel(entry, home: home), root: entry.scope.root))
        }
        return targets
    }

    /// The test's line under its outcome ("sample bash · exit 2 · 41 ms").
    public static func testMeta(_ result: HookTestResult, event: HookEvent, matcher: String) -> String {
        let tool = [.preToolUse, .postToolUse, .permissionRequest].contains(event) ? HookMatcher.agentTools(matching: matcher).first.map { "sample \($0)" } : nil
        return [tool ?? "sample \(event.rawValue)", result.exit.map { "exit \($0)" } ?? "no exit", "\(result.milliseconds) ms"].joined(separator: " · ")
    }
}

/// A test's collapsed Output: what the hook printed, each stream labelled, without its last line
/// breaks. Nil when it printed nothing.
public struct HookTestOutput: Equatable, Sendable {
    public struct Stream: Equatable, Sendable, Identifiable {
        public var label: String
        public var text: String
        /// "cut at 64 KiB" when the hook printed more than the cap.
        public var note: String?
        public var id: String { label }
        public init(label: String, text: String, note: String?) { self.label = label; self.text = text; self.note = note }
    }

    public var streams: [Stream]

    public init?(_ result: HookTestResult) {
        func shown(_ text: String) -> String { String(text[..<(text.lastIndex { !$0.isNewline }.map(text.index(after:)) ?? text.startIndex)]) }
        let streams = [Stream(label: "stdout", text: shown(result.stdout), note: result.stdoutCut ? "cut at 64 KiB" : nil),
                       Stream(label: "stderr", text: shown(result.stderr), note: result.stderrCut ? "cut at 64 KiB" : nil)]
            .filter { !$0.text.isEmpty }
        guard !streams.isEmpty else { return nil }
        self.streams = streams
    }
}

// MARK: The editor's form

/// Why the form can't be saved yet, said as how to fix it.
public struct HookEditError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// One handler as Settings' form edits it; `base` keeps the keys the form doesn't show.
public struct HookFormHandler: Equatable, Identifiable, Sendable {
    public var id = UUID()
    /// The entry being edited's own handler.
    public var original = false
    public var base: HookJSON = .object([HookJSON.Member]())
    public var type = "command"
    public var command = ""
    public var server = ""
    public var tool = ""
    public var input = ""
    public var timeout = ""
    public var statusMessage = ""

    public init(original: Bool = false, _ handler: HookHandler? = nil) {
        self.original = original
        guard let handler else { return }
        base = handler.raw
        type = handler.type
        command = handler.command ?? ""
        server = handler.server ?? ""
        tool = handler.tool ?? ""
        input = handler.input.map { $0.pretty.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        timeout = handler.timeout.map { $0 == $0.rounded() ? String(Int($0)) : String($0) } ?? ""
        statusMessage = handler.statusMessage ?? ""
    }

    /// The handler object, or why it can't be one.
    public func raw() throws -> HookJSON {
        var raw = base
        raw["type"] = .string(type)
        switch type {
        case "command":
            let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw HookEditError("Enter the command the hook runs.") }
            raw["command"] = .string(text)
            raw["server"] = nil; raw["tool"] = nil; raw["input"] = nil
        case "mcp_tool":
            guard !server.isEmpty, !tool.isEmpty else { throw HookEditError("Enter the MCP server and the tool the hook calls.") }
            raw["server"] = .string(server); raw["tool"] = .string(tool); raw["command"] = nil
            if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { raw["input"] = nil } else {
                guard let parsed = try? HookJSON.parse(input), parsed.objectValue != nil else {
                    throw HookEditError("The tool's input must be a JSON object.")
                }
                raw["input"] = parsed
            }
        default: break
        }
        let limit = timeout.trimmingCharacters(in: .whitespaces)
        if limit.isEmpty { raw["timeout"] = nil } else {
            guard let seconds = Double(limit), seconds > 0, seconds <= 600 else {
                throw HookEditError("The time limit is a number of seconds, up to 600.")
            }
            raw["timeout"] = .number(seconds)
        }
        raw["statusMessage"] = statusMessage.isEmpty ? nil : .string(statusMessage)
        return raw
    }

    /// Whether Test can run it: a command handler with a command.
    public var testable: Bool { type == "command" && !command.trimmingCharacters(in: .whitespaces).isEmpty }
}

/// The JSON pane: the file's entry for one hook (its event, one group, the handlers), and back.
public enum HookForm {
    public static func json(event: HookEvent, matcher: String, handlers: [HookFormHandler]) -> String {
        var group = HookJSON.object([HookJSON.Member]())
        if !matcher.isEmpty { group["matcher"] = .string(matcher) }
        group["hooks"] = .array(handlers.map { (try? $0.raw()) ?? $0.base })
        var hooks = HookJSON.object([HookJSON.Member]())
        hooks[event.rawValue] = .array([group])
        var root = HookJSON.object([HookJSON.Member]())
        root["hooks"] = hooks
        return root.pretty.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reads the JSON pane: one event with one group of handler objects. `originals` keeps which
    /// handlers were the edited entry's own, by position. Throws a line-numbered `HookEditError`.
    public static func parse(_ text: String, originals: [Bool]) throws -> (event: HookEvent, matcher: String, handlers: [HookFormHandler]) {
        do {
            let root = try HookJSON.parse(text)
            guard let events = root["hooks"]?.objectValue, events.count == 1, let member = events.first else {
                throw HookEditError("Keep one event under “hooks”.")
            }
            guard let event = HookEvent(rawValue: member.key) else { throw HookEditError("“\(member.key)” isn't a hook event.") }
            guard let groups = member.value.arrayValue, groups.count == 1, let handlers = groups[0]["hooks"]?.arrayValue, !handlers.isEmpty,
                  handlers.allSatisfy({ $0.objectValue != nil }) else {
                throw HookEditError("Keep one group with a “hooks” list of handler objects.")
            }
            let parsed = handlers.enumerated().map { index, raw in
                HookFormHandler(original: originals.indices.contains(index) && originals[index], HookHandler(raw: raw))
            }
            return (event, groups[0]["matcher"]?.stringValue ?? "", parsed)
        } catch let error as HookJSON.ParseError {
            throw HookEditError("Line \(error.line): \(error.message)")
        }
    }

    /// The drafts Save writes, or why not.
    public static func drafts(event: HookEvent, matcher: String, handlers: [HookFormHandler]) throws -> [HookDraft] {
        guard HookMatcher.isValid(matcher) else { throw HookEditError("The matcher isn't a regular expression Shepherd can read.") }
        return try handlers.map { HookDraft(event: event.rawValue, matcher: matcher, handler: HookHandler(raw: try $0.raw())) }
    }
}
