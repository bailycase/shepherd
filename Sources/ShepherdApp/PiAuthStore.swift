import AppKit
import Foundation
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions

/// Shepherd's pi's sign-ins (PiAuthStates' `PiAuthStore`): the sign-in sheet while one runs,
/// sign-outs, what pi said expired, and what agents wait on. Signing in runs pi's own login
/// through the bridge (`PiSignInBridge`), against Shepherd's pi home alone; nothing here ever holds
/// a credential but what the user types into the sheet, which goes to pi as a prompt's answer.
@MainActor @Observable
final class PiAuthStore {
    /// The sheet, while one is up.
    var session: PiSignInSession?
    /// Providers pi said failed to refresh (a turn's error); cleared when one signs in again.
    private(set) var expired: Set<String> = []
    /// A failed sign-out, by provider.
    private(set) var problems: [String: String] = [:]
    /// Providers this Mac's agents wait on, not signed in (the view model keeps it).
    var needed: Set<String> = []
    /// The provider Sign-in scrolls to (`/login anthropic`, an agent's card); nil once it has.
    var focus: String?
    /// Providers a sign-out is under way for.
    private(set) var signingOut: Set<String> = []

    /// A sign-in landed for a provider: the agents waiting on it start again. Returns how many.
    @ObservationIgnored var onSignedIn: ((String) -> Int)?
    /// Sign-ins changed (a sign-in, a sign-out): Settings reads both sides again.
    @ObservationIgnored var onChanged: (() -> Void)?
    @ObservationIgnored let pi: PiSetup
    @ObservationIgnored let bridge: @MainActor () throws -> PiSignInBridge
    @ObservationIgnored var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    @ObservationIgnored var copy: (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    init(pi: PiSetup, bridge: (@MainActor () throws -> PiSignInBridge)? = nil) {
        self.pi = pi
        self.bridge = bridge ?? { try PiAuthStore.appBridge(pi) }
    }

    /// Why this build can't sign in: a Debug build run on a stand-in engine has no pi SDK.
    struct NoSDK: Error, CustomStringConvertible {
        var description: String { "Signing in needs the pi that ships with Shepherd." }
    }

    /// The bridge on the engine's node, with pi's SDK from the engine's package, installed beside
    /// Shepherd's other scripts in the support folder.
    static func appBridge(_ pi: PiSetup) throws -> PiSignInBridge {
        guard let package = pi.engine.packageDirectory else { throw NoSDK() }
        let script = try PiSignInScript.install(in: ShepherdPaths.supportDirectory())
        let sdk = URL(fileURLWithPath: package).appendingPathComponent(BundledPiEngine.libraryPath).path
        return PiSignInBridge(line: PiLaunch.signInBridge(node: pi.engine.node, script: script.path, sdk: sdk, home: pi.files))
    }

    // MARK: Signing in

    /// Opens the sheet for `provider` and starts its sign-in: an account's by its catalog flow, a
    /// key's (`key`, or any provider without an account sign-in) with the key form. One sheet at
    /// a time: another provider's under way is cancelled.
    func signIn(_ provider: String, key: Bool = false, origin: PiSignInSession.Origin = .settings) {
        if let session, session.provider == provider, session.phase.isLive { return }
        session?.end()
        let subscription = key ? nil : PiSignInCatalog.subscription(provider)
        let next = PiSignInSession(provider: provider, subscription: subscription, origin: origin, store: self)
        session = next
        next.start()
    }

    /// The sheet closed, whichever way: a sign-in under way is cancelled.
    func closeSheet() {
        session?.end()
        session = nil
    }

    /// Readies Shepherd's pi home off the main thread (`PiSetup.prepare`): why not, or nil.
    func readyHome() async -> String? {
        let pi = pi
        return await Task.detached(priority: .userInitiated) { pi.prepare()?.message }.value
    }

    /// A sign-in landed in Shepherd's pi.
    func landed(_ provider: String) -> Int {
        expired.remove(provider)
        pi.catalog.invalidate()
        onChanged?()
        return onSignedIn?(provider) ?? 0
    }

    /// Signs `provider` out of Shepherd's pi only (pi's own logout on the home's auth.json); the
    /// user's pi keeps its own.
    func signOut(_ provider: String) async {
        guard !signingOut.contains(provider) else { return }
        signingOut.insert(provider)
        defer { signingOut.remove(provider) }
        problems[provider] = nil
        let failure: String?
        if let problem = await readyHome() {
            failure = problem
        } else {
            do {
                let bridge = try bridge()
                bridge.send(.logout(provider: provider))
                failure = await Self.outcome(of: bridge, provider: provider)
                bridge.close()
            } catch {
                failure = String(describing: error)
            }
        }
        if let failure { problems[provider] = "Couldn’t sign out: \(failure)" } else { expired.remove(provider) }
        pi.catalog.invalidate()
        onChanged?()
    }

    private static func outcome(of bridge: PiSignInBridge, provider: String) async -> String? {
        for await reply in bridge.replies {
            switch reply {
            case .loggedOut(provider): return nil
            case .failed(let failure): return failure.reason
            default: continue
            }
        }
        return "The sign-in helper stopped."
    }

    // MARK: What pi says

    /// A turn's error named a provider whose refresh failed: its row says Expired.
    func noteTurnError(_ message: String) {
        guard let provider = PiAuthText.expiredProvider(in: message), !expired.contains(provider) else { return }
        expired.insert(provider)
    }
}

/// One run of the sign-in sheet (`SignInSheet`): its flow, where it stands, and what the user
/// typed. The bridge's replies move it; the sheet's buttons call it.
@MainActor @Observable
final class PiSignInSession: Identifiable {
    /// Where the sheet was opened from: one opened from `/login` or an agent's card closes by
    /// itself a beat after it lands.
    enum Origin: Equatable { case settings, slash, agentCard, firstLaunch }

    enum Flow: Equatable { case browser, device, paste, key }

    /// A key being checked.
    enum KeyCheck: Equatable {
        case idle
        case checking
        case works(models: [String])
        case rejected(String)
        case unreachable(String)
        case unset(String)

        var allowsSave: Bool {
            switch self {
            case .works, .unreachable: true
            case .idle, .checking, .rejected, .unset: false
            }
        }
    }

    enum Phase: Equatable {
        /// The bridge is starting pi's login.
        case starting
        /// The browser was opened; waiting for its callback (or a pasted code).
        case browser
        /// Another sign-in holds the provider's callback port.
        case portBusy(Int)
        /// A device code to enter at `uri`, good until `expires`.
        case device(code: String, uri: String, expires: Date?)
        /// A code to paste; `rejected` is the provider's reason for the last one.
        case paste(rejected: String?)
        /// The key form.
        case key
        /// A pasted code or key went to pi; waiting for it to land.
        case saving
        /// Signed in: `pickedUp` agents started again.
        case done(pickedUp: Int)
        case failed(String)

        var isLive: Bool {
            switch self {
            case .done, .failed, .portBusy: false
            default: true
            }
        }
    }

    enum KeyMode: Equatable { case paste, variable }

    let id = UUID()
    let provider: String
    let subscription: PiSignInCatalog.Subscription?
    let origin: Origin
    private(set) var flow: Flow
    private(set) var phase: Phase = .starting
    /// The browser page, once pi gave it.
    private(set) var authURL: URL?
    /// The code the user pastes (paste flow).
    var code = ""
    var keyMode: KeyMode = .paste
    var key = "" { didSet { if key != oldValue { scheduleCheck() } } }
    var variable = "" { didSet { if variable != oldValue { scheduleCheck() } } }
    private(set) var keyCheck: KeyCheck = .idle

    // Strong: the store drops the session when its sheet closes.
    @ObservationIgnored private var store: PiAuthStore?
    @ObservationIgnored private var bridge: PiSignInBridge?
    @ObservationIgnored private var reader: Task<Void, Never>?
    @ObservationIgnored private var checking: Task<Void, Never>?
    @ObservationIgnored private var pendingPrompt: PiSignInPrompt?
    @ObservationIgnored private var checkCount = 0
    /// How long typing rests before a key is checked.
    @ObservationIgnored var checkDelay: Duration = .milliseconds(600)

    init(provider: String, subscription: PiSignInCatalog.Subscription?, origin: Origin, store: PiAuthStore) {
        self.provider = provider
        self.subscription = subscription
        self.origin = origin
        self.store = store
        flow = subscription.map { $0.flow == .device ? .device : .browser } ?? .key
        if let names = PiProviders.environmentKeys[provider], let first = names.first { variable = first }
    }

    /// Previews: a sheet drawn in one phase, with no bridge.
    init(preview provider: String, flow: Flow, phase: Phase, authURL: URL? = nil, code: String = "", keyMode: KeyMode = .paste,
         key: String = "", variable: String = "", keyCheck: KeyCheck = .idle) {
        self.provider = provider
        subscription = flow == .key ? nil : PiSignInCatalog.subscription(provider)
        origin = .settings
        self.flow = flow
        self.phase = phase
        self.authURL = authURL
        self.code = code
        self.keyMode = keyMode
        self.key = key
        self.variable = variable
        self.keyCheck = keyCheck
    }

    var name: String { PiSignInCatalog.name(provider) }
    var site: String { subscription?.site ?? PiSignInCatalog.keyPages[provider] ?? name }

    // MARK: Running pi's login

    func start(flow override: PiSignInFlow? = nil) {
        reader?.cancel()
        bridge?.close()
        pendingPrompt = nil
        guard let store else { return }
        if flow != .paste { phase = flow == .key ? .key : .starting }
        reader = Task { [weak self] in
            // The home first (Shepherd's launcher and its guards): nothing signs in to a home the
            // guards refuse.
            if let problem = await store.readyHome() {
                self?.phase = .failed(problem)
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.run(override)
        }
    }

    private func run(_ override: PiSignInFlow?) {
        guard let store else { return }
        do {
            let bridge = try store.bridge()
            self.bridge = bridge
            reader = Task { [weak self] in
                for await reply in bridge.replies {
                    guard let self, !Task.isCancelled else { return }
                    self.handle(reply)
                }
            }
            let method: PiSignInMethod = flow == .key ? .apiKey : .oauth
            let piFlow = override ?? (flow == .device ? .device : flow == .paste ? .paste : .browser)
            bridge.send(.login(provider: provider, method: method, flow: piFlow))
            if flow != .paste { phase = flow == .key ? .key : .starting }
            // A key typed while the bridge started is checked now.
            if flow == .key, keyInput != nil { scheduleCheck() }
        } catch {
            phase = .failed(String(describing: error))
        }
    }

    func handle(_ reply: PiSignInReply) {
        switch reply {
        case .ready, .info, .progress:
            break
        case .authURL(let url, _):
            authURL = url
            if flow != .paste { phase = .browser }
            store?.openURL(url)
        case .deviceCode(let code, let uri, let expires):
            flow = .device
            phase = .device(code: code, uri: uri, expires: expires.map { Date().addingTimeInterval(TimeInterval($0)) })
            store?.copy(code)
        case .prompt(let prompt):
            pendingPrompt = prompt
            if prompt.kind == .secret { flow = .key; phase = .key }
        case .promptClosed(let id):
            if pendingPrompt?.id == id { pendingPrompt = nil }
        case .done(let provider, _):
            bridge?.close()
            let count = store?.landed(provider) ?? 0
            phase = .done(pickedUp: count)
        case .failed(let failure):
            switch failure.code {
            case .cancelled: break
            case .portBusy: phase = .portBusy(failure.port ?? 0)
            default:
                if flow == .paste { phase = .paste(rejected: failure.reason) }
                else if flow == .key { phase = .failed(failure.reason) }
                else { phase = .failed(failure.reason) }
            }
        case .checked(let id, let result):
            guard id == "c\(checkCount)" else { return }
            keyCheck = switch result {
            case .works(let models): .works(models: models)
            case .rejected(let reason): .rejected(reason)
            case .unreachable(let reason): .unreachable(reason)
            case .unset(let reason): .unset(reason)
            }
        case .loggedOut:
            break
        }
    }

    /// The sheet went away: a login under way is cancelled and the bridge ends.
    func end() {
        bridge?.send(.cancel)
        bridge?.close()
        reader?.cancel()
        checking?.cancel()
    }

    /// Open browser again.
    func openBrowserAgain() {
        if let authURL, phase.isLive { store?.openURL(authURL) } else { flow = .browser; start() }
    }

    func copyLink() {
        if let authURL { store?.copy(authURL.absoluteString) }
    }

    /// "Paste a code instead": the same login, answered with a code. After a taken port, a new
    /// login that doesn't check the port.
    func pasteInstead() {
        let restart = { if case .portBusy = self.phase { true } else { !self.phase.isLive } }()
        flow = .paste
        phase = .paste(rejected: nil)
        if restart { start(flow: .paste) }
    }

    /// pi is waiting for a pasted code (its prompt is open).
    var submitReady: Bool { pendingPrompt.map { $0.kind == .manualCode || $0.kind == .text } ?? false }

    /// Continue with the pasted code.
    func submitCode() {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        guard let prompt = pendingPrompt, prompt.kind == .manualCode || prompt.kind == .text else {
            // The login that asked for it ended (the code was refused): a new one, then this code.
            start(flow: .paste)
            return
        }
        pendingPrompt = nil
        phase = .saving
        bridge?.send(.answer(id: prompt.id, value: code))
    }

    /// "Open claude.ai again": a fresh page for a fresh code.
    func reopenForCode() {
        code = ""
        flow = .paste
        phase = .paste(rejected: nil)
        start(flow: .paste)
    }

    func tryAgain() {
        flow = subscription.map { $0.flow == .device ? .device : .browser } ?? .key
        keyCheck = .idle
        start()
    }

    func openDevicePage() {
        if case .device(_, let uri, _) = phase, let url = URL(string: uri) { store?.openURL(url) }
    }

    func copyCode() {
        if case .device(let code, _, _) = phase { store?.copy(code) }
    }

    // MARK: Keys

    /// What the key form would save.
    var keyInput: PiKeyInput? {
        switch keyMode {
        case .paste:
            let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
            return key.isEmpty ? nil : .literal(key)
        case .variable:
            let name = variable.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "$"))
            return name.isEmpty ? nil : .variable(name)
        }
    }

    func setKeyMode(_ mode: KeyMode) {
        guard mode != keyMode else { return }
        keyMode = mode
        scheduleCheck()
    }

    private func scheduleCheck() {
        checking?.cancel()
        // A preview's sheet has no pi to ask.
        guard store != nil else { return }
        guard flow == .key, let input = keyInput else {
            keyCheck = .idle
            return
        }
        keyCheck = .idle
        let delay = checkDelay
        checking = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.checkCount += 1
            self.keyCheck = .checking
            self.bridge?.send(.check(id: "c\(self.checkCount)", provider: self.provider, key: input))
        }
    }

    /// Save: the key (or `$NAME`) goes to pi as its prompt's answer, escaped as pi reads it.
    func saveKey() {
        guard keyCheck.allowsSave, let input = keyInput, let prompt = pendingPrompt else { return }
        pendingPrompt = nil
        phase = .saving
        bridge?.send(.answer(id: prompt.id, value: input.stored))
    }
}
