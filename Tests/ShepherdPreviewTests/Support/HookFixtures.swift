import Foundation
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport
@testable import ShepherdApp

/// A scratch home and support folder with the hooks the Hooks boards show, read through the real
/// catalog: This Mac's three files, a space ("payments") with hooks in two files, one switched off,
/// "ledger" and one whose Codex file doesn't parse ("web"). Never the user's home.
@MainActor
final class HookFixture {
    let dir: URL
    var home: String { dir.appendingPathComponent("home").path }
    var support: URL { dir.appendingPathComponent("support") }
    var payments: String { home + "/code/payments" }
    var ledger: String { home + "/code/ledger" }
    var web: String { home + "/code/web" }
    let model: HooksModel

    static let noEnv = #""$CLAUDE_PROJECT_DIR"/.shepherd/hooks/no-env.sh"#

    init(empty: Bool = false) throws {
        dir = URL(fileURLWithPath: PiHome.canonical(try makeScratchDirectory("hooks").path))
        model = HooksModel(home: dir.appendingPathComponent("home").path, support: dir.appendingPathComponent("support"))
        for space in [payments, ledger, web] { try FileManager.default.createDirectory(atPath: space + "/.git", withIntermediateDirectories: true) }
        let spaces = [payments, ledger, web]
        model.spacePaths = { spaces }
        guard !empty else { return }
        try write(home + "/.shepherd/hooks.json", #"{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"~/.shepherd/hooks/confirm-rm.sh"}]}]}}"#)
        try write(home + "/.claude/settings.json", #"""
        {"model":"opus","hooks":{"SessionStart":[{"matcher":"startup|resume","hooks":[{"type":"command","command":"python3 ~/.claude/hooks/session_notes.py"}]}],
         "Notification":[{"hooks":[{"type":"command","command":"osascript -e 'display notification \"Needs you\"'"}]}]}}
        """#)
        try write(home + "/.codex/hooks.json", #"{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"python3 ~/.codex/hooks/scan_secrets.py"}]}]}}"#)
        let spaceFile = #"""
        {"hooks":{"PreToolUse":[{"matcher":"Edit|Write","hooks":[{"type":"command","command":"\"$CLAUDE_PROJECT_DIR\"/.shepherd/hooks/no-env.sh","timeout":10,"statusMessage":"Checking the path"}]}],
         "Stop":[{"hooks":[{"type":"command","command":"npm test --silent"}]}]}}
        """#
        try write(payments + "/.shepherd/hooks.json", spaceFile)
        try write(payments + "/.shepherd/hooks/no-env.sh", "#!/bin/sh\ncat >/dev/null\necho 'No edits to .env files.' >&2\nexit 2\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: payments + "/.shepherd/hooks/no-env.sh")
        try write(payments + "/.claude/settings.json", #"{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"git-guard push --ask-on main","timeout":30}]}]}}"#)
        try write(ledger + "/.claude/settings.json", #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"make check"},{"type":"command","command":"make lint"}]}]}}"#)
        try write(web + "/.codex/hooks.json", "{\n  \"hooks\": {\n    \"Stop\": [\n      {\n        \"hooks\": [\n          {\n            \"type\": \"command\",\n            \"command\": \"pnpm test\"\n          }\n        ]\n      }\n    ]\n  }\n\n\n\n  \"x\": 1\n}\n")
        try write(payments + "/.shepherd/hooks.json", spaceFile.replacingOccurrences(of: #""Stop":"#, with: #""PostToolUse":[{"matcher":"Edit|Write","hooks":[{"type":"command","command":"jq -r .tool_input.file_path | xargs npx prettier --write","statusMessage":"Formatting edited files"}]}],"Stop":"#))
        // One switched off in Settings.
        let catalog = model.catalog
        if let lint = catalog.load(spaceRoots: [ledger]).entries.first(where: { $0.handler.command == "make lint" }) {
            try catalog.settingsStore.setOn(lint.hash, false)
        }
    }

    func write(_ path: String, _ text: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Loads the catalog and waits for it.
    func load() async throws {
        // The workspace's view model points the model at its own spaces; these are the fixture's.
        let spaces = [payments, ledger, web]
        model.spacePaths = { spaces }
        model.reload()
        let model = model
        try await eventuallyOnMain("the hooks catalog to load") { model.snapshot != nil && !model.loading }
    }

    func remove() { try? FileManager.default.removeItem(at: dir) }
}

/// Threads with each kind of hook row, built from the messages the runtime posts
/// (`shepherd.hook` custom messages) through the host's own projection.
enum HookThreads {
    static func hook(_ id: String, _ details: String, content: String) -> NativeThreadMessage {
        let json = #"{"role":"custom","customType":"shepherd.hook","display":true,"content":\#(quoted(content)),"details":\#(details)}"#
        let message = try! JSONDecoder().decode(RPCMessage.self, from: Data(json.utf8))
        return RPCThreadState.project(entryID: id, message: message)
    }

    static func quoted(_ text: String) -> String { String(decoding: try! JSONEncoder().encode(text), as: UTF8.self) }

    static func user(_ id: String, _ text: String) -> NativeThreadMessage {
        NativeThreadMessage(entryID: id, role: "user", blocks: [.init(kind: .text, text: text)])
    }

    static func say(_ id: String, _ text: String) -> NativeThreadMessage {
        NativeThreadMessage(entryID: id, role: "assistant", blocks: [.init(kind: .text, text: text)])
    }

    static func tool(_ id: String, _ name: String, _ args: String) -> NativeThreadMessage {
        NativeThreadMessage(entryID: id, role: "toolResult", blocks: [.init(kind: .text, text: "ok")], toolName: name, toolCallID: "c-" + id,
                            argumentsText: args, status: "complete")
    }

    static func snapshot(_ messages: [NativeThreadMessage], running: Bool = false, dialogs: [NativeThreadDialog] = [],
                         hookStatus: String? = nil) -> NativeThreadSnapshot {
        var snapshot = NativeThreadSnapshot(piSessionID: "fixture", generation: "g", revision: 1, running: running, model: "anthropic/claude-opus-4-5",
                                            thinking: "medium", supportedActions: ["send", "abort", "answer", "setModel", "setThinking"],
                                            dialogsSupported: true, dialogs: dialogs, messages: messages, provisional: [], clipped: false, runtime: "rpc")
        snapshot.hookStatus = hookStatus
        return snapshot
    }

    /// Every row kind in one thread: denied, sent back, added, failed (timed out and exit), context,
    /// asked, ran, and a system message.
    static func everyKind(file: String) -> NativeThreadSnapshot {
        snapshot([
            hook("h1", #"{"kind":"context","event":"SessionStart","name":"session_notes.py","detail":"startup","lines":["Notes from your last session in payments:","- The ledger page reads /v2/ledger; v1 is gone.","- CSV exports go through src/export/csv.ts."],"meta":"python3 ~/.claude/hooks/session_notes.py · exit 0 · 312 ms"}"#,
                 content: "session_notes.py added context (SessionStart)"),
            user("u1", "Refunds of half a cent round the wrong way. Fix it, and put the Stripe test key in .env so the tests can reach the sandbox."),
            hook("h2", #"{"kind":"ran","event":"UserPromptSubmit","name":"scan_secrets.py","detail":"scan_secrets.py · nothing found","meta":"python3 ~/.codex/hooks/scan_secrets.py · exit 0 · 80 ms"}"#,
                 content: "Hook ran: scan_secrets.py (UserPromptSubmit)"),
            tool("t1", "read", #"{"path":"src/refunds/round.ts"}"#),
            tool("t2", "edit", #"{"path":"src/refunds/round.ts","edits":[{"oldText":"a","newText":"b"}]}"#),
            hook("h3", #"{"kind":"denied","event":"PreToolUse","name":"Checking the path","detail":"Edit|Write · edit .env","lines":["No edits to .env files. Put secrets in the keychain."],"meta":"\"$CLAUDE_PROJECT_DIR\"/.shepherd/hooks/no-env.sh · exit 2 · 41 ms","hash":"h-noenv","file":"\#(file)"}"#,
                 content: "A hook denied edit .env: No edits to .env files."),
            say("a1", "A hook in this space denies edits to .env, so I didn’t add the key. I added STRIPE_TEST_KEY to .env.example; put the real key in .env yourself."),
            hook("h4", #"{"kind":"sentBack","event":"Stop","name":"npm","detail":"npm test --silent · 1 failing","lines":["FAIL src/refunds/round.test.ts","  rounds half-cent refunds down","    expected 12.35, got 12.34"],"meta":"npm test --silent · exit 2 · 8204 ms · the agent sees this output","hash":"h-npm","file":"\#(file)"}"#,
                 content: "A Stop hook (npm) sent you back"),
            hook("h5", #"{"kind":"failed","event":"PreToolUse","name":"Checking the path","detail":"Edit|Write · edit test/fixtures/README.md","lines":["Stopped after 10 s with no output.","Only exit 2 or a deny decision blocks a call."],"meta":"\"$CLAUDE_PROJECT_DIR\"/.shepherd/hooks/no-env.sh · timed out · 10000 ms","hash":"h-noenv","file":"\#(file)"}"#,
                 content: "A hook failed: no-env.sh (PreToolUse)"),
            hook("h6", #"{"kind":"failed","event":"Notification","name":"osascript","detail":"question","meta":"osascript -e 'display notification' · exit 127 · 9 ms","hash":"h-osa","file":"\#(file)"}"#,
                 content: "A hook failed: osascript (Notification)"),
            hook("h7", #"{"kind":"asked","event":"PreToolUse","name":"confirm-rm.sh","detail":"Bash · bash rm -rf ./build","lines":["rm -rf outside a temp folder needs a person to say yes."],"meta":"~/.shepherd/hooks/confirm-rm.sh · exit 0 · 22 ms"}"#,
                 content: "A hook asked before bash rm -rf ./build: allowed once"),
            hook("h8", #"{"kind":"added","event":"PostToolUse","name":"Formatting edited files","detail":"Edit|Write","meta":"jq -r .tool_input.file_path | xargs npx prettier --write","hash":"h-fmt","file":"\#(file)"}"#,
                 content: "Hook added: Formatting edited files (PostToolUse)"),
            hook("h9", #"{"kind":"systemMessage","event":"Stop","name":"npm","lines":["214 tests passed."],"meta":"npm test --silent · exit 0 · 8.0 s"}"#,
                 content: "npm: 214 tests passed."),
            NativeThreadMessage(entryID: "h10", role: "custom", blocks: [.init(kind: .text, text: "Hook ran: lint (Stop)")], customType: "shepherd.hook"),
        ])
    }

    /// The working thread whose PostToolUse hook runs now: its status is the live line.
    static var running: NativeThreadSnapshot {
        snapshot([user("u1", "Add a monthly CSV export to the ledger page."), tool("t1", "read", #"{"path":"src/export/csv.ts"}"#),
                  tool("t2", "edit", #"{"path":"src/ledger/export.ts","edits":[{"oldText":"a","newText":"b"}]}"#)],
                 running: true, hookStatus: "Checking the path")
    }

    static func propose(space: String, mac: String) -> NativeThreadSnapshot {
        let card = #"{"name":"Format after edits","event":"PostToolUse","matcher":"Edit|Write","command":"f=$(jq -r .tool_input.file_path)\n[ -n \"$f\" ] || exit 0\nnpx prettier --write \"$f\" --log-level warn --config \"$CLAUDE_PROJECT_DIR/.prettierrc\" --ignore-path \"$CLAUDE_PROJECT_DIR/.prettierignore\"","statusMessage":"Formatting edited files","timeout":null,"scopes":{"space":"\#(space)","mac":"\#(mac)"},"scope":"space","test":{"ok":true,"summary":"exit 0: reformatted 3 lines in a copy of round.ts","exit":0,"ms":412}}"#
        return snapshot([user("u1", "Run prettier on the files you change in this repo, from now on."), tool("t1", "read", #"{"path":"package.json"}"#),
                         say("a1", "Here’s the hook. I tested it on a copy of round.ts and it reformatted 3 lines. Add it, or tell me what to change.")],
                        running: true,
                        dialogs: [NativeThreadDialog(id: "p1", kind: .select, title: NativeHookProposal.marker + "\n" + card,
                                                     options: ["Add to this space", "Add to this Mac", "Not now", NativeHookProposal.addedInSettings])])
    }

    static func ask(file: String) -> NativeThreadSnapshot {
        snapshot([user("u1", "The build is stale. Clear the caches and rebuild."), tool("t1", "read", #"{"path":"package.json"}"#)],
                 running: true,
                 dialogs: [NativeThreadDialog(id: "q1", kind: .select,
                                              title: "A hook asks before this runs\n\nbash rm -rf ./build ./node_modules/.cache ./dist ./coverage ./.turbo ./packages/*/dist ./packages/*/node_modules/.cache && npm ci --prefer-offline && npm run build\n\nrm -rf outside a temp folder needs a person to say yes.\n\n\(file)",
                                              options: ["Deny", "Allow once"])])
    }
}
