import Foundation
import Testing
@testable import ShepherdSessions

/// Hooks identity: canonical JSON and hashes shared with the runtime.
@Suite("Hook canonical JSON and hashes")
struct HookCanonicalTests {
    static let vectors = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/hooks/hash-vectors.json")

    @Test func everySharedVectorHasItsCanonicalJSONAndHash() throws {
        let vectors = try #require(HookJSON.parse(String(contentsOf: Self.vectors, encoding: .utf8)).arrayValue)
        #expect(vectors.count >= 6)
        for vector in vectors {
            let handler = try #require(vector["handler"])
            let canonical = HookCanonical.canonical(handler)
            #expect(canonical == vector["canonical"]?.stringValue)
            let hash = HookCanonical.hash(file: vector["file"]!.stringValue!, event: vector["event"]!.stringValue!,
                                          matcher: vector["matcher"]!.stringValue!, handler: handler)
            #expect(hash == vector["hash"]?.stringValue)
        }
    }

    @Test func numbersPrintAsJavaScriptPrintsThem() {
        let cases: [(Double, String)] = [(10, "10"), (-2, "-2"), (1.5, "1.5"), (0.1, "0.1"), (0.001, "0.001"), (1e-7, "1e-7"),
                                         (1e21, "1e+21"), (1e20, "100000000000000000000"), (123.456, "123.456"),
                                         (1.2345678901234568e20, "123456789012345680000"), (-0.0, "0"), (2.5e-7, "2.5e-7")]
        for (value, text) in cases { #expect(HookJSON.jsNumber(value) == text, "\(value)") }
    }

    @Test func prettyTextKeepsKeyOrderAndRoundTrips() throws {
        let text = #"{"z":1,"a":{"keep":[1,"two",{"b":null,"a":true}],"empty":[],"none":{}},"s":"tab\t/é"}"#
        let value = try HookJSON.parse(text)
        #expect(value.objectValue?.map(\.key) == ["z", "a", "s"])
        let pretty = value.pretty
        #expect(pretty.hasPrefix("{\n  \"z\": 1,\n  \"a\": {\n    \"keep\": [\n      1,"))
        #expect(pretty.contains("\"empty\": [],\n    \"none\": {}"))
        #expect(try HookJSON.parse(pretty) == value)
    }

    @Test func aParseErrorNamesItsLine() {
        #expect(throws: HookJSON.ParseError(line: 3, message: "expected “,” or “}”")) {
            try HookJSON.parse("{\n  \"a\": 1\n  \"b\": 2\n}")
        }
    }

    @Test func matchersMatchAgentToolsByEitherName() {
        #expect(HookMatcher.agentTools(matching: "Edit|Write") == ["edit", "write"])
        #expect(HookMatcher.agentTools(matching: "MultiEdit") == ["edit"])
        #expect(HookMatcher.agentTools(matching: "Glob|ls") == ["find", "ls"])
        #expect(HookMatcher.agentTools(matching: "") == HookMatcher.agentTools)
        #expect(HookMatcher.agentTools(matching: "*") == HookMatcher.agentTools)
        #expect(HookMatcher.agentTools(matching: "Bas") == [])
        #expect(HookMatcher.agentTools(matching: "(") == [] && !HookMatcher.isValid("("))
        #expect(HookMatcher.matches("mcp__github__.*", name: "mcp__github__create_issue"))
        #expect(HookEvent.allCases.count == 12 && HookEvent.preToolUse.label == "Before a tool runs")
    }

    @Test func outcomesReadExitCodesAndJSON() {
        #expect(HookOutcome.interpret(event: "PreToolUse", exit: 2, stdout: "", stderr: "no .env\n") == .blocked(reason: "no .env"))
        #expect(HookOutcome.interpret(event: "PreToolUse", exit: 1, stdout: "", stderr: "boom") == .failed("exit 1: boom"))
        #expect(HookOutcome.interpret(event: "PreToolUse", exit: 0, stdout: "", stderr: "") == .allowed)
        #expect(HookOutcome.interpret(event: "PreToolUse", exit: 0, stdout: #"{"hookSpecificOutput":{"permissionDecision":"ask","permissionDecisionReason":"rm"}}"#, stderr: "") == .ask(reason: "rm"))
        #expect(HookOutcome.interpret(event: "PreToolUse", exit: 0, stdout: #"{"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":"no"}}"#, stderr: "") == .blocked(reason: "no"))
        #expect(HookOutcome.interpret(event: "Stop", exit: 0, stdout: #"{"decision":"block","reason":"tests fail"}"#, stderr: "") == .blocked(reason: "tests fail"))
        #expect(HookOutcome.interpret(event: "SessionStart", exit: 0, stdout: "notes\n", stderr: "") == .context("notes"))
        #expect(HookOutcome.interpret(event: "PostToolUse", exit: 0, stdout: "notes\n", stderr: "") == .allowed)
        #expect(HookOutcome.interpret(event: "PostToolUse", exit: 0, stdout: #"{"additionalContext":"lint ok"}"#, stderr: "") == .context("lint ok"))
    }
}

/// Finding, reading and reviewing hooks files, on scratch folders standing in for the home,
/// the support folder and spaces.
@Suite("Hook catalog")
struct HookCatalogTests {
    struct Fixture {
        let dir: URL
        var home: String { dir.appendingPathComponent("home").path }
        var support: URL { dir.appendingPathComponent("support") }
        var catalog: HookCatalog { HookCatalog(home: home, support: support) }
        var space: String { PiHome.canonical(dir.appendingPathComponent("home/code/app").path) }

        init() throws {
            dir = URL(fileURLWithPath: PiHome.canonical(try makeTempDirectory().path))
            try FileManager.default.createDirectory(atPath: space + "/.git", withIntermediateDirectories: true)
        }
        func write(_ path: String, _ text: String) throws {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try text.write(toFile: path, atomically: true, encoding: .utf8)
        }
        func trustSpace(_ path: String, _ decision: Bool) throws {
            try write(support.appendingPathComponent("pi/trust.json").path, "{\"\(path)\": \(decision)}")
        }
        func remove() { try? FileManager.default.removeItem(at: dir) }
    }

    static let preToolUse = #"{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"./check.sh","x-note":"kept"}]}]}}"#

    @Test func aMacFileLoadsAndEachHookStartsNew() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write(f.home + "/.shepherd/hooks.json", Self.preToolUse)
        let snapshot = f.catalog.load()
        let source = try #require(snapshot.sources.first { $0.path == f.home + "/.shepherd/hooks.json" })
        #expect(source.state == .loaded(count: 1) && source.format == .shepherd && source.scope == .mac)
        #expect(snapshot.sources.count == 4) // This Mac has no settings.local.json
        #expect(snapshot.sources.filter { $0.state == .notFound }.count == 3)
        let entry = try #require(snapshot.entries.first)
        #expect(entry.slot == f.home + "/.shepherd/hooks.json#PreToolUse/0/0")
        #expect(entry.matcher == "Bash" && entry.handler.command == "./check.sh" && entry.handler.type == "command")
        #expect(entry.canonical == #"{"command":"./check.sh","type":"command","x-note":"kept"}"#)
        #expect(entry.hash == HookCanonical.hash(file: entry.file, event: "PreToolUse", matcher: "Bash", canonical: entry.canonical))
        #expect(entry.review == .new && entry.editable && !entry.runs && entry.name == "./check.sh")
    }

    @Test func trustOffAndChangedFollowTheTrustFile() throws {
        let f = try Fixture(); defer { f.remove() }
        let path = f.home + "/.shepherd/hooks.json"
        try f.write(path, Self.preToolUse)
        let store = f.catalog.trustStore
        let entry = try #require(f.catalog.load().entries.first)
        try store.trust([entry], by: .review)
        #expect(f.catalog.load().entries.first?.review == .on)
        #expect(f.catalog.load().summary(forSpaceRoot: nil) == HookSummary(running: 1, needingReview: 0))
        try store.setOn(entry.hash, false)
        #expect(f.catalog.load().entries.first?.review == .off)
        try store.setOn(entry.hash, true)

        try f.write(path, Self.preToolUse.replacingOccurrences(of: "./check.sh", with: "./other.sh"))
        let changed = try #require(f.catalog.load().entries.first)
        guard case .changed(let previous) = changed.review else { Issue.record("expected changed, got \(changed.review)"); return }
        #expect(previous.entry == entry.canonical && previous.by == "review" && previous.slot == entry.slot)
        #expect(f.catalog.load().summary(forSpaceRoot: nil) == HookSummary(running: 0, needingReview: 1))

        try store.keepOff([changed])
        #expect(f.catalog.load().entries.first?.review == .off)
        try store.untrust([changed.hash])
        guard case .changed = f.catalog.load().entries.first?.review else { Issue.record("expected changed again"); return }
    }

    @Test func aMissingOrInvalidTrustFileReadsAsEmpty() throws {
        let f = try Fixture(); defer { f.remove() }
        #expect(f.catalog.trustStore.read() == HookTrust())
        try f.write(f.catalog.trustStore.url.path, "not json")
        #expect(f.catalog.trustStore.read() == HookTrust())
        try f.write(f.catalog.trustStore.url.path, #"{"version":1,"trusted":{"h":{"slot":"s"}},"readers":{"codex":false}}"#)
        let trust = f.catalog.trustStore.read()
        #expect(trust.trusted["h"]?.slot == "s" && trust.readers == HookTrust.Readers(claude: true, codex: false))
    }

    @Test func readersOffSkipClaudeAndCodexFiles() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write(f.home + "/.claude/settings.json", #"{"model":"x","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#)
        try f.write(f.home + "/.codex/hooks.json", Self.preToolUse)
        #expect(f.catalog.load().entries.map(\.format) == [.claude, .codex])
        try f.catalog.trustStore.setReader(.claude, false)
        let snapshot = f.catalog.load()
        #expect(snapshot.entries.map(\.format) == [.codex])
        #expect(snapshot.sources.first { $0.format == .claude }?.state == .readerOff)
    }

    @Test func spaceFilesLoadOnlyWhenPiTrustsTheSpace() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write(f.space + "/.shepherd/hooks.json", Self.preToolUse)
        #expect(f.catalog.spaceRoot(forCwd: f.space + "/Sources/deep") == f.space)
        #expect(f.catalog.spaceRoot(forCwd: f.home) == nil)
        #expect(f.catalog.spaceRoot(forCwd: f.dir.path) == nil)

        var snapshot = f.catalog.load(spaceRoots: [f.space, f.home])
        #expect(snapshot.sources.count == 4 + 5)
        #expect(snapshot.sources.first { $0.path == f.space + "/.shepherd/hooks.json" }?.state == .spaceNotTrusted)
        #expect(snapshot.entries.isEmpty)

        try f.trustSpace((f.space as NSString).deletingLastPathComponent, true) // a parent decision counts
        snapshot = f.catalog.load(spaceRoots: [f.space])
        #expect(snapshot.entries.map(\.scope) == [.space(root: f.space)])
        #expect(snapshot.sources.first { $0.path == f.space + "/.shepherd/hooks.json" }?.state == .loaded(count: 1))

        try f.write(f.support.appendingPathComponent("pi/trust.json").path,
                    "{\"\((f.space as NSString).deletingLastPathComponent)\": true, \"\(f.space)\": false}")
        #expect(f.catalog.load(spaceRoots: [f.space]).entries.isEmpty)
    }

    @Test func theComposerSummaryCountsThisMacAndTheThreadsSpace() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.trustSpace(f.space, true)
        try f.write(f.home + "/.shepherd/hooks.json", Self.preToolUse)
        try f.write(f.space + "/.claude/settings.local.json", #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"npm test"},{"type":"prompt","prompt":"x"}]}]}}"#)
        let mac = try #require(f.catalog.load().entries.first)
        try f.catalog.trustStore.trust([mac], by: .review)
        #expect(f.catalog.summary(forCwd: f.space + "/Sources") == HookSummary(running: 1, needingReview: 2))
        let snapshot = f.catalog.load(spaceRoots: [f.space])
        try f.catalog.trustStore.trust(snapshot.entries.filter { $0.scope != .mac }, by: .review)
        let trusted = f.catalog.load(spaceRoots: [f.space])
        #expect(trusted.running(forSpaceRoot: f.space).map(\.handler.command) == ["./check.sh", "npm test"]) // prompt never runs
        #expect(trusted.summary(forSpaceRoot: "/elsewhere") == HookSummary(running: 1, needingReview: 0))
        #expect(HookSummary(running: 0, needingReview: 0).showsGlyph == false)
    }

    @Test func aFileThatDoesNotParseIsReportedWithItsLine() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write(f.home + "/.shepherd/hooks.json", "{\n  \"hooks\": {\n    \"Stop\": [,]\n  }\n}")
        try f.write(f.home + "/.claude/settings.json", #"{"hooks":[]}"#)
        let snapshot = f.catalog.load()
        #expect(snapshot.sources[0].state == .unreadable(line: 3, message: "unexpected character"))
        #expect(snapshot.sources[0].state.label == "Couldn't read: line 3, unexpected character")
        #expect(snapshot.sources[1].state == .unreadable(line: nil, message: "“hooks” isn't an object"))
        #expect(snapshot.entries.isEmpty)
    }

    /// The runtime's node test reads the same cases: both take a file or leave it out alike.
    @Test func filesReadAsTheRuntimeReadsThemTheSharedParseCases() throws {
        let f = try Fixture(); defer { f.remove() }
        let url = HookCanonicalTests.vectors.deletingLastPathComponent().appendingPathComponent("parse-cases.json")
        let cases = try #require(HookJSON.parse(String(contentsOf: url, encoding: .utf8))["cases"]?.arrayValue)
        #expect(cases.count >= 20)
        for item in cases {
            let name = item["name"]?.stringValue ?? "", file = try #require(item["file"]?.stringValue)
            var bytes: Data
            if let hex = item["hex"]?.stringValue {
                bytes = Data(stride(from: 0, to: hex.count, by: 2).map { i in
                    UInt8(hex[hex.index(hex.startIndex, offsetBy: i)..<hex.index(hex.startIndex, offsetBy: i + 2)], radix: 16)!
                })
            } else { bytes = Data(try #require(item["text"]?.stringValue).utf8) }
            if let pad = item["padTo"]?.numberValue { bytes.append(Data(repeating: 0x20, count: Int(pad) - bytes.count)) }
            let path = f.dir.appendingPathComponent(file).path
            try bytes.write(to: URL(fileURLWithPath: path))
            let read = Result { try HookCatalog.entries(in: path, scope: .mac, format: .shepherd, isTOML: file.hasSuffix(".toml"), trust: HookTrust()) }
            if let unreadable = item["unreadable"] {
                let line: Int?? = switch read {
                case .success: nil
                case .failure(let error as HookJSON.ParseError): .some(error.line)
                case .failure: .some(nil)
                }
                #expect(line == .some(unreadable["line"]?.numberValue.map { Int($0) }), "\(name)")
            } else {
                #expect(try read.get().count == Int(item["entries"]?.numberValue ?? -1), "\(name)")
            }
        }
    }

    @Test func codexConfigTomlHooksReadLikeJSON() throws {
        let f = try Fixture(); defer { f.remove() }
        let toml = """
        model = "gpt-5"
        notes = \"\"\"
        [[hooks.Fake]]
        \"\"\"
        [mcp_servers.github]
        args = ["-y", "server"]
        env = { TOKEN = "x" }

        [[hooks.PreToolUse]]
        matcher = "Edit|Write" # files
        [[hooks.PreToolUse.hooks]]
        type = "command"
        command = 'grep -q "x" $FILE'
        timeout = 10
        async = false
        statusMessage = "Tab\\tthere \\u00e9"

        [[hooks.Stop]]
        [[hooks.Stop.hooks]]
        type = "command"
        command = "npm test"
        """
        let path = f.home + "/.codex/config.toml"
        try f.write(path, toml)
        let entries = f.catalog.load().entries
        #expect(entries.map(\.event) == ["PreToolUse", "Stop"])
        let first = try #require(entries.first)
        #expect(first.matcher == "Edit|Write" && !first.editable && first.format == .codex)
        #expect(first.handler.command == #"grep -q "x" $FILE"# && first.handler.timeout == 10 && first.handler.isAsync == false)
        #expect(first.handler.statusMessage == "Tab\tthere é")
        #expect(first.slot == path + "#PreToolUse/0/0" && entries[1].slot == path + "#Stop/0/0" && entries[1].matcher == "")
        let json = try HookJSON.parse(#"{"type":"command","command":"grep -q \"x\" $FILE","timeout":10,"async":false,"statusMessage":"Tab\tthere é"}"#)
        #expect(first.canonical == json.canonical)

        try f.write(path, "[[hooks.Stop]]\n[[hooks.Stop.hooks]]\ntype = \"command\"\nargs = [\"x\"]\n")
        #expect(f.catalog.load().sources.first { $0.path == path }?.state == .unreadable(line: 4, message: "only strings, numbers and booleans are supported here"))
        try f.write(path, "[[hooks.Stop.hooks]]\ntype = \"command\"\n")
        guard case .unreadable(line: 1, _) = f.catalog.load().sources.first(where: { $0.path == path })?.state else { Issue.record("expected line 1"); return }
    }
}

/// Writing one handler into a hooks file without disturbing the rest.
@Suite("Hook file writer")
struct HookFileWriterTests {
    @Test func addUpdateAndDeleteKeepEveryOtherKeyAndTrustTheirWrites() throws {
        let f = try HookCatalogTests.Fixture(); defer { f.remove() }
        let path = f.home + "/.claude/settings.json"
        try f.write(path, #"{"model":"opus","permissions":{"allow":["Bash(ls)"]},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done","x":1}]}]},"zeta":true}"#)
        let writer = HookFileWriter(trust: f.catalog.trustStore)

        let added = try writer.add(HookDraft(event: "PreToolUse", matcher: "Edit|Write", handler: .command("./no-env.sh", timeout: 10)), to: path)
        var text = try String(contentsOfFile: path, encoding: .utf8)
        #expect(text.hasPrefix("{\n  \"model\": \"opus\",\n  \"permissions\": {\n    \"allow\": [\n      \"Bash(ls)\"\n    ]\n  },"))
        #expect(text.hasSuffix("  \"zeta\": true\n}\n"))
        var entries = f.catalog.load().entries
        #expect(entries.map(\.event) == ["Stop", "PreToolUse"])
        #expect(entries[0].canonical == #"{"command":"say done","type":"command","x":1}"# && entries[0].review == .new)
        #expect(entries[1].hash == added && entries[1].review == .on)
        #expect(f.catalog.trustStore.read().trusted[added]?.by == "edit")

        // A second hook with the same matcher joins the group.
        try writer.add(HookDraft(event: "PreToolUse", matcher: "Edit|Write", handler: .command("./lint.sh")), to: path)
        entries = f.catalog.load().entries
        #expect(entries.map { $0.slot.split(separator: "#").last.map(String.init) } == ["Stop/0/0", "PreToolUse/0/0", "PreToolUse/0/1"])

        // Off stays off across an edit; the old hash is forgotten.
        try f.catalog.trustStore.setOn(entries[1].hash, false)
        let stale = entries[1]
        let updated = try writer.update(stale, to: HookDraft(event: "PreToolUse", matcher: "Edit|Write", handler: .command("./no-env.sh", timeout: 20)))
        let trust = f.catalog.trustStore.read()
        #expect(trust.trusted[added] == nil && trust.off == [updated])
        entries = f.catalog.load().entries
        #expect(entries[1].handler.timeout == 20 && entries[1].review == .off)

        // Moving to another matcher makes a group; a stale entry is refused.
        #expect(throws: HookFileWriter.Failure.self) { try writer.update(stale, to: HookDraft(event: "Stop", handler: .command("x"))) }
        let moved = try writer.update(entries[2], to: HookDraft(event: "PreToolUse", matcher: "Bash", handler: .command("./lint.sh")))
        entries = f.catalog.load().entries
        #expect(entries.first { $0.hash == moved }?.slot.hasSuffix("#PreToolUse/1/0") == true)

        for entry in entries.reversed() { try writer.delete(entry) }
        text = try String(contentsOfFile: path, encoding: .utf8)
        #expect(text == "{\n  \"model\": \"opus\",\n  \"permissions\": {\n    \"allow\": [\n      \"Bash(ls)\"\n    ]\n  },\n  \"hooks\": {},\n  \"zeta\": true\n}\n")
        #expect(f.catalog.trustStore.read().trusted.isEmpty)
    }

    @Test func aNewFileAndItsFoldersAreCreatedAndTomlIsRefused() throws {
        let f = try HookCatalogTests.Fixture(); defer { f.remove() }
        let writer = HookFileWriter(trust: f.catalog.trustStore)
        let path = f.space + "/.shepherd/hooks.json"
        try writer.add(HookDraft(event: "Stop", handler: .command("npm test")), to: path)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == """
        {
          "hooks": {
            "Stop": [
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "npm test"
                  }
                ]
              }
            ]
          }
        }

        """)
        #expect(throws: HookFileWriter.Failure.self) {
            try writer.add(HookDraft(event: "Stop", handler: .command("x")), to: f.home + "/.codex/config.toml")
        }
        try f.write(f.home + "/.shepherd/hooks.json", "{ broken")
        #expect(throws: HookFileWriter.Failure.self) {
            try writer.add(HookDraft(event: "Stop", handler: .command("x")), to: f.home + "/.shepherd/hooks.json")
        }
        #expect(try String(contentsOfFile: f.home + "/.shepherd/hooks.json", encoding: .utf8) == "{ broken")
    }
}
