import Foundation
import ShepherdSessions
import ShepherdTestSupport
import Testing

/// The sign-in bridge for real: `shepherd-sign-in.mjs` on node, in a login shell, driving a fake
/// pi SDK (`FakePiSDK`) against a scratch Shepherd home, through each path the sheet takes: the
/// browser's callback, a pasted code (and one the provider refuses), a device code, a port in
/// use, a key with its check, cancel, and sign-out. A scratch "your pi" beside it stays
/// byte-identical, and no reply carries a credential.
@Suite("Sign-in bridge", .serialized, .integrationTimeLimit, .enabled(if: TestNode.url != nil, "needs node 22.6 or later"))
struct PiSignInBridgeTests {
    /// A scratch home, a scratch "your pi" with a login of its own, and the control folder.
    struct Setup {
        let dir: URL
        let home: URL
        let yours: URL
        let control: URL

        init() throws {
            dir = try makeScratchDirectory("signin")
            home = dir.appendingPathComponent("support/pi", isDirectory: true)
            yours = dir.appendingPathComponent("user/.pi/agent", isDirectory: true)
            control = dir.appendingPathComponent("control", isDirectory: true)
            for folder in [home, yours, control] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
            try Data(#"{"anthropic":{"type":"oauth","access":"theirs-access-0001","refresh":"theirs-refresh-0001","expires":1}}"#.utf8)
                .write(to: yours.appendingPathComponent("auth.json"))
        }

        func bridge() throws -> Replies {
            let node = try #require(TestNode.url)
            let script = try PiSignInScript.install(in: dir)
            let piHome = PiHome(directory: home, engine: PiEngine(command: ["/usr/bin/false"], packageDirectory: nil, version: nil,
                                                                  node: .executable(node.path)))
            let line = PiLaunch.signInBridge(node: .executable(node.path), script: script.path, sdk: FakePiSDK.path, home: piHome)
            var environment = ProcessInfo.processInfo.environment
            environment["FAKE_PI_CONTROL"] = control.path
            environment["SHEPHERD_TEST_KEY_VAR"] = nil
            return Replies(PiSignInBridge(line: line, environment: environment))
        }

        func auth() throws -> [String: Any] {
            guard let data = try? Data(contentsOf: home.appendingPathComponent("auth.json")) else { return [:] }
            return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        func remove() { try? FileManager.default.removeItem(at: dir) }
    }

    /// Every reply the bridge sent, as it arrives.
    final class Replies: @unchecked Sendable {
        let bridge: PiSignInBridge
        private let seen = Locked<[PiSignInReply]>([])
        private var reader: Task<Void, Never>?

        init(_ bridge: PiSignInBridge) {
            self.bridge = bridge
            reader = Task { [seen] in
                for await reply in bridge.replies { seen.withValue { $0.append(reply) } }
            }
        }

        var all: [PiSignInReply] { seen.current }

        /// The first reply `match` picks, once it has come.
        @discardableResult
        func first<T>(_ what: String, _ match: @escaping (PiSignInReply) -> T?) async throws -> T {
            var found: T?
            do {
                try await eventually(what, timeout: .seconds(15)) {
                    found = seen.current.lazy.compactMap(match).first
                    return found != nil
                }
            } catch {
                throw CommandFailure("waiting for \(what)", "the bridge said \(seen.current)")
            }
            return found!
        }

        func prompt(_ kind: PiSignInPrompt.Kind) async throws -> PiSignInPrompt {
            try await first("a \(kind) prompt") { if case .prompt(let p) = $0, p.kind == kind { p } else { nil } }
        }

        func done() async throws -> Bool {
            try await first("the sign-in to land") { if case .done(_, let subscription) = $0 { subscription } else { nil } }
        }

        func failure() async throws -> PiSignInFailure {
            try await first("the sign-in to fail") { if case .failed(let f) = $0 { f } else { nil } }
        }

        func close() {
            bridge.close()
        }

        /// No reply names a credential's value.
        func expectNoSecrets(_ extra: [String] = [], sourceLocation: SourceLocation = #_sourceLocation) {
            let text = String(describing: all)
            for secret in FakePiSDK.secrets + extra { #expect(!text.contains(secret), "a reply carried a credential", sourceLocation: sourceLocation) }
        }
    }

    static func tree(_ folder: URL) throws -> [String: Data] {
        var files: [String: Data] = [:]
        for case let url as URL in FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) ?? .init() {
            if let data = try? Data(contentsOf: url) { files[url.lastPathComponent] = data }
        }
        return files
    }

    @Test func aBrowserSignInLandsWhenTheCallbackComesAndTheCodePromptCloses() async throws {
        let setup = try Setup()
        defer { setup.remove() }
        let before = try Self.tree(setup.yours)
        let replies = try setup.bridge()
        defer { replies.close() }
        try await replies.first("ready") { $0 == .ready ? true : nil }
        replies.bridge.send(.login(provider: "anthropic", method: .oauth, flow: .browser))

        let instructions = try await replies.first("the page to open") { if case .authURL(_, let text) = $0 { text } else { nil } }
        let prompt = try await replies.prompt(.manualCode)
        let callback = try #require(instructions.split(separator: " ").last.flatMap { URL(string: String($0) + "?code=FAKE-CODE") })
        _ = try await URLSession.shared.data(from: callback)

        #expect(try await replies.done(), "an account sign-in")
        try await replies.first("the code prompt to close") { $0 == .promptClosed(prompt.id) ? true : nil }
        let auth = try setup.auth()
        #expect((auth["anthropic"] as? [String: Any])?["type"] as? String == "oauth")
        #expect(try Self.tree(setup.yours) == before, "your pi is untouched")
        replies.expectNoSecrets()
    }

    @Test func aPastedCodeSignsInAndOneTheProviderRefusesSaysWhy() async throws {
        let setup = try Setup()
        defer { setup.remove() }
        let replies = try setup.bridge()
        defer { replies.close() }
        replies.bridge.send(.login(provider: "anthropic", method: .oauth, flow: .browser))
        let first = try await replies.prompt(.manualCode)
        replies.bridge.send(.answer(id: first.id, value: "USED-CODE#fake-state"))
        let failure = try await replies.failure()
        #expect(failure.code == .other && failure.reason.contains("already used"))
        #expect(try setup.auth()["anthropic"] == nil, "nothing saved")

        // Open the page again: a new login, and the good code.
        replies.bridge.send(.login(provider: "anthropic", method: .oauth, flow: .browser))
        let second = try await replies.first("a second code prompt") { if case .prompt(let p) = $0, p.id != first.id { p } else { nil } }
        replies.bridge.send(.answer(id: second.id, value: "\(FakePiSDK.goodCode)#fake-state"))
        #expect(try await replies.done())
        #expect(try setup.auth()["anthropic"] != nil)
        replies.expectNoSecrets()
    }

    @Test func aDeviceCodeSignInShowsTheCodeAndLandsWhenApproved() async throws {
        let setup = try Setup()
        defer { setup.remove() }
        let replies = try setup.bridge()
        defer { replies.close() }
        replies.bridge.send(.login(provider: "github-copilot", method: .oauth, flow: .device))
        let code = try await replies.first("the device code") { if case .deviceCode(let code, let uri, let expires) = $0 { (code, uri, expires) } else { nil } }
        #expect(code.0 == "8F3K-Q2WD" && code.1 == "https://example.invalid/login/device" && code.2 == 900)
        #expect(!replies.all.contains { if case .prompt = $0 { true } else { false } }, "the Enterprise question is answered for github.com")
        try Data().write(to: setup.control.appendingPathComponent("approved"))
        #expect(try await replies.done())
        #expect(try setup.auth()["github-copilot"] != nil)
    }

    @Test func aTakenCallbackPortFailsBeforeTheBrowserOpens() async throws {
        let setup = try Setup()
        defer { setup.remove() }
        // Hold 127.0.0.1:1455 the way Codex CLI or the terminal pi's /login would (unless something
        // already does).
        let held = Self.listen(on: 1455)
        defer { if held >= 0 { close(held) } }
        #expect(!Self.portFree(1455), "the port is taken")

        let replies = try setup.bridge()
        defer { replies.close() }
        replies.bridge.send(.login(provider: "openai-codex", method: .oauth, flow: .browser))
        let failure = try await replies.failure()
        #expect(failure.code == .portBusy && failure.port == 1455)
        #expect(!replies.all.contains { if case .authURL = $0 { true } else { false } }, "the browser never opened")
    }

    @Test func aKeyIsCheckedThenSavedEscapedAndNeverEchoed() async throws {
        let setup = try Setup()
        defer { setup.remove() }
        let replies = try setup.bridge()
        defer { replies.close() }
        let bad = "sk-fake-bad-key-9999"
        replies.bridge.send(.check(id: "c1", provider: "deepseek", key: .literal(bad)))
        let rejected = try await replies.first("the bad key's check") { if case .checked("c1", let r) = $0 { r } else { nil } }
        guard case .rejected(let reason) = rejected else { Issue.record("expected rejected, got \(rejected)"); return }
        #expect(reason.contains("401") && !reason.contains(bad), "in the provider's words, without the key")

        replies.bridge.send(.check(id: "c2", provider: "deepseek", key: .literal(FakePiSDK.goodKey)))
        let works = try await replies.first("the good key's check") { if case .checked("c2", let r) = $0 { r } else { nil } }
        #expect(works == .works(models: ["deepseek-chat", "deepseek-reasoner"]))

        replies.bridge.send(.check(id: "c3", provider: "deepseek", key: .variable("SHEPHERD_TEST_KEY_VAR")))
        let unset = try await replies.first("the unset variable's check") { if case .checked("c3", let r) = $0 { r } else { nil } }
        #expect(unset == .unset("$SHEPHERD_TEST_KEY_VAR isn’t set in your login shell."))

        replies.bridge.send(.login(provider: "deepseek", method: .apiKey, flow: .browser))
        let prompt = try await replies.prompt(.secret)
        replies.bridge.send(.answer(id: prompt.id, value: PiKeyInput.literal("sk-fake-$9").stored))
        #expect(try await replies.done() == false, "a key, not an account")
        #expect((try setup.auth()["deepseek"] as? [String: Any])?["key"] as? String == "sk-fake-$$9")
        replies.expectNoSecrets([bad])
    }

    @Test func cancelEndsASignInUnderWayAndSavesNothing() async throws {
        let setup = try Setup()
        defer { setup.remove() }
        let replies = try setup.bridge()
        defer { replies.close() }
        replies.bridge.send(.login(provider: "anthropic", method: .oauth, flow: .browser))
        _ = try await replies.prompt(.manualCode)
        replies.bridge.send(.cancel)
        #expect(try await replies.failure().code == .cancelled)
        #expect(try setup.auth()["anthropic"] == nil)
    }

    @Test func signOutRemovesOnlyShepherdsCredential() async throws {
        let setup = try Setup()
        defer { setup.remove() }
        try Data(#"{"anthropic":{"type":"oauth","access":"a","refresh":"r","expires":1},"openai":{"type":"api_key","key":"sk-x"}}"#.utf8)
            .write(to: setup.home.appendingPathComponent("auth.json"))
        let before = try Self.tree(setup.yours)
        let replies = try setup.bridge()
        defer { replies.close() }
        replies.bridge.send(.logout(provider: "anthropic"))
        try await replies.first("the sign-out") { $0 == .loggedOut(provider: "anthropic") ? true : nil }
        #expect(Set(try setup.auth().keys) == ["openai"], "only that provider went, from Shepherd's pi")
        #expect(try Self.tree(setup.yours) == before, "your pi keeps its own sign-in")
    }

    @Test func aBridgeThatCantRunSaysSo() async throws {
        let replies = Replies(PiSignInBridge(line: PiLaunch.Line(script: "exit 127")))
        let failure = try await replies.failure()
        #expect(failure.code == .bridge && failure.reason == "Shepherd can’t find its pi’s runtime.")
    }

    /// 127.0.0.1:`port`, as a callback server holds it.
    static func address(_ port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return address
    }

    static func bind(_ fd: Int32, _ port: UInt16) -> Bool {
        var address = address(port)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        } == 0
    }

    /// A socket listening on 127.0.0.1:`port`; -1 when something else already holds it.
    static func listen(on port: UInt16) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0, bind(fd, port), Darwin.listen(fd, 1) == 0 else { if fd >= 0 { close(fd) }; return -1 }
        return fd
    }

    static func portFree(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return bind(fd, port)
    }
}
