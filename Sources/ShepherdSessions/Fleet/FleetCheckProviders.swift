import Foundation
import ShepherdProtocol

/// Check's look at the model providers in this Mac's sign-ins (`auth.json`, which syncs): each answers pi's own cheap check of its stored
/// login (the smallest request pi can make; a stale OAuth token is refreshed on the way), or, for a provider whose key is a command, says
/// whether that command can start. Read only: a sign-in is never changed, and what pi answers is never more than a word.
struct FleetCheckProviders: @unchecked Sendable {
    let pi: PiSetup
    /// Where Shepherd's own scripts live (`PiSignInScript`).
    let support: URL
    /// The whole look is given this long, bridge and all.
    static let timeout: TimeInterval = 30

    func answers() async -> [FleetCheck.ProviderAnswer] {
        let auth = FleetCredentialsSource.load(pi.home.appendingPathComponent("auth.json")) ?? [:]
        guard !auth.isEmpty else { return [] }
        var answers: [FleetCheck.ProviderAnswer] = []
        var asked: [String] = []
        for id in auth.keys.sorted() {
            let key = ((auth[id] as? [String: Any])?["key"] as? String)?.trimmingCharacters(in: .whitespaces)
            if let key, key.hasPrefix("!") {
                // A key that is a command: it can start when its program is on the login shell's PATH.
                let program = String(key.dropFirst()).split(separator: " ").first.map(String.init) ?? ""
                let name = PiSignInCatalog.name(id)
                guard FleetReadiness.isSafeCommand(program) else {
                    answers.append(.init(id: id, name: name, outcome: .cantStart(program)))
                    continue
                }
                let found = await LoginShell.run("command -v \(program) >/dev/null 2>&1", timeout: 15)
                answers.append(.init(id: id, name: name, outcome: found.status == 0 ? .works : .cantStart(program)))
            } else {
                asked.append(id)
            }
        }
        let checked = await ask(asked)
        for id in asked {
            let name = PiSignInCatalog.name(id)
            switch checked[id] {
            case .works?: answers.append(.init(id: id, name: name, outcome: .works))
            case .rejected(let reason)?: answers.append(.init(id: id, name: name, outcome: .refused(reason)))
            case .unset(let reason)?: answers.append(.init(id: id, name: name, outcome: .refused(reason)))
            case .unreachable?, nil: answers.append(.init(id: id, name: name, outcome: .unknown))
            }
        }
        return answers.sorted { $0.name < $1.name }
    }

    /// pi's check of each provider, through the sign-in bridge; whatever hasn't answered when the time is up is left out.
    private func ask(_ providers: [String]) async -> [String: PiKeyCheck] {
        guard !providers.isEmpty, let package = pi.engine.packageDirectory else { return [:] }
        guard await Task.detached(operation: { [pi] in pi.prepare() }).value == nil,
              let script = try? PiSignInScript.install(in: support) else { return [:] }
        let sdk = URL(fileURLWithPath: package).appendingPathComponent(BundledPiEngine.libraryPath).path
        let bridge = PiSignInBridge(line: PiLaunch.signInBridge(node: pi.engine.node, script: script.path, sdk: sdk, home: pi.files))
        defer { bridge.close() }
        let results = Results()
        let reading = Task {
            for await reply in bridge.replies {
                switch reply {
                case .ready:
                    for (index, provider) in providers.enumerated() { bridge.send(.check(id: "\(index)", provider: provider, key: nil)) }
                case .checked(let id, let result):
                    if let index = Int(id), providers.indices.contains(index) { results.set(providers[index], result) }
                    if results.count == providers.count { return }
                case .failed: return
                default: break
                }
            }
        }
        let limit = Task {
            try? await Task.sleep(for: .seconds(Self.timeout))
            reading.cancel()
        }
        await reading.value
        limit.cancel()
        return results.all
    }

    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: PiKeyCheck] = [:]
        var count: Int { lock.withLock { values.count } }
        var all: [String: PiKeyCheck] { lock.withLock { values } }
        func set(_ provider: String, _ result: PiKeyCheck) { lock.withLock { values[provider] = result } }
    }
}
