import Foundation
import Observation
import ShepherdUI

/// One OAuth sign-in, as the sign-in sheet shows it. pi does the work (`pi mcp login <server>`:
/// it finds the sign-in server, registers itself as Shepherd, opens the browser, waits on a loopback
/// redirect and keeps the tokens in its home); this runs that and tells its output as the three
/// steps the sheet draws. Nothing about the sign-in is kept here: the credentials are pi's.
@MainActor
@Observable
final class MCPSignInFlow: Identifiable {
    /// How long pi waits for the browser, in seconds (`pi mcp login --timeout`).
    nonisolated static let timeout: TimeInterval = 300

    let id = UUID()
    let server: String
    private(set) var model: MCPSignInSheetModel
    /// Finished and signed in: the sheet closes a moment later.
    private(set) var succeeded = false
    /// The page pi opened, as it printed it: Open browser again and Copy link use it.
    @ObservationIgnored private(set) var authorizationURL: URL?

    /// Runs `pi mcp <arguments>`, handing each line of its output over; nil when pi's home isn't ready.
    typealias Run = @MainActor ([String], @escaping @Sendable (String) -> Void) async -> MCPCLIResult?

    @ObservationIgnored private let url: URL
    @ObservationIgnored private let run: Run
    @ObservationIgnored private let openURL: @MainActor (URL) -> Void
    @ObservationIgnored private let copy: @MainActor (String) -> Void
    @ObservationIgnored private let finished: @MainActor () -> Void
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var provider: String
    @ObservationIgnored private var domain: String

    init(server: String, url: URL, run: @escaping Run, openURL: @escaping @MainActor (URL) -> Void,
         copy: @escaping @MainActor (String) -> Void, finished: @escaping @MainActor () -> Void) {
        self.server = server
        self.url = url
        self.run = run
        self.openURL = openURL
        self.copy = copy
        self.finished = finished
        provider = Self.providerName(server: server, host: url.host)
        domain = Self.domain(url.host) ?? url.host ?? server
        model = MCPSignInSheetModel(title: "Sign in to \(provider)", subtitle: "Finish signing in on \(domain).", steps: [],
                                    phase: .waiting)
        model.steps = Self.steps(provider: provider, domain: domain)
    }

    /// "Notion" from mcp.notion.com, else the server's own name capitalized.
    nonisolated static func providerName(server: String, host: String?) -> String {
        if let domain = domain(host), let label = domain.split(separator: ".").first, !domain.hasPrefix("127."),
           domain != "localhost" {
            return label.prefix(1).uppercased() + label.dropFirst()
        }
        return server.prefix(1).uppercased() + server.dropFirst()
    }

    /// The last two labels of a host: notion.com from mcp.notion.com.
    nonisolated static func domain(_ host: String?) -> String? {
        guard let host, !host.isEmpty else { return nil }
        if host.allSatisfy({ $0.isNumber || $0 == "." || $0 == ":" }) { return host }
        let labels = host.split(separator: ".")
        return labels.count <= 2 ? host : labels.suffix(2).joined(separator: ".")
    }

    private static func steps(provider: String, domain: String) -> [MCPSignInSheetModel.Step] {
        [
            .init(id: "found", title: "Finding \(provider)’s sign-in server", state: .live),
            .init(id: "registered", title: "Registering Shepherd with \(provider)", state: .pending),
            .init(id: "browser", title: "Waiting for you in the browser",
                  note: "Approve access on \(domain); this closes by itself.", state: .pending),
        ]
    }

    func start() {
        task?.cancel()
        succeeded = false
        authorizationURL = nil
        model = MCPSignInSheetModel(title: "Sign in to \(provider)", subtitle: "Finish signing in on \(domain).",
                                    steps: Self.steps(provider: provider, domain: domain), phase: .waiting)
        task = Task { [weak self] in await self?.signIn() }
    }

    func tryAgain() { start() }

    /// Ends the sign-in: pi's process is stopped and nothing is saved.
    func cancel() {
        task?.cancel()
    }

    func openBrowserAgain() {
        if let authorizationURL { openURL(authorizationURL) }
    }

    func copyLink() {
        if let authorizationURL { copy(authorizationURL.absoluteString) }
    }

    private func set(_ id: String, _ state: MCPSignInSheetModel.Step.State, title: String? = nil, note: String?? = nil) {
        guard let index = model.steps.firstIndex(where: { $0.id == id }) else { return }
        model.steps[index].state = state
        if let title { model.steps[index].title = title }
        if let note { model.steps[index].note = note }
    }

    private var live: String? { model.steps.first { $0.state == .live }?.id }

    /// pi prints the address once, on a line of its own; everything before it is it working out where to sign in.
    private func hear(_ line: String) {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard authorizationURL == nil, text.hasPrefix("http"), let address = URL(string: text), let host = address.host else { return }
        authorizationURL = address
        provider = Self.providerName(server: server, host: host)
        domain = Self.domain(host) ?? domain
        model.title = "Sign in to \(provider)"
        model.subtitle = "Finish signing in on \(domain)."
        set("found", .done, title: "Found \(provider)’s sign-in server", note: .some(nil))
        set("registered", .done, title: "Registered Shepherd with \(provider)", note: .some(nil))
        set("browser", .live, note: .some("pi opened the page; approve access on \(domain) and this closes by itself."))
    }

    private func signIn() async {
        let result = await run(["login", server, "--timeout", String(Int(Self.timeout))]) { [weak self] line in
            Task { @MainActor in self?.hear(line) }
        }
        guard !Task.isCancelled else { return }
        guard let result else {
            fail(result: MCPCLIResult(status: 1, stdout: "", stderr: "Shepherd’s pi isn’t ready: see the problem on the page."))
            return
        }
        if result.status == 0 {
            set("found", .done)
            set("registered", .done)
            set("browser", .done, title: "Signed in", note: .some(nil))
            let tools = result.stdout.split(whereSeparator: \.isNewline).last.flatMap { Self.toolCount(in: String($0)) }
            model.subtitle = tools.map { "\(server) is connected: \($0) tool\($0 == 1 ? "" : "s")." } ?? "Signed in to \(server)."
            model.phase = .done
            succeeded = true
            finished()
        } else {
            fail(result: result)
        }
    }

    /// "(8 tools)" in pi's last line.
    nonisolated static func toolCount(in line: String) -> Int? {
        guard let open = line.range(of: "(", options: .backwards), let close = line.range(of: " tool", range: open.upperBound..<line.endIndex) else { return nil }
        return Int(line[open.upperBound..<close.lowerBound])
    }

    private func fail(result: MCPCLIResult) {
        let failing = live ?? "browser"
        let said = [result.stderr, result.stdout.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""]
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? "pi stopped with status \(result.status)."
        let note = said.split(whereSeparator: \.isNewline).last.map(String.init) ?? said
        switch failing {
        case "found", "registered":
            set(failing, .failed, title: "Couldn’t sign in to \(provider)", note: .some(note))
        default:
            set(failing, .failed, title: result.timedOut || note.contains("not completed") ? "Signing in didn’t finish" : "\(provider) didn’t sign Shepherd in",
                note: .some(note))
        }
        model.subtitle = "Nothing was saved."
        model.details = [result.stdout, result.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
        model.phase = .failed
    }
}
