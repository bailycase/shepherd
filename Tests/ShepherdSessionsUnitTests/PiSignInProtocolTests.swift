import Foundation
import Testing
@testable import ShepherdSessions

/// The sign-in bridge's JSON lines (`Extensions/shepherd-sign-in.mjs`): what the app sends, what
/// it reads back, and what a key becomes in auth.json. The bridge itself runs in
/// `PiSignInBridgeTests`.
@Suite("Sign-in bridge protocol")
struct PiSignInProtocolTests {
    struct Command: CustomTestStringConvertible, Sendable {
        let command: PiSignInCommand
        let json: String
        var testDescription: String { json }
    }

    static let commands: [Command] = [
        Command(command: .login(provider: "anthropic", method: .oauth, flow: .browser),
                json: #"{"flow":"browser","method":"oauth","provider":"anthropic","type":"login"}"#),
        Command(command: .login(provider: "deepseek", method: .apiKey, flow: .device),
                json: #"{"flow":"device","method":"api_key","provider":"deepseek","type":"login"}"#),
        Command(command: .answer(id: "p1", value: "code#state"), json: #"{"id":"p1","type":"answer","value":"code#state"}"#),
        Command(command: .cancel, json: #"{"type":"cancel"}"#),
        Command(command: .logout(provider: "kimi-coding"), json: #"{"provider":"kimi-coding","type":"logout"}"#),
        Command(command: .check(id: "c1", provider: "deepseek", key: .literal("sk-1")),
                json: #"{"id":"c1","key":"sk-1","provider":"deepseek","type":"check"}"#),
        Command(command: .check(id: "c2", provider: "deepseek", key: .variable("DEEPSEEK_API_KEY")),
                json: #"{"id":"c2","provider":"deepseek","type":"check","variable":"DEEPSEEK_API_KEY"}"#),
    ]

    @Test(arguments: commands)
    func eachCommandIsOneJSONLine(row: Command) {
        #expect(String(decoding: row.command.line, as: UTF8.self) == row.json + "\n")
    }

    struct Reply: CustomTestStringConvertible, Sendable {
        let json: String
        let reply: PiSignInReply?
        var testDescription: String { json }
    }

    static let replies: [Reply] = [
        Reply(json: #"{"type":"ready"}"#, reply: .ready),
        Reply(json: #"{"type":"event","event":{"type":"auth_url","url":"https://claude.ai/oauth/authorize?x=1","instructions":"Complete login"}}"#,
              reply: .authURL(URL(string: "https://claude.ai/oauth/authorize?x=1")!, instructions: "Complete login")),
        // Only a web page is ever opened.
        Reply(json: #"{"type":"event","event":{"type":"auth_url","url":"file:///etc/passwd"}}"#, reply: nil),
        Reply(json: #"{"type":"event","event":{"type":"device_code","userCode":"8F3K-Q2WD","verificationUri":"https://github.com/login/device","expiresInSeconds":900}}"#,
              reply: .deviceCode(code: "8F3K-Q2WD", verificationURI: "https://github.com/login/device", expiresIn: 900)),
        Reply(json: #"{"type":"event","event":{"type":"progress","message":"Exchanging…"}}"#, reply: .progress("Exchanging…")),
        Reply(json: #"{"type":"event","event":{"type":"info","message":"Configured elsewhere"}}"#, reply: .info("Configured elsewhere")),
        Reply(json: #"{"type":"prompt","id":"p1","kind":"manual_code","message":"Paste","placeholder":"http://localhost"}"#,
              reply: .prompt(PiSignInPrompt(id: "p1", kind: .manualCode, message: "Paste", placeholder: "http://localhost"))),
        Reply(json: #"{"type":"prompt","id":"p2","kind":"select","message":"How?","options":[{"id":"a","label":"A"}]}"#,
              reply: .prompt(PiSignInPrompt(id: "p2", kind: .select, message: "How?", options: [.init(id: "a", label: "A")]))),
        Reply(json: #"{"type":"prompt","id":"p3","kind":"telepathy","message":"?"}"#, reply: nil),
        Reply(json: #"{"type":"promptClosed","id":"p1"}"#, reply: .promptClosed("p1")),
        Reply(json: #"{"type":"done","provider":"anthropic","credential":"oauth"}"#, reply: .done(provider: "anthropic", subscription: true)),
        Reply(json: #"{"type":"done","provider":"deepseek","credential":"api_key"}"#, reply: .done(provider: "deepseek", subscription: false)),
        Reply(json: #"{"type":"failed","code":"portBusy","port":1455,"reason":"busy"}"#,
              reply: .failed(PiSignInFailure(.portBusy, reason: "busy", port: 1455))),
        Reply(json: #"{"type":"failed","code":"somethingNew","reason":"x"}"#, reply: .failed(PiSignInFailure(.other, reason: "x"))),
        Reply(json: #"{"type":"checked","id":"c1","result":"works","models":["m1"]}"#, reply: .checked(id: "c1", .works(models: ["m1"]))),
        Reply(json: #"{"type":"checked","id":"c1","result":"rejected","reason":"401"}"#, reply: .checked(id: "c1", .rejected("401"))),
        Reply(json: #"{"type":"checked","id":"c1","result":"unset","reason":"not set"}"#, reply: .checked(id: "c1", .unset("not set"))),
        Reply(json: #"{"type":"checked","id":"c1","result":"unreachable","reason":"offline"}"#, reply: .checked(id: "c1", .unreachable("offline"))),
        Reply(json: #"{"type":"loggedOut","provider":"anthropic"}"#, reply: .loggedOut(provider: "anthropic")),
        Reply(json: #"{"type":"somethingElse"}"#, reply: nil),
        Reply(json: #"not json"#, reply: nil),
    ]

    @Test(arguments: replies)
    func eachReplyParses(row: Reply) {
        #expect(PiSignInReply.parse(Data(row.json.utf8)) == row.reply)
    }

    @Test(arguments: [
        (PiKeyInput.literal("sk-proj-abc"), "sk-proj-abc"),
        (.literal("sk-$HOME-x"), "sk-$$HOME-x"),
        (.literal("!rm -rf"), "$!rm -rf"),
        (.literal("!a$b"), "$!a$$b"),
        (.variable("DEEPSEEK_API_KEY"), "$DEEPSEEK_API_KEY"),
    ])
    func aKeyIsStoredSoPiReadsItAsTyped(input: PiKeyInput, stored: String) {
        #expect(input.stored == stored)
    }

    @Test func theBridgeRunsOnTheEnginesNodeInTheHomeWithThePinsAfterTheLoginShell() {
        let home = PiHome(directory: URL(fileURLWithPath: "/Users/me/Library/Application Support/Shepherd/pi", isDirectory: true),
                          engine: PiLaunchTests.engine)
        let line = PiLaunch.signInBridge(node: .executable("/A/Helpers/node"), script: "/S/shepherd-sign-in.mjs",
                                         sdk: "/A/pi-engine/dist/bundle/index.js", home: home)
        #expect(line.argv.prefix(3) == ["/bin/zsh", "-l", "-c"])
        #expect(line.script == PiLaunchTests.clearing
            + "export PI_CODING_AGENT_DIR='/Users/me/Library/Application Support/Shepherd/pi' PI_OFFLINE=1 PI_SKIP_VERSION_CHECK=1 PI_TELEMETRY=0; "
            + "cd -- '/Users/me/Library/Application Support/Shepherd/pi' && exec '/A/Helpers/node' \"$0\" \"$1\" \"$2\"")
        #expect(line.positional == ["/S/shepherd-sign-in.mjs", "/A/pi-engine/dist/bundle/index.js", "/Users/me/Library/Application Support/Shepherd/pi"])
    }
}
