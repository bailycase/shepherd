import Foundation
import ShepherdProtocol
import ShepherdRemote

// Settings ▸ Pi ▸ Sign-in's bridge to pi's own login (docs/design/dialogs-and-palette.md › Dialogs and sheets › Sign in to
// <provider>): `Extensions/shepherd-sign-in.mjs` runs `ModelRuntime.login` against Shepherd's pi
// home on the engine's node, and speaks JSON lines. These are its two halves, and the process.
// Nothing of a credential ever crosses: the app sends what the user typed (a key, a pasted code)
// as a prompt's answer, and hears back only that it worked.

/// How a provider signs in: with an account (OAuth), or with a key.
public enum PiSignInMethod: String, Codable, Sendable {
    case oauth
    case apiKey = "api_key"
}

/// Which of a provider's account sign-ins to take when pi asks (OpenAI Codex and Radius offer both).
public enum PiSignInFlow: String, Codable, Sendable {
    case browser
    case device
    /// The browser's page, but the code is pasted: no check of the callback port, which another
    /// sign-in holds.
    case paste
}

/// A key to check: its value, or the variable the login shell sets.
public enum PiKeyInput: Equatable, Sendable {
    case literal(String)
    case variable(String)

    /// What auth.json stores for it, as pi reads it (pi: core/resolve-config-value.js): `$NAME`
    /// for a variable; a literal with every `$` doubled and a leading `!` escaped, so a key that
    /// happens to hold either is never read as a variable or run as a command.
    public var stored: String {
        switch self {
        case .variable(let name): "$" + name
        case .literal(let key):
            key.hasPrefix("!") ? "$!" + key.dropFirst().replacingOccurrences(of: "$", with: "$$")
                : key.replacingOccurrences(of: "$", with: "$$")
        }
    }
}

/// What the app tells the bridge.
public enum PiSignInCommand: Equatable, Sendable {
    case login(provider: String, method: PiSignInMethod, flow: PiSignInFlow)
    /// A prompt's answer.
    case answer(id: String, value: String)
    /// Ends the login under way.
    case cancel
    /// Removes Shepherd's credential for the provider (pi's own logout).
    case logout(provider: String)
    /// Whether a key works, with the smallest request pi can make.
    case check(id: String, provider: String, key: PiKeyInput)

    /// One JSON line, newline included.
    public var line: Data {
        var object: [String: String]
        switch self {
        case .login(let provider, let method, let flow):
            object = ["type": "login", "provider": provider, "method": method.rawValue, "flow": flow.rawValue]
        case .answer(let id, let value): object = ["type": "answer", "id": id, "value": value]
        case .cancel: object = ["type": "cancel"]
        case .logout(let provider): object = ["type": "logout", "provider": provider]
        case .check(let id, let provider, let key):
            object = ["type": "check", "id": id, "provider": provider]
            switch key {
            case .literal(let value): object["key"] = value
            case .variable(let name): object["variable"] = name
            }
        }
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        data.append(0x0A)
        return data
    }
}

/// A question pi asks while it signs in.
public struct PiSignInPrompt: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        /// A code pasted from the provider's page, raced against the browser's callback.
        case manualCode = "manual_code"
        /// A key.
        case secret
        case text
        case select
    }

    public struct Option: Equatable, Sendable {
        public var id: String
        public var label: String
        public init(id: String, label: String) {
            self.id = id
            self.label = label
        }
    }

    public var id: String
    public var kind: Kind
    public var message: String
    public var placeholder: String?
    public var options: [Option]

    public init(id: String, kind: Kind, message: String, placeholder: String? = nil, options: [Option] = []) {
        self.id = id
        self.kind = kind
        self.message = message
        self.placeholder = placeholder
        self.options = options
    }
}

/// Why a sign-in ended without one, in words fit for the sheet: never a credential.
public struct PiSignInFailure: Equatable, Sendable, Error {
    public enum Code: String, Sendable {
        case cancelled
        /// The provider's fixed callback port is taken (Codex CLI, or the terminal pi's /login).
        case portBusy
        case unknownProvider
        /// The bridge couldn't run, or stopped without an answer.
        case bridge
        case other
    }

    public var code: Code
    public var reason: String
    public var port: Int?

    public init(_ code: Code, reason: String, port: Int? = nil) {
        self.code = code
        self.reason = reason
        self.port = port
    }
}

/// What checking a key found.
public enum PiKeyCheck: Equatable, Sendable {
    /// The provider answered; these are some of its models.
    case works(models: [String])
    /// The provider refused it, in its words.
    case rejected(String)
    /// The provider couldn't be reached, so the key wasn't checked.
    case unreachable(String)
    /// The variable isn't set in the login shell.
    case unset(String)
}

/// What the bridge says.
public enum PiSignInReply: Equatable, Sendable {
    case ready
    /// The browser sign-in's page: open it.
    case authURL(URL, instructions: String?)
    /// A device-code sign-in's code and where to enter it.
    case deviceCode(code: String, verificationURI: String, expiresIn: Int?)
    case info(String)
    case progress(String)
    case prompt(PiSignInPrompt)
    /// pi no longer needs that answer (the browser's callback won).
    case promptClosed(String)
    /// Signed in: the credential is in the home's auth.json.
    case done(provider: String, subscription: Bool)
    case failed(PiSignInFailure)
    case checked(id: String, PiKeyCheck)
    case loggedOut(provider: String)

    private struct Wire: Decodable {
        struct Event: Decodable {
            var type: String
            var url: String?
            var instructions: String?
            var userCode: String?
            var verificationUri: String?
            var expiresInSeconds: Double?
            var message: String?
        }
        struct Option: Decodable { var id: String; var label: String? }
        var type: String
        var event: Event?
        var id: String?
        var kind: String?
        var message: String?
        var placeholder: String?
        var options: [Option]?
        var provider: String?
        var credential: String?
        var code: String?
        var reason: String?
        var port: Int?
        var result: String?
        var models: [String]?
    }

    /// One line of the bridge's stdout; nil for anything it doesn't say.
    public static func parse(_ line: Data) -> PiSignInReply? {
        guard let wire = try? JSONDecoder().decode(Wire.self, from: line) else { return nil }
        switch wire.type {
        case "ready": return .ready
        case "event":
            guard let event = wire.event else { return nil }
            switch event.type {
            case "auth_url":
                guard let url = event.url.flatMap(URL.init(string:)), ["https", "http"].contains(url.scheme ?? "") else { return nil }
                return .authURL(url, instructions: event.instructions)
            case "device_code":
                guard let code = event.userCode, let uri = event.verificationUri else { return nil }
                return .deviceCode(code: code, verificationURI: uri, expiresIn: event.expiresInSeconds.map { Int($0) })
            case "info": return .info(event.message ?? "")
            case "progress": return .progress(event.message ?? "")
            default: return nil
            }
        case "prompt":
            guard let id = wire.id, let kind = wire.kind.flatMap(PiSignInPrompt.Kind.init(rawValue:)) else { return nil }
            return .prompt(PiSignInPrompt(id: id, kind: kind, message: wire.message ?? "", placeholder: wire.placeholder,
                                          options: (wire.options ?? []).map { .init(id: $0.id, label: $0.label ?? $0.id) }))
        case "promptClosed":
            return wire.id.map { .promptClosed($0) }
        case "done":
            guard let provider = wire.provider else { return nil }
            return .done(provider: provider, subscription: wire.credential == "oauth")
        case "failed":
            let code = wire.code.flatMap(PiSignInFailure.Code.init(rawValue:)) ?? .other
            return .failed(PiSignInFailure(code, reason: wire.reason ?? "The sign-in stopped.", port: wire.port))
        case "checked":
            guard let id = wire.id else { return nil }
            let reason = wire.reason ?? ""
            switch wire.result {
            case "works": return .checked(id: id, .works(models: wire.models ?? []))
            case "rejected": return .checked(id: id, .rejected(reason))
            case "unset": return .checked(id: id, .unset(reason))
            default: return .checked(id: id, .unreachable(reason))
            }
        case "loggedOut":
            return wire.provider.map { .loggedOut(provider: $0) }
        default:
            return nil
        }
    }
}

extension PiLaunch {
    /// The sign-in bridge: `shepherd-sign-in.mjs` on the engine's node, in a login shell (so a
    /// key's variable and the user's proxy settings are there), with the shell's pi, jiti and
    /// Node settings dropped and Shepherd's pi home pinned, in the home: `$0` is the script, `$1`
    /// pi's SDK (the engine's `dist/bundle/index.js`), `$2` the home.
    public static func signInBridge(node: PiEngine.Program, script: String, sdk: String, home: PiHome) -> Line {
        Line(script: clearedEnvironment(home: home)
                + "export PI_CODING_AGENT_DIR=\(quoted(home.directory.path)) PI_OFFLINE=1 PI_SKIP_VERSION_CHECK=1 PI_TELEMETRY=0; "
                + "cd -- \(quoted(home.directory.path)) && exec \(word(node)) \"$0\" \"$1\" \"$2\"",
             positional: [script, sdk, home.directory.path])
    }
}

/// One run of the sign-in bridge: its replies as they come, and the commands the sheet sends. It
/// ends when the sheet closes (`close`), or on its own when it can't run; either way `replies`
/// finishes, and a bridge that never said `ready` or stopped mid-login is a `.bridge` failure.
public final class PiSignInBridge: @unchecked Sendable {
    public let replies: AsyncStream<PiSignInReply>
    private let continuation: AsyncStream<PiSignInReply>.Continuation
    private let process = Process()
    private let input = Pipe()
    private let lock = NSLock()
    private var buffer = LineBuffer()
    private var errors = Data()
    private var closed = false

    /// Starts `line` (`PiLaunch.signInBridge`). The environment is the app's, without Shepherd's
    /// own variables but the support folder's.
    public init(line: PiLaunch.Line, environment: [String: String] = ProcessInfo.processInfo.environment) {
        (replies, continuation) = AsyncStream.makeStream(of: PiSignInReply.self)
        process.executableURL = URL(fileURLWithPath: line.argv[0])
        process.arguments = Array(line.argv.dropFirst())
        var env = environment
        for key in env.keys where key.hasPrefix("SHEPHERD_") && key != ShepherdPaths.supportDirectoryEnvKey { env[key] = nil }
        process.environment = env
        let output = Pipe(), stderr = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = stderr
        // Pipe handlers outlive a weak owner. Remove them even if close released the bridge.
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self, !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            let lines = self.lock.withLock { (try? self.buffer.append(chunk)) ?? [] }
            for line in lines {
                if let reply = PiSignInReply.parse(line) { self.continuation.yield(reply) }
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self, !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            self.lock.withLock {
                self.errors.append(chunk)
                if self.errors.count > 8192 { self.errors = self.errors.suffix(4096) }
            }
        }
        process.terminationHandler = { [weak self] process in
            output.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            guard let self else { return }
            // What was still in the pipe.
            let rest = output.fileHandleForReading.readDataToEndOfFile()
            let lines = self.lock.withLock { (try? self.buffer.append(rest + (rest.last == 0x0A || rest.isEmpty ? Data() : Data([0x0A])))) ?? [] }
            for line in lines { if let reply = PiSignInReply.parse(line) { self.continuation.yield(reply) } }
            let (wasClosed, text) = self.lock.withLock { (self.closed, String(decoding: self.errors, as: UTF8.self)) }
            if !wasClosed, process.terminationStatus != 0 {
                let last = text.split(whereSeparator: \.isNewline).last.map(String.init)?.trimmingCharacters(in: .whitespaces)
                let reason = process.terminationStatus == 127 ? "Shepherd can’t find its pi’s runtime."
                    : last.map { "The sign-in stopped: \($0.prefix(200))" } ?? "The sign-in stopped (status \(process.terminationStatus))."
                self.continuation.yield(.failed(PiSignInFailure(.bridge, reason: reason)))
            }
            self.continuation.finish()
        }
        do {
            try process.run()
        } catch {
            continuation.yield(.failed(PiSignInFailure(.bridge, reason: "Couldn’t start the sign-in: \(error.localizedDescription)")))
            continuation.finish()
        }
    }

    public func send(_ command: PiSignInCommand) {
        let open = lock.withLock { !closed }
        guard open, process.isRunning else { return }
        try? input.fileHandleForWriting.write(contentsOf: command.line)
    }

    /// Ends the bridge: a login under way is cancelled, and the process exits by itself.
    public func close() {
        let first = lock.withLock { () -> Bool in
            defer { closed = true }
            return !closed
        }
        guard first else { return }
        try? input.fileHandleForWriting.close()
        // It exits within a beat of stdin closing; one that doesn't is stopped.
        let process = self.process
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if process.isRunning { process.terminate() }
        }
    }

    deinit {
        if process.isRunning { process.terminate() }
    }
}

/// The installed bridge script.
public enum PiSignInScript {
    public static let fileName = "shepherd-sign-in.mjs"

    /// Writes the script into `directory` when it differs, and returns its path.
    public static func install(in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName)
        let data = Data(source.utf8)
        if (try? Data(contentsOf: url)) != data { try data.write(to: url, options: .atomic) }
        return url
    }

    /// Extensions/shepherd-sign-in.mjs is canonical; keep this byte-identical.
    static let source = #"""
        // Shepherd's sign-in bridge. Not an extension: the app runs it with the engine's node, in a login
        // shell, as `node shepherd-sign-in.mjs <pi sdk> <pi home>`, for Settings ▸ Pi ▸ Sign-in's sheet.
        //
        // It runs pi's own login (`ModelRuntime.login`) against Shepherd's pi home, never the user's, and
        // passes pi's prompts and events to the app as JSON lines. The credential goes from pi straight
        // into the home's auth.json: nothing of it is written to stdout or stderr. One process per sheet.
        //
        // stdin, one JSON object a line:
        //   {"type":"login","provider":"anthropic","method":"oauth"|"api_key","flow":"browser"|"device"|"paste"}
        //   ("paste" is the browser flow without the callback port's check: a code pasted from the page)
        //   {"type":"answer","id":"p1","value":"…"}      a prompt's answer (a key, a pasted code)
        //   {"type":"cancel"}                            ends the login under way
        //   {"type":"logout","provider":"anthropic"}     removes Shepherd's credential for it
        //   {"type":"check","id":"c1","provider":"deepseek","key":"…"} or {…,"variable":"DEEPSEEK_API_KEY"}
        // stdout:
        //   {"type":"ready"}
        //   {"type":"event","event":{"type":"auth_url"|"device_code"|"info"|"progress",…}}
        //   {"type":"prompt","id":"p1","kind":"manual_code"|"secret"|"text"|"select","message":…,"placeholder"?,"options"?}
        //   {"type":"promptClosed","id":"p1"}           pi no longer needs that answer (the browser won)
        //   {"type":"done","provider":…,"credential":"oauth"|"api_key"}
        //   {"type":"failed","code":"cancelled"|"portBusy"|"unknownProvider"|"other","reason":…,"port"?}
        //   {"type":"checked","id":…,"result":"works"|"rejected"|"unreachable"|"unset","reason"?,"models"?}
        //   {"type":"loggedOut","provider":…}
        //
        // It exits when stdin closes, and never throws: every failure is a line.
        import * as net from "node:net";
        import * as path from "node:path";
        import * as readline from "node:readline";
        import { pathToFileURL } from "node:url";

        const [sdkPath, home] = process.argv.slice(2);

        /** The callback ports pi's browser sign-ins listen on, checked before the browser opens. */
        const CALLBACK_PORTS = { anthropic: 53692, "openai-codex": 1455, radius: 1456 };

        function send(message) {
          process.stdout.write(JSON.stringify(message) + "\n");
        }

        /** A reason without a stack, a response body, or anything that looks like a token. */
        export function clean(reason, secrets = []) {
          let text = String(reason instanceof Error ? reason.message : reason ?? "");
          for (const secret of secrets) {
            if (secret && secret.length >= 8) text = text.split(secret).join("••••");
          }
          text = text.split(/\r?\n/)[0];
          text = text.replace(/\s*;?\s*body=.*$/s, "").replace(/\s*;?\s*details=.*$/s, "");
          text = text.replace(/[A-Za-z0-9_\-.~+/]{32,}={0,2}/g, "••••");
          return text.trim().slice(0, 240);
        }

        let runtime;
        async function modelRuntime() {
          if (!runtime) {
            const sdk = await import(pathToFileURL(sdkPath).href);
            runtime = await sdk.ModelRuntime.create({
              authPath: path.join(home, "auth.json"),
              modelsPath: path.join(home, "models.json"),
              refreshOnCreate: false,
            });
          }
          return runtime;
        }

        function portFree(port) {
          return new Promise((resolve) => {
            const server = net.createServer();
            server.unref();
            server.once("error", (error) => resolve(error && error.code === "EADDRINUSE" ? false : true));
            server.listen(port, "127.0.0.1", () => server.close(() => resolve(true)));
          });
        }

        let login;
        let promptCount = 0;
        const prompts = new Map();
        /** What the user typed for this login (a key, a code): kept out of every reason sent back. */
        let typed = [];

        function answerAutomatically(prompt, flow) {
          if (prompt.type === "select") {
            const want = flow === "device" ? /device/i : /browser/i;
            const option = prompt.options.find((o) => want.test(o.id) || want.test(o.label));
            return option ? option.id : undefined;
          }
          // GitHub Copilot asks for an Enterprise domain first: blank is github.com.
          if (prompt.type === "text" && /enterprise/i.test(prompt.message)) return "";
          return undefined;
        }

        function interaction(controller, flow) {
          return {
            signal: controller.signal,
            notify(event) {
              if (!event || typeof event !== "object") return;
              const { type } = event;
              if (type === "auth_url") send({ type: "event", event: { type, url: event.url, instructions: event.instructions } });
              else if (type === "device_code")
                send({
                  type: "event",
                  event: {
                    type,
                    userCode: event.userCode,
                    verificationUri: event.verificationUri,
                    expiresInSeconds: event.expiresInSeconds,
                  },
                });
              else if (type === "info" || type === "progress") send({ type: "event", event: { type, message: String(event.message ?? "") } });
            },
            prompt(prompt) {
              const automatic = answerAutomatically(prompt, flow);
              if (automatic !== undefined) return Promise.resolve(automatic);
              const id = `p${++promptCount}`;
              return new Promise((resolve, reject) => {
                const close = () => {
                  if (!prompts.delete(id)) return;
                  send({ type: "promptClosed", id });
                  reject(new Error("Login cancelled"));
                };
                prompts.set(id, { resolve, reject });
                if (prompt.signal) {
                  if (prompt.signal.aborted) return close();
                  prompt.signal.addEventListener("abort", close, { once: true });
                }
                send({
                  type: "prompt",
                  id,
                  kind: prompt.type,
                  message: String(prompt.message ?? ""),
                  placeholder: prompt.placeholder,
                  options: prompt.type === "select" ? prompt.options.map((o) => ({ id: o.id, label: o.label })) : undefined,
                });
              });
            },
          };
        }

        async function startLogin(message) {
          if (login) return send({ type: "failed", code: "other", reason: "A sign-in is already under way." });
          const { provider, method = "oauth", flow = "browser" } = message;
          const controller = new AbortController();
          login = controller;
          typed = [];
          try {
            const models = await modelRuntime();
            if (!models.getProvider(provider)) {
              return send({ type: "failed", code: "unknownProvider", reason: `Shepherd’s pi doesn’t know ${provider}.` });
            }
            const port = CALLBACK_PORTS[provider];
            if (method === "oauth" && flow === "browser" && port && !(await portFree(port))) {
              return send({ type: "failed", code: "portBusy", port, reason: `Another sign-in is using localhost:${port}.` });
            }
            const credential = await models.login(provider, method, interaction(controller, flow));
            send({ type: "done", provider, credential: credential && credential.type === "oauth" ? "oauth" : "api_key" });
          } catch (error) {
            if (controller.signal.aborted || /Login cancelled/.test(String(error && error.message))) {
              send({ type: "failed", code: "cancelled", reason: "Cancelled." });
            } else if (error && error.code === "EADDRINUSE") {
              send({ type: "failed", code: "portBusy", port: CALLBACK_PORTS[provider], reason: clean(error) });
            } else {
              send({ type: "failed", code: "other", reason: clean(error, typed) });
            }
          } finally {
            login = undefined;
            for (const [id, pending] of prompts) {
              prompts.delete(id);
              pending.reject(new Error("Login cancelled"));
            }
          }
        }

        async function logout(message) {
          try {
            const models = await modelRuntime();
            await models.logout(message.provider);
            send({ type: "loggedOut", provider: message.provider });
          } catch (error) {
            send({ type: "failed", code: "other", reason: clean(error) });
          }
        }

        /** Whether a key works: the smallest request pi can make with it, on the provider's first model. */
        async function check(message) {
          const { id, provider } = message;
          let key = message.key;
          if (message.variable) {
            key = process.env[message.variable];
            if (!key) return send({ type: "checked", id, result: "unset", reason: `$${message.variable} isn’t set in your login shell.` });
          }
          try {
            const models = await modelRuntime();
            const list = models.getModels(provider);
            if (!list.length) return send({ type: "checked", id, result: "unreachable", reason: `Shepherd’s pi has no models for ${provider}.` });
            const model = list.find((m) => !m.reasoning) ?? list[0];
            const reply = await models.completeSimple(
              model,
              { messages: [{ role: "user", content: "Reply with OK.", timestamp: Date.now() }] },
              { apiKey: key, maxTokens: 16, signal: AbortSignal.timeout(20_000) },
            );
            if (reply && reply.stopReason === "error") throw new Error(reply.errorMessage || "The provider refused the request.");
            send({ type: "checked", id, result: "works", models: list.slice(0, 3).map((m) => m.id) });
          } catch (error) {
            const reason = clean(error, [key]);
            const rejected = /\b(401|403)\b|unauthori[sz]ed|invalid.{0,20}(api.?key|key|token)|incorrect api key|authentication|permission/i.test(reason);
            send({ type: "checked", id, result: rejected ? "rejected" : "unreachable", reason });
          }
        }

        function handle(line) {
          let message;
          try {
            message = JSON.parse(line);
          } catch {
            return;
          }
          if (!message || typeof message !== "object") return;
          switch (message.type) {
            case "login":
              void startLogin(message);
              break;
            case "answer": {
              const pending = prompts.get(message.id);
              if (!pending) return;
              prompts.delete(message.id);
              typed.push(String(message.value ?? ""));
              pending.resolve(String(message.value ?? ""));
              break;
            }
            case "cancel":
              login?.abort();
              break;
            case "logout":
              void logout(message);
              break;
            case "check":
              void check(message);
              break;
          }
        }

        if (sdkPath && home) {
          process.on("uncaughtException", (error) => send({ type: "failed", code: "other", reason: clean(error) }));
          process.on("unhandledRejection", (error) => send({ type: "failed", code: "other", reason: clean(error) }));
          const lines = readline.createInterface({ input: process.stdin });
          lines.on("line", handle);
          lines.on("close", () => {
            login?.abort();
            setTimeout(() => process.exit(0), 200);
          });
          send({ type: "ready" });
        }

        """#
}
