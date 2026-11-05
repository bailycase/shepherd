import Foundation
import ShepherdProtocol
import Testing
@testable import ShepherdRemote

/// Hook rows, proposals and asks as the thread draws them (Proposals).
struct HookPresentationTests {
    static func details(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    @Test func aRecordReadsTheContractsDetailsAndClipsThem() throws {
        let long = String(repeating: "x", count: NativeHookRecord.maxText + 10)
        let record = try #require(NativeHookRecord(details: Self.details(#"""
        {"kind":"denied","event":"PreToolUse","name":"no-env.sh","detail":"Edit|Write · edit .env",
         "lines":["No edits to .env files.\nPut secrets in the keychain.","\#(long)"],"meta":"./no-env.sh · exit 2 · 41 ms","hash":"abc","file":"/r/.shepherd/hooks.json"}
        """#)))
        #expect(record.kind == "denied" && record.event == "PreToolUse" && record.hash == "abc")
        #expect(record.lines.count == 3 && record.lines[1] == "Put secrets in the keychain.")
        #expect(record.lines[2].count == NativeHookRecord.maxText + 1)
        #expect(try NativeHookRecord(details: Self.details(#"{"event":"Stop"}"#)) == nil, "no kind, no record")
        #expect(NativeHookRecord(details: nil) == nil)
    }

    @Test(arguments: [
        ("ran", "Stop", nil as String?, "Ran a hook"),
        ("denied", "PreToolUse", nil, "A hook denied a tool call"),
        ("denied", "UserPromptSubmit", nil, "A hook blocked your message"),
        ("sentBack", "Stop", nil, "A hook sent the agent back"),
        ("sentBack", "PostToolUse", nil, "A hook sent feedback to the agent"),
        ("added", "PostToolUse", nil, "Added a hook"),
        ("failed", "Notification", "osascript · exit 127 · 9 ms", "A hook failed"),
        ("failed", "PreToolUse", "./no-env.sh · timed out · 10000 ms", "A hook timed out; the agent went ahead"),
        ("context", "SessionStart", nil, "A hook added context"),
        ("asked", "PreToolUse", nil, "A hook asked you first"),
        ("systemMessage", "Stop", nil, "A hook says"),
        ("someday", "Stop", nil, "Ran a hook"),
    ])
    func everyKindHasItsVerb(kind: String, event: String, meta: String?, verb: String) {
        let row = NativeHookRow(NativeHookRecord(kind: kind, event: event, name: "check", detail: "Bash · ls", meta: meta, hash: "h"))
        #expect(row.verb == verb)
        #expect(row.detail == "\(event) · Bash · ls")
    }

    @Test func boxesAndLinksFollowTheKind() {
        let denied = NativeHookRow(NativeHookRecord(kind: "denied", event: "PreToolUse", name: "n", lines: ["No"], meta: "m", hash: "h"))
        #expect(denied.hasBox && denied.link == .openHook(hash: "h"))
        let ran = NativeHookRow(NativeHookRecord(kind: "ran", event: "Stop", name: "npm test", meta: "npm test · exit 0 · 8 ms", hash: "h"))
        #expect(!ran.hasBox && ran.link == nil && ran.detail == "Stop · npm test", "a quiet run is one line: the name when it has no detail")
        let noHash = NativeHookRow(NativeHookRecord(kind: "failed", event: "Stop", name: "n", meta: "x · exit 1 · 2 ms"))
        #expect(noHash.hasBox && noHash.link == nil)
    }

    @Test func theTurnDrawsAHookMessageAsItsRowAndFallsBackToItsText() {
        let record = NativeHookRecord(kind: "context", event: "SessionStart", name: "notes", lines: ["Read /v2"])
        var withRecord = NativeThreadMessage(entryID: "h1", role: "custom", blocks: [.init(kind: .text, text: "notes (SessionStart)")], customType: "shepherd.hook")
        withRecord.hook = record
        let older = NativeThreadMessage(entryID: "h2", role: "custom", blocks: [.init(kind: .text, text: "Hook ran: check (Stop)\nmore")], customType: "shepherd.hook")
        let presentation = nativeTurnPresentation([withRecord, older], live: false)
        let rows = presentation.items.compactMap { item -> NativeHookRow? in if case .hook(_, let row) = item { row } else { nil } }
        #expect(rows.count == 2)
        #expect(rows[0] == NativeHookRow(record))
        #expect(rows[1].verb == "Hook ran: check (Stop)" && rows[1].lines == ["more"] && rows[1].kind == .ran)
    }

    @Test func aProposalDialogParsesAndAnswersWithTheContractsOptions() throws {
        let card = #"{"name":"Format after edits","event":"PostToolUse","matcher":"Edit|Write","command":"npx prettier --write","statusMessage":"Formatting edited files","timeout":null,"scopes":{"space":"/r/.shepherd/hooks.json","mac":"/h/.shepherd/hooks.json"},"scope":"space","test":{"ok":true,"summary":"exit 0, no output","exit":0,"ms":412}}"#
        let dialog = NativeThreadDialog(id: "d1", kind: .select, title: NativeHookProposal.marker + "\n" + card,
                                        options: [NativeHookProposal.addToSpace, NativeHookProposal.addToMac, NativeHookProposal.notNow])
        let proposal = try #require(NativeHookProposal(dialog: dialog))
        #expect(proposal.name == "Format after edits" && proposal.matcher == "Edit|Write" && proposal.scope == "space")
        #expect(proposal.addOption(scope: "space") == "Add to this space" && proposal.addOption(scope: "mac") == "Add to this Mac")
        #expect(proposal.path(scope: "mac") == "/h/.shepherd/hooks.json" && proposal.testMeta == "exit 0 · 412 ms")
        #expect(NativeHookPrompt(dialog) == .proposal(proposal))
        let plain = NativeThreadDialog(id: "d2", kind: .select, title: "Pick one", options: ["A", "B"])
        #expect(NativeHookProposal(dialog: plain) == nil && NativeHookPrompt(plain) == nil)
        let broken = NativeThreadDialog(id: "d3", kind: .select, title: NativeHookProposal.marker + "\n{", options: ["Not now"])
        #expect(NativeHookPrompt(broken) == nil, "a card that doesn't parse stays an ordinary question")
        #expect(NativeHookPrompt.isConsent(broken), "but no Project may answer it")
        #expect(!NativeHookPrompt.isConsent(plain))
    }

    /// A client that draws no card (iOS) shows a hook's prompt in the question dock: a human title and
    /// everything trusted unfolded, never the card's JSON.
    @Test func theQuestionDockShowsAHookPromptReadably() throws {
        let command = String(repeating: "long-command ", count: 40) + "&& rm -rf ./build"
        let card = #"{"name":"Clean","event":"Stop","matcher":"","command":""# + command + #"","scopes":{"space":"/r/.shepherd/hooks.json","mac":"/h/.shepherd/hooks.json"},"scope":"space","test":{"ok":true,"summary":"exit 0, no output"}}"#
        let proposal = NativeQuestionPrompt(dialog: NativeThreadDialog(id: "d", kind: .select, title: NativeHookProposal.marker + "\n" + card,
                                                                        options: [NativeHookProposal.addToSpace, NativeHookProposal.addToMac, NativeHookProposal.notNow, NativeHookProposal.addedInSettings]))
        #expect(proposal.question == "Add the hook “Clean”?" && proposal.details == nil)
        let message = try #require(proposal.message)
        #expect(message.contains(command) && message.contains("When: Stop") && message.contains("Matcher: always")
                && message.contains("Saved in: /r/.shepherd/hooks.json") && message.contains("Tested: exit 0"))
        #expect(!message.contains("{") && !proposal.question.contains(NativeHookProposal.marker))
        #expect(proposal.options.map(\.value) == [NativeHookProposal.addToSpace, NativeHookProposal.addToMac, NativeHookProposal.notNow])

        let ask = NativeQuestionPrompt(dialog: NativeThreadDialog(id: "a", kind: .select,
            title: "A hook asks before this runs\n\nbash \(command)\n\nNeeds a person.\n\n/h/.shepherd/hooks.json", options: ["Deny", "Allow once"]))
        #expect(ask.question == NativeHookAsk.title && ask.details == nil)
        #expect(ask.message?.contains("bash \(command)") == true && ask.message?.contains("Hook: /h/.shepherd/hooks.json") == true
                && ask.message?.contains("Event: PreToolUse") == true)
    }

    @Test func aProposalSaysWhenItsTestWasBlocked() throws {
        func lead(_ test: String) throws -> String {
            let card = #"{"name":"n","event":"Stop","command":"c","scopes":{"mac":"/h"},"test":"# + test + "}"
            let dialog = NativeThreadDialog(id: "d", kind: .select, title: NativeHookProposal.marker + "\n" + card, options: [NativeHookProposal.notNow])
            return try #require(NativeHookProposal(dialog: dialog)).testLead
        }
        #expect(try lead(#"{"ok":true,"summary":"s"}"#) == "Tested: ")
        #expect(try lead(#"{"ok":false,"summary":"s","exit":1}"#) == "Test didn’t pass: ")
        #expect(try lead(#"{"ok":false,"blocked":true,"summary":"blocked by a PreToolUse hook: no","exit":null}"#) == "Test didn’t run: ")
    }

    @Test func aHooksAskParsesItsCallReasonAndFile() throws {
        let dialog = NativeThreadDialog(id: "a1", kind: .select,
                                        title: "A hook asks before this runs\n\nbash · rm -rf ./build\n\nrm -rf needs a person.\n\n/h/.shepherd/hooks.json",
                                        options: ["Deny", "Allow once"])
        let ask = try #require(NativeHookAsk(dialog: dialog))
        #expect(ask.call == "bash · rm -rf ./build" && ask.reason == "rm -rf needs a person." && ask.file == "/h/.shepherd/hooks.json")
        #expect(NativeHookPrompt(dialog) == .ask(ask))
        let script = "cat <<EOF > notes\nfirst\n\nsecond\nEOF"
        let whole = try #require(NativeHookAsk(dialog: NativeThreadDialog(id: "a3", kind: .select,
            title: "A hook asks before this runs\n\nbash \(script)\n\nWhy.\n\n/h/hooks.json", options: ["Deny", "Allow once"])))
        #expect(whole.call == "bash \(script)" && whole.reason == "Why." && whole.file == "/h/hooks.json", "a call with blank lines stays whole")
        let other = NativeThreadDialog(id: "a2", kind: .select, title: "A hook asks before this runs", options: ["Yes", "No"])
        #expect(NativeHookAsk(dialog: other) == nil, "only the contract's two options")
    }

    @Test func aRunningHooksStatusIsTheLiveLine() {
        #expect(NativeLiveWait(nil, hookStatus: "Checking the path").title == "Checking the path…")
        #expect(NativeLiveWait(nil, hookStatus: "Formatting…").title == "Formatting…")
        #expect(NativeLiveWait(nil).title == "Waiting for response")
    }
}
