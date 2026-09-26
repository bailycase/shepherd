import Foundation
import ShepherdProtocol

// Activity lines (NWThread, ToolRows): a turn's tool calls as one quiet line per burst of work,
// consecutive calls of one kind merged, with the calls behind it. Pure derivations: every string
// a line, its calls, or the turn's changes card shows is built here once per turn, never in a
// view body.

/// "1 file", "7 files". Explicit forms: Foundation's inflection does not know words like
/// "subagent".
public func nativeCount(_ count: Int, _ singular: String, _ plural: String? = nil) -> String {
    "\(count) \(count == 1 ? singular : plural ?? singular + "s")"
}

/// "A", "A and B", "A, B and C".
func nativeJoinedList(_ parts: [String]) -> String {
    guard parts.count > 1 else { return parts.first ?? "" }
    return parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
}

private func capitalizedFirst(_ text: String) -> String {
    text.prefix(1).uppercased() + text.dropFirst()
}

// MARK: Shell commands

/// What a shell command does, as far as the thread cares: its line reads "Ran tests",
/// "Building", "Pushed".
public enum NativeCommandClass: String, Equatable, Hashable, Sendable, CaseIterable {
    case tests, build, commit, push, other
}

/// One classified shell segment: its class and a short head ("swift test", "git push").
private struct CommandSegment {
    var commandClass: NativeCommandClass
    var head: String
}

/// Segments of a command line split at `&&`, `||`, `;`, `|` and newlines, outside quotes.
private func commandSegments(_ command: String) -> [String] {
    var segments: [String] = []
    var current = ""
    var quote: Character?
    var index = command.startIndex
    while index < command.endIndex {
        let char = command[index]
        let next = command.index(after: index)
        if let open = quote {
            current.append(char)
            if char == open { quote = nil }
        } else if char == "'" || char == "\"" {
            quote = char
            current.append(char)
        } else if char == "\n" || char == ";" {
            segments.append(current)
            current = ""
        } else if char == "&" || char == "|" {
            // `&&`, `||`, and a pipe end a segment; `2>&1` and a lone `&` do not.
            if next < command.endIndex, command[next] == char {
                segments.append(current)
                current = ""
                index = command.index(after: next)
                continue
            } else if char == "|" {
                segments.append(current)
                current = ""
            } else {
                current.append(char)
            }
        } else {
            current.append(char)
        }
        index = next
    }
    segments.append(current)
    return segments.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

/// Words of one segment, quotes kept as part of their word.
private func commandWords(_ segment: String) -> [String] {
    var words: [String] = []
    var current = ""
    var quote: Character?
    for char in segment {
        if let open = quote {
            if char == open { quote = nil } else { current.append(char) }
        } else if char == "'" || char == "\"" {
            quote = char
        } else if char == " " || char == "\t" {
            if !current.isEmpty { words.append(current); current = "" }
        } else {
            current.append(char)
        }
    }
    if !current.isEmpty { words.append(current) }
    return words
}

/// Segments that never decide what a command is ("cd x && …", "… | tail -20").
private let noisePrograms: Set<String> = [
    "cd", "pushd", "popd", "export", "source", ".", "set", "unset", "echo", "printf", "true", "false", ":",
    "tail", "head", "grep", "rg", "tee", "cat", "sleep", "wc", "sort", "uniq", "sed", "awk", "cut", "tr", "less", "more",
]
private let wrapperPrograms: Set<String> = ["time", "nice", "sudo", "env", "command", "exec", "caffeinate", "timeout", "xcrun"]
private let testRunners: Set<String> = ["pytest", "jest", "vitest", "mocha", "rspec", "ctest", "phpunit", "ava", "tap", "karma", "playwright"]
private let buildTools: Set<String> = ["tsc", "webpack", "rollup", "esbuild", "cmake", "ninja", "xcodebuild"]

private func classify(_ segment: String) -> CommandSegment? {
    var words = commandWords(segment)
    // Leading `NAME=value` assignments and wrappers (`time`, `nice -n 10`, `env A=b`).
    while let first = words.first {
        if first.contains("="), first.first.map({ $0.isLetter || $0 == "_" }) == true, !first.hasPrefix("-") {
            words.removeFirst()
        } else if wrapperPrograms.contains(first) {
            words.removeFirst()
            while let option = words.first, option.hasPrefix("-") || (option.first?.isNumber ?? false) { words.removeFirst() }
        } else {
            break
        }
    }
    guard let first = words.first else { return nil }
    let program = (first as NSString).lastPathComponent
    if noisePrograms.contains(program) { return nil }
    let arguments = Array(words.dropFirst())
    let operands = arguments.filter { !$0.hasPrefix("-") }
    let sub = operands.first
    var head = [program] + (sub.map { [$0] } ?? [])
    var result: NativeCommandClass = .other

    switch program {
    case "git":
        // `git -C path commit`: the subcommand is the first operand that is not an option's value.
        var index = 0
        var subcommand: String?
        while index < arguments.count {
            let word = arguments[index]
            if word == "-C" || word == "-c" { index += 2; continue }
            if word.hasPrefix("-") { index += 1; continue }
            subcommand = word
            break
        }
        head = ["git"] + (subcommand.map { [$0] } ?? [])
        if subcommand == "commit" { result = .commit } else if subcommand == "push" { result = .push }
    case "swift":
        if sub == "test" { result = .tests } else if sub == "build" { result = .build }
    case "xcodebuild":
        head = ["xcodebuild"]
        result = arguments.contains(where: { $0 == "test" || $0 == "test-without-building" }) ? .tests : .build
        if result == .tests { head.append("test") }
    case "npm", "pnpm", "yarn", "bun", "deno":
        var script = sub
        if sub == "run" || sub == "run-script" {
            script = operands.dropFirst().first
            if let script { head.append(script) }
        }
        if let script {
            if script == "t" || script.hasPrefix("test") { result = .tests } else if script.hasPrefix("build") { result = .build }
        }
    case "npx", "pnpx", "bunx":
        if let tool = sub {
            if testRunners.contains(tool) { result = .tests } else if buildTools.contains(tool) || tool == "vite" && operands.contains("build") { result = .build }
        }
    case "go", "cargo", "dotnet", "zig", "mix", "gradle", "gradlew", "mvn", "bazel", "make":
        let tests: Set<String> = program == "make" ? ["test", "tests", "check"] : program == "mvn" ? ["test", "verify"] : ["test", "nextest"]
        if let sub, tests.contains(sub) {
            result = .tests
        } else if program == "make" || ["build", "check", "package", "install", "assemble", "compile"].contains(sub ?? "") {
            result = .build
        }
    case "python", "python3":
        if let module = arguments.firstIndex(of: "-m").flatMap({ arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }) {
            head = [program, "-m", module]
            if module == "pytest" || module == "unittest" { result = .tests }
        }
    case "node":
        if arguments.contains("--test") { result = .tests; head = ["node", "--test"] }
    case "bundle":
        if operands.contains("rspec") { result = .tests; head = ["bundle", "exec", "rspec"] }
    default:
        if testRunners.contains(program) { result = .tests; head = [program] }
        else if buildTools.contains(program) { result = .build; head = [program] }
    }
    return CommandSegment(commandClass: result, head: head.joined(separator: " "))
}

/// Every class a command line runs, in order: `cd x && swift build && swift test` is tests
/// (a test run builds), `git commit … && git push` is commit then push. Setup and pipes
/// (`cd`, `| tail`) never decide; a command with nothing recognisable is `other`.
public func nativeCommandClasses(_ command: String) -> [NativeCommandClass] {
    let segments = commandSegments(command).compactMap(classify)
    var classes: [NativeCommandClass] = []
    for segment in segments {
        guard segment.commandClass != .other, !classes.contains(segment.commandClass) else { continue }
        classes.append(segment.commandClass)
    }
    if classes.contains(.tests) { classes.removeAll { $0 == .build } }
    return classes.isEmpty ? [.other] : classes
}

/// The part of a command worth naming in a line's meta: "swift test", "git push",
/// "xcodebuild", "npm run build". The first segment that decided the class, else the first
/// segment that is not setup.
public func nativeCommandHead(_ command: String) -> String {
    let segments = commandSegments(command).compactMap(classify)
    let decisive = segments.first { $0.commandClass != .other } ?? segments.first
    return decisive?.head ?? command.split(whereSeparator: \.isNewline).first.map(String.init) ?? command
}

// MARK: Output parsing

private func regex(_ pattern: String) -> NSRegularExpression {
    try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
}

private enum OutputPattern {
    static let exitCode = regex(#"Command exited with code (\d+)"#)
    static let swiftTestingRun = regex(#"Test run with (\d+) tests?(?: in \d+ suites?)? (passed|failed)"#)
    static let swiftTestingFailure = regex(#"^\S*\s*Test (?!run with)\S.* failed after"#)
    static let xctest = regex(#"Executed (\d+) tests?, with (\d+) failures?"#)
    static let passed = regex(#"(\d+) (?:tests? |checks? |specs? |examples?, )?passed"#)
    static let failed = regex(#"(\d+) (?:tests? |checks? |specs? )?(?:failed|failures?)"#)
    static let filesChanged = regex(#"(\d+) files? changed"#)
}

private func matches(_ pattern: NSRegularExpression, in text: String) -> [[String]] {
    let range = NSRange(text.startIndex..., in: text)
    return pattern.matches(in: text, range: range).map { match in
        (0..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }
}

/// Summaries live at the end of long outputs; parsing the tail keeps a 10 MB log cheap. A cut
/// inside a multi-byte character (✔, ✘) is repaired rather than falling back to the whole log.
private func outputTail(_ output: String, limit: Int = 64 * 1024) -> String {
    guard output.utf8.count > limit else { return output }
    return String(decoding: output.utf8.suffix(limit), as: UTF8.self)
}

/// Passed and failed test counts from a runner's output (Swift Testing, XCTest, pytest, jest,
/// cargo, and "N passed" in general). nil where the output does not say.
public func nativeTestCounts(_ output: String) -> (passed: Int?, failed: Int?) {
    let text = outputTail(output)
    if let run = matches(OutputPattern.swiftTestingRun, in: text).last, let total = Int(run[1]) {
        if run[2] == "passed" { return (total, nil) }
        let failures = matches(OutputPattern.swiftTestingFailure, in: text).count
        return failures > 0 ? (max(0, total - failures), failures) : (nil, nil)
    }
    if let executed = matches(OutputPattern.xctest, in: text).last, let total = Int(executed[1]), let failures = Int(executed[2]) {
        return (total - failures, failures > 0 ? failures : nil)
    }
    let passed = matches(OutputPattern.passed, in: text).first.flatMap { Int($0[1]) }
    let failed = matches(OutputPattern.failed, in: text).first.flatMap { Int($0[1]) }.flatMap { $0 > 0 ? $0 : nil }
    return (passed, failed)
}

/// pi's bash tool ends a failed run with "Command exited with code N".
public func nativeExitCode(_ output: String) -> Int? {
    matches(OutputPattern.exitCode, in: outputTail(output, limit: 4096)).last.flatMap { Int($0[1]) }
}

// MARK: Calls

/// One tool call as the activity line and its calls list read it. Built once per message.
public struct NativeActivityCall: Equatable, Sendable, Identifiable {
    public enum Kind: String, Equatable, Hashable, Sendable {
        /// read, grep, find, ls: merges into "Explored N files".
        case explore
        /// edit, write: "Edited N files".
        case edit
        /// bash: classified into tests, builds, commits, pushes.
        case run
        /// Spawning subagents that have no card in the thread.
        case subagents
        /// The design agent's board_write and canvas_update: "Drew 4 boards", "Updated A and
        /// A · phone".
        case drew
        /// The design agent's design_check: "Checked against acme-web".
        case checked
        /// Any other tool; consecutive calls of the same tool merge.
        case other
    }

    public enum Explore: String, Equatable, Sendable { case read, search, list }

    /// The call id (stable from the live call to the saved one), else the entry id.
    public var id: String
    public var entryID: String
    public var toolCallID: String?
    /// The tool's own name ("read", "bash").
    public var name: String
    public var kind: Kind
    public var explore: Explore?
    /// The calls list's kind column: "read", "grep", "edit", "bash".
    public var label: String
    /// A path, a command's first line, or a quoted pattern.
    public var detail: String
    /// Paths truncate at the head so the filename survives; commands at the tail.
    public var isPath: Bool
    /// The calls list's trailing stat: "+58 −41", "160 lines", "3 matches", "17 passed", "exit 1".
    public var stat: String?
    public var state: NativeToolRow.State
    /// The file an edit or write touched (opens the review pane).
    public var path: String?
    public var added: Int
    public var removed: Int
    public var commandClasses: [NativeCommandClass]
    public var commandHead: String?
    public var testsPassed: Int?
    public var testsFailed: Int?
    public var filesChanged: Int?
    public var exitCode: Int?
    /// For a spawn: the subagent's name ("reviewer").
    public var subagent: String?
    /// For a board_write: the board's path, and whether the write made it (nil when the result
    /// doesn't say, as while it runs).
    public var board: String?
    public var boardCreated: Bool?
    /// For a design_check: the system it checked against and how many values were off it; both
    /// nil when no system was found.
    public var system: String?
    public var offSystem: Int?
    /// First line of a failed call's output ("no such file"), for its line's meta.
    public var failure: String?
    /// The user's Stop interrupted it (the host's `aborted`): done, not failed, and it reads
    /// "stopped".
    public var stopped: Bool
    public var startedAt: Double?
    public var endedAt: Double?
    /// Saved output (text blocks joined): the source for Copy Output and the full-output sheet.
    public var output: String
    /// The first lines a finished call expands to, and how many lines there are in all.
    public var outputHead: [String]
    public var outputLineCount: Int
    /// A running call's last three non-empty output lines.
    public var tail: [String]
    public var truncated: Bool
    /// Raw JSON arguments ("Show Call").
    public var arguments: String?

    public static let outputHeadLines = 12
    public static let tailLines = 3

    public var failed: Bool { state == .failed }
    public var running: Bool { state == .running }

    /// A shell call's whole command line, from its arguments (`detail` is its first line only);
    /// nil for any other call, or arguments with no command.
    public var command: String? {
        guard kind == .run, let data = arguments?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = object["command"] as? String,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return command
    }
    public var expandable: Bool { outputLineCount > 0 }

    /// Seconds from start to result; nil without both stamps.
    public var seconds: Double? {
        guard let startedAt, let endedAt, endedAt >= startedAt else { return nil }
        return (endedAt - startedAt) / 1000
    }
}

extension NativeActivityCall {
    public init(_ message: NativeThreadMessage) {
        let name = message.toolName ?? "result"
        let args = message.argumentsText.flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        func string(_ key: String) -> String? { (args?[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let output = message.blocks.filter { $0.kind == .text }.map(\.text).joined(separator: "\n")
        let stopped = message.status == "aborted"
        let failed = message.isError == true && !stopped
        let running = !failed && (message.status == "running" || message.status == "streaming")
        let lines = output.isEmpty ? [] : output.split(separator: "\n", omittingEmptySubsequences: false)
        let lineCount = lines.count
        let firstLine = lines.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { String($0.prefix(120)) } ?? ""

        self.id = message.toolCallID ?? message.entryID
        self.entryID = message.entryID
        self.toolCallID = message.toolCallID
        self.name = name
        self.explore = nil
        self.label = name
        self.detail = firstLine
        self.isPath = false
        self.stat = nil
        self.state = failed ? .failed : running ? .running : .done
        self.path = nil
        self.added = 0
        self.removed = 0
        self.commandClasses = []
        self.commandHead = nil
        self.testsPassed = nil
        self.testsFailed = nil
        self.filesChanged = nil
        self.exitCode = nil
        self.subagent = nil
        self.board = nil
        self.boardCreated = nil
        self.system = nil
        self.offSystem = nil
        self.failure = failed ? (firstLine.isEmpty ? nil : String(firstLine.prefix(60))) : nil
        self.stopped = stopped
        self.startedAt = message.startedAt
        self.endedAt = running ? nil : message.timestamp
        self.output = output
        self.outputHead = running ? [] : lines.prefix(Self.outputHeadLines).map(String.init)
        self.outputLineCount = lineCount
        var tail: [String] = []
        if running {
            for line in lines.reversed() where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                tail.insert(String(line), at: 0)
                if tail.count == Self.tailLines { break }
            }
        }
        self.tail = tail
        self.truncated = message.truncated
        self.arguments = message.argumentsText

        switch name {
        case "read":
            kind = .explore
            explore = .read
            detail = string("path") ?? firstLine
            isPath = string("path") != nil
            if !failed, !running, lineCount > 0 { stat = nativeCount(lineCount, "line") }
        case "grep", "find", "glob":
            kind = .explore
            explore = .search
            let pattern = string("pattern").map { name == "grep" ? "\"\($0)\"" : $0 }
            detail = pattern.map { "\($0) in \(string("path") ?? ".")" } ?? firstLine
            if !failed, !running {
                let count = output.hasPrefix("No ") ? 0 : lineCount
                stat = name == "grep" ? nativeCount(count, "match", "matches") : nativeCount(count, "file")
            }
        case "ls":
            kind = .explore
            explore = .list
            detail = string("path") ?? "."
            isPath = true
            if !failed, !running, lineCount > 0 { stat = nativeCount(lineCount, "entry", "entries") }
        case "edit", "write":
            kind = .edit
            detail = string("path") ?? firstLine
            isPath = string("path") != nil
            path = failed ? nil : string("path")
            if name == "edit" {
                var edits: [(old: String, new: String)] = []
                if let list = args?["edits"] as? [[String: Any]] {
                    edits = list.compactMap { edit in
                        guard let old = edit["oldText"] as? String, let new = edit["newText"] as? String else { return nil }
                        return (old, new)
                    }
                } else if let old = string("oldText"), let new = args?["newText"] as? String {
                    edits = [(old, new)]
                }
                let diff = NativeDiffStat(edits: edits)
                added = diff.added
                removed = diff.removed
            } else if let content = args?["content"] as? String {
                added = content.isEmpty ? 0 : content.split(separator: "\n", omittingEmptySubsequences: false).count
                    - (content.hasSuffix("\n") ? 1 : 0)
            }
            if !failed { stat = nativeDiffText(added: added, removed: removed) }
        case "bash", "powershell":
            kind = .run
            label = "bash"
            let command = string("command") ?? ""
            detail = command.split(whereSeparator: \.isNewline).first.map(String.init) ?? firstLine
            commandClasses = nativeCommandClasses(command)
            commandHead = command.isEmpty ? nil : nativeCommandHead(command)
            if !running {
                let counts: (passed: Int?, failed: Int?) = commandClasses.contains(.tests) ? nativeTestCounts(output) : (nil, nil)
                testsPassed = counts.passed
                testsFailed = counts.failed
                if commandClasses.contains(.commit) {
                    filesChanged = matches(OutputPattern.filesChanged, in: outputTail(output)).first.flatMap { Int($0[1]) }
                }
                exitCode = failed ? nativeExitCode(output) : nil
                if let testsFailed, failed || testsFailed > 0 {
                    // A piped run (`swift test | tail`) exits 0 with failures; the line still fails.
                    state = .failed
                    stat = "\(testsFailed) failed"
                } else if failed {
                    stat = exitCode.map { "exit \($0)" } ?? "failed"
                } else if let testsPassed {
                    stat = "\(testsPassed) passed"
                } else if commandClasses.contains(.build) {
                    stat = "build ok"
                } else if let filesChanged {
                    stat = nativeCount(filesChanged, "file") + " changed"
                }
            }
        case "subagent" where string("agent") != nil || string("task") != nil,
             "shepherd_child_start":
            kind = .subagents
            label = "spawn"
            let task = string("task").flatMap { $0.split(whereSeparator: \.isNewline).first.map(String.init) }
            subagent = string("agent") ?? string("role") ?? string("name")
                ?? task.flatMap { $0.split(separator: " ").first.map(String.init) } ?? "subagent"
            detail = [subagent, task].compactMap { $0 }.joined(separator: " · ")
        case "design_read":
            kind = .explore
            explore = .read
            detail = string("path") ?? "canvas.json"
            isPath = true
        case "board_write":
            kind = .drew
            label = "board"
            board = string("path")
            detail = board ?? firstLine
            isPath = board != nil
            if !failed, !running {
                boardCreated = firstLine.hasPrefix("Drew ") ? true : firstLine.hasPrefix("Updated ") ? false : nil
                stat = boardCreated == true ? "new" : boardCreated == false ? "updated" : "unchanged"
            }
        case "canvas_update":
            kind = .drew
            label = "canvas"
            detail = "canvas.json"
            isPath = true
        case "design_check":
            kind = .checked
            label = "check"
            detail = string("path") ?? "every board"
            isPath = string("path") != nil
            if !failed, !running, let found = nativeDesignCheck(firstLine) {
                system = found.system
                offSystem = found.offSystem
                stat = nativeCount(found.offSystem, "off-system value")
            }
        case "shepherd_parent_message":
            kind = .other
            label = "to parent"
            detail = string("message") ?? firstLine
        default:
            kind = .other
            detail = ["command", "path", "query", "url", "pattern"].compactMap(string).first ?? firstLine
            isPath = string("command") == nil && string("path") != nil
        }
        detail = String(detail.prefix(240))
        if stopped {
            // What it did before the Stop is unknown: no counts, and no file to review.
            stat = "stopped"
            path = nil
            testsPassed = nil
            testsFailed = nil
            filesChanged = nil
        }
        if stat == nil, !running, let seconds, seconds >= 0.5, kind != .edit, kind != .subagents, kind != .drew, !failed {
            stat = nativeDurationText(seconds)
        }
        if failed, stat == nil { stat = "failed" }
    }
}

// MARK: Bursts

/// One activity line: consecutive calls of one kind, or one failed call (failures never merge,
/// so each stays visible), or the one call that is running now.
public struct NativeActivityBurst: Equatable, Sendable, Identifiable {
    public enum State: Equatable, Sendable { case done, failed, running }

    /// The first call's id: stable while calls join the burst.
    public var id: String
    public var kind: NativeActivityCall.Kind
    public var state: State
    public var calls: [NativeActivityCall]
    /// "Explored 7 files", "Ran tests and a build", "Building".
    public var label: String
    /// "read 5 · search 2 · 0.9s"; for a running line, the command or path.
    public var meta: String
    /// "Explored 7 files, read 5, search 2, 0.9s, done"
    public var accessibilityLabel: String

    /// The running call's start (ms since epoch), for its elapsed time.
    public var startedAt: Double? { state == .running ? calls.first?.startedAt : nil }
    /// A running call's last output lines.
    public var tail: [String] { state == .running ? calls.first?.tail ?? [] : [] }
    public var expandable: Bool { state != .running }
    /// A drawing burst that only rewrote boards: it reads "Updated A and A · phone" and wears the
    /// edit glyph rather than the nib.
    public var isBoardUpdate: Bool {
        kind == .drew && calls.contains { $0.board != nil } && !calls.contains { $0.boardCreated == true }
    }
}

/// Merge consecutive calls of one kind into bursts. A failed, stopped, or running call each
/// stands alone; other tools merge only with the same tool.
public func nativeActivityBursts(_ calls: [NativeActivityCall]) -> [NativeActivityBurst] {
    var groups: [[NativeActivityCall]] = []
    for call in calls {
        if call.state == .done, !call.stopped, let last = groups.last?.last, last.state == .done, !last.stopped, last.kind == call.kind,
           call.kind != .other || last.name == call.name {
            groups[groups.count - 1].append(call)
        } else {
            groups.append([call])
        }
    }
    return groups.map(nativeActivityBurst)
}

/// One burst's words, from its calls.
public func nativeActivityBurst(_ calls: [NativeActivityCall]) -> NativeActivityBurst {
    let first = calls[0]
    let state: NativeActivityBurst.State = first.running ? .running : calls.contains(where: \.failed) ? .failed : .done
    let label: String
    var meta: [String] = []
    switch state {
    case .running:
        label = progressiveLabel(first)
        meta = [first.detail]
    case .failed:
        label = failedLabel(first)
        if first.kind == .run {
            meta = [first.commandHead ?? first.detail, first.stat ?? "failed"]
        } else {
            meta = [first.isPath ? (first.detail as NSString).lastPathComponent : first.detail, first.failure ?? "failed"]
        }
        if let seconds = wallSeconds(calls) { meta.append(nativeDurationText(seconds)) }
    case .done where first.stopped:
        label = stoppedLabel(first)
        meta = [first.kind == .run ? first.commandHead ?? first.detail
                : first.isPath ? (first.detail as NSString).lastPathComponent : first.detail, "stopped"]
        if let seconds = wallSeconds(calls) { meta.append(nativeDurationText(seconds)) }
    case .done:
        (label, meta) = doneWords(calls)
    }
    meta = meta.filter { !$0.isEmpty }
    let word = switch state {
    case .done: first.stopped ? "stopped" : "done"
    case .failed: "failed"
    case .running: "running"
    }
    return NativeActivityBurst(id: first.id, kind: first.kind, state: state, calls: calls, label: label,
                               meta: meta.joined(separator: " · "),
                               accessibilityLabel: ([label] + meta + [word]).joined(separator: ", "))
}

private func progressiveLabel(_ call: NativeActivityCall) -> String {
    switch call.kind {
    case .explore:
        switch call.explore {
        case .search: return "Searching"
        case .list: return "Listing"
        default: return "Reading"
        }
    case .edit: return call.name == "write" ? "Writing" : "Editing"
    case .run:
        switch call.commandClasses.first ?? .other {
        case .tests: return "Running tests"
        case .build: return "Building"
        case .commit: return "Committing"
        case .push: return "Pushing"
        case .other: return "Running"
        }
    case .subagents: return "Starting a subagent"
    case .drew: return call.name == "canvas_update" ? "Arranging the canvas" : "Drawing"
    case .checked: return "Checking the boards"
    case .other: return "Running \(call.label)"
    }
}

private func failedLabel(_ call: NativeActivityCall) -> String {
    switch call.kind {
    case .explore:
        switch call.explore {
        case .search: return "Search failed"
        case .list: return "List failed"
        default: return "Read failed"
        }
    case .edit: return call.name == "write" ? "Write failed" : "Edit failed"
    case .run:
        switch call.commandClasses.first ?? .other {
        case .tests: return "Ran tests"
        case .build: return "Ran a build"
        case .commit: return "Commit failed"
        case .push: return "Push failed"
        case .other: return "Ran a command"
        }
    case .subagents: return "Subagent failed to start"
    case .drew: return call.name == "canvas_update" ? "Canvas update failed" : "Board write failed"
    case .checked: return "Check failed"
    case .other: return "\(call.label) failed"
    }
}

/// A call the user's Stop interrupted: what it was doing, in the past, without blame.
private func stoppedLabel(_ call: NativeActivityCall) -> String {
    switch call.kind {
    case .explore:
        switch call.explore {
        case .search: return "Search stopped"
        case .list: return "List stopped"
        default: return "Read stopped"
        }
    case .edit: return call.name == "write" ? "Write stopped" : "Edit stopped"
    case .run:
        switch call.commandClasses.first ?? .other {
        case .tests: return "Ran tests"
        case .build: return "Ran a build"
        case .commit: return "Commit stopped"
        case .push: return "Push stopped"
        case .other: return "Ran a command"
        }
    case .subagents: return "Subagent stopped"
    case .drew: return call.name == "canvas_update" ? "Canvas update stopped" : "Drawing stopped"
    case .checked: return "Check stopped"
    case .other: return "\(call.label) stopped"
    }
}

/// Wall time from the first start to the last result, when the host stamped both. Under half
/// a second reads as instant and is left out, as a thought that short is.
private func wallSeconds(_ calls: [NativeActivityCall]) -> Double? {
    let starts = calls.compactMap(\.startedAt), ends = calls.compactMap(\.endedAt)
    guard starts.count == calls.count, ends.count == calls.count, let start = starts.min(), let end = ends.max(), end >= start else { return nil }
    let seconds = (end - start) / 1000
    return seconds >= 0.5 ? seconds : nil
}

private func doneWords(_ calls: [NativeActivityCall]) -> (String, [String]) {
    let first = calls[0]
    let duration = wallSeconds(calls).map { nativeDurationText($0) }
    switch first.kind {
    case .explore:
        let reads = calls.filter { $0.explore == .read }
        let searches = calls.count { $0.explore == .search }
        let lists = calls.count { $0.explore == .list }
        let files = Set(reads.map(\.detail)).count + searches + lists
        var meta: [String] = []
        if !reads.isEmpty { meta.append("read \(reads.count)") }
        if searches > 0 { meta.append("search \(searches)") }
        if lists > 0 { meta.append("list \(lists)") }
        return ("Explored " + nativeCount(files, "file"), meta + [duration].compactMap { $0 })
    case .edit:
        let files = Set(calls.map { $0.path ?? $0.detail }).count
        let added = calls.reduce(0) { $0 + $1.added }, removed = calls.reduce(0) { $0 + $1.removed }
        return ("Edited " + nativeCount(files, "file"), [nativeDiffText(added: added, removed: removed)])
    case .run:
        return runWords(calls, duration: duration)
    case .subagents:
        let names = calls.compactMap(\.subagent)
        return ("Started " + nativeCount(calls.count, "subagent"), [names.joined(separator: " · ")])
    case .drew:
        return drewWords(calls)
    case .checked:
        let total = calls.compactMap(\.offSystem).reduce(0, +)
        guard let system = calls.last(where: { $0.system != nil })?.system else {
            return ("Checked the boards", ["no design system found"])
        }
        return ("Checked against \(system)", [nativeCount(total, "off-system value")])
    case .other:
        let label = calls.count == 1 ? "Used \(first.label)" : "Used \(first.label) \(calls.count) times"
        return (label, (calls.count == 1 ? [first.detail] : []) + [duration].compactMap { $0 })
    }
}

/// "Ran tests and a build", "Committed and pushed", "Ran 2 commands"; meta "17 passed ·
/// build ok · 1m 02s".
private func runWords(_ calls: [NativeActivityCall], duration: String?) -> (String, [String]) {
    var order: [NativeCommandClass] = []
    var counts: [NativeCommandClass: Int] = [:]
    for call in calls {
        for value in call.commandClasses {
            if counts[value] == nil { order.append(value) }
            counts[value, default: 0] += 1
        }
    }
    func noun(_ value: NativeCommandClass) -> String? {
        let n = counts[value] ?? 0
        switch value {
        case .tests: return "tests"
        case .build: return n == 1 ? "a build" : "\(n) builds"
        case .other: return n == 1 ? "a command" : "\(n) commands"
        case .commit, .push: return nil
        }
    }
    var phrases: [String] = []
    var nouns: [String] = []
    var ranIndex: Int?
    for value in order {
        if let noun = noun(value) {
            if ranIndex == nil { ranIndex = phrases.count; phrases.append("") }
            nouns.append(noun)
        } else {
            phrases.append(value == .commit ? "committed" : "pushed")
        }
    }
    if let ranIndex { phrases[ranIndex] = "ran " + nativeJoinedList(nouns) }
    let label = capitalizedFirst(nativeJoinedList(phrases))

    var meta: [String] = []
    for value in order {
        switch value {
        case .tests:
            let passed = calls.compactMap(\.testsPassed)
            if !passed.isEmpty { meta.append("\(passed.reduce(0, +)) passed") }
        case .build:
            meta.append("build ok")
        case .commit:
            if let files = calls.compactMap(\.filesChanged).last { meta.append(nativeCount(files, "file") + " changed") }
        case .push:
            break
        case .other:
            let others = calls.filter { $0.commandClasses == [.other] }
            if others.count == 1, let head = others[0].commandHead { meta.append(head) }
        }
    }
    return (label, meta + [duration].compactMap { $0 })
}

// MARK: Design verbs

/// A board's name as the design agent's lines say it: the skill names a direction's board by its
/// letter and a size of it by letter and size (`A.dc.html` reads "A", `A-phone.dc.html`
/// "A · phone"); any other board reads as its file name.
public func nativeBoardName(_ path: String) -> String {
    let stem = nativeBoardParts(path)
    guard let letter = stem.letter else { return stem.stem }
    return stem.size.map { "\(letter) · \($0)" } ?? letter
}

private func nativeBoardParts(_ path: String) -> (stem: String, letter: String?, size: String?) {
    var stem = (path as NSString).lastPathComponent
    if stem.hasSuffix(".dc.html") { stem.removeLast(".dc.html".count) }
    let scalars = Array(stem)
    guard let first = scalars.first, first.isASCII, first.isUppercase,
          scalars.count == 1 || scalars[1] == "-" || scalars[1] == "_" else { return (stem, nil, nil) }
    let size = scalars.count > 2 ? String(scalars[2...]).replacingOccurrences(of: "-", with: " ")
        .replacingOccurrences(of: "_", with: " ") : nil
    return (stem, String(first), size)
}

/// "3 directions + phone": how many directions the boards draw, and the other sizes drawn of
/// them; the boards' names when they don't follow the skill's naming.
public func nativeBoardSummary(_ paths: [String]) -> String {
    let parts = paths.map(nativeBoardParts)
    guard parts.allSatisfy({ $0.letter != nil }) else {
        let names = paths.map(nativeBoardName)
        return names.count > 3 ? names.prefix(3).joined(separator: " · ") + " …" : names.joined(separator: " · ")
    }
    var directions: [String] = [], sizes: [String] = []
    for part in parts {
        if let size = part.size {
            if !sizes.contains(size) { sizes.append(size) }
        } else if let letter = part.letter, !directions.contains(letter) {
            directions.append(letter)
        }
    }
    guard !directions.isEmpty else { return paths.map(nativeBoardName).joined(separator: " · ") }
    return ([nativeCount(directions.count, "direction")] + sizes).joined(separator: " + ")
}

/// A design_check result's first line: "Checked against acme-web · 0 off-system values".
func nativeDesignCheck(_ line: String) -> (system: String, offSystem: Int)? {
    let prefix = "Checked against "
    guard line.hasPrefix(prefix), let dot = line.range(of: " · ", options: .backwards) else { return nil }
    let system = String(line[line.index(line.startIndex, offsetBy: prefix.count)..<dot.lowerBound])
    let count = line[dot.upperBound...].split(separator: " ").first.flatMap { Int($0) }
    guard !system.isEmpty, let count else { return nil }
    return (system, count)
}

/// "Drew 4 boards" · "3 directions + phone"; "Updated A and A · phone"; "Arranged the canvas".
private func drewWords(_ calls: [NativeActivityCall]) -> (String, [String]) {
    var order: [String] = []
    var created: Set<String> = []
    for call in calls {
        guard let board = call.board else { continue }
        if !order.contains(board) { order.append(board) }
        if call.boardCreated == true { created.insert(board) }
    }
    guard !order.isEmpty else { return ("Arranged the canvas", []) }
    let drawn = order.filter { created.contains($0) }
    let updated = order.filter { !created.contains($0) }
    let updatedWords = updated.count > 3 ? nativeCount(updated.count, "board") : nativeJoinedList(updated.map(nativeBoardName))
    if drawn.isEmpty { return ("Updated " + updatedWords, []) }
    let label = "Drew " + nativeCount(drawn.count, "board") + (updated.isEmpty ? "" : " and updated " + updatedWords)
    return (label, [nativeBoardSummary(drawn)])
}

// MARK: Changes card

/// The files a turn's edits and writes touched: the changes card that ends the turn.
public struct NativeTurnChanges: Equatable, Sendable {
    public struct File: Equatable, Sendable, Identifiable {
        public enum Status: String, Equatable, Sendable { case modified = "M", added = "A", deleted = "D" }
        public var id: String { path }
        public var path: String
        /// "Sources/ShepherdApp/" (empty at the root) and "ThreadView.swift".
        public var directory: String
        public var name: String
        public var status: Status
        public var added: Int
        public var removed: Int

        public init(path: String, status: Status, added: Int, removed: Int) {
            self.path = path
            self.status = status
            self.added = added
            self.removed = removed
            if let slash = path.lastIndex(of: "/") {
                directory = String(path[...slash])
                name = String(path[path.index(after: slash)...])
            } else {
                directory = ""
                name = path
            }
        }
    }

    public var files: [File]
    public var added: Int
    public var removed: Int
    /// Every file the turn changed; `files` may list only the first of them (a recorded turn
    /// carries twenty).
    public var fileCount: Int
    /// The turn the host recorded (`ChangesTurn`): its Undo and Redo, and the scope Review opens.
    /// nil for a card drawn from the turn's edit calls alone (an older host, no repository).
    public var turnID: UUID?
    public var undone: Bool
    public var canUndo: Bool
    public var canRedo: Bool

    public init(files: [File], added: Int, removed: Int, fileCount: Int? = nil, turnID: UUID? = nil, undone: Bool = false,
                canUndo: Bool = false, canRedo: Bool = false) {
        self.files = files
        self.added = added
        self.removed = removed
        self.fileCount = max(fileCount ?? files.count, files.count)
        self.turnID = turnID
        self.undone = undone
        self.canUndo = canUndo
        self.canRedo = canRedo
    }

    /// "Edited 4 files"; "Undid the agent’s edits to 4 files" once undone (ChangesCard).
    public var title: String {
        let files = nativeCount(fileCount, "file")
        return undone ? "Undid the agent’s edits to \(files)" : "Edited \(files)"
    }
}

/// Files the calls edited or wrote, in first-touched order, with summed line counts. A write
/// to a file the turn had not read or edited before reads as added: the host cannot say
/// whether it existed.
public func nativeTurnChanges(_ calls: [NativeActivityCall]) -> NativeTurnChanges? {
    var order: [String] = []
    var files: [String: NativeTurnChanges.File] = [:]
    var seen: Set<String> = []
    for call in calls where call.state == .done {
        if call.explore == .read { seen.insert(call.detail) }
        guard call.kind == .edit, let path = call.path else { continue }
        if var file = files[path] {
            file.added += call.added
            file.removed += call.removed
            files[path] = file
        } else {
            order.append(path)
            let status: NativeTurnChanges.File.Status = call.name == "write" && !seen.contains(path) ? .added : .modified
            files[path] = NativeTurnChanges.File(path: path, status: status, added: call.added, removed: call.removed)
        }
        seen.insert(path)
    }
    guard !order.isEmpty else { return nil }
    let list = order.compactMap { files[$0] }
    return NativeTurnChanges(files: list, added: list.reduce(0) { $0 + $1.added }, removed: list.reduce(0) { $0 + $1.removed })
}
