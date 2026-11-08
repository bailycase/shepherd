import Foundation
import SwiftUI
import UIKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// Files (DuoSidePaneTabs, Files card): a remote thread's folder over `files.v1`. The pane has no route of its own yet (the side
// pane mounts it), so these screens present `ThreadFilesScreen` over the thread, as a push on compact width would show it.
// `files-tree` opens two folders, `files-file` reads a file in place, `files-old-host` is a host without the capability.
extension FixtureCatalog {
    static var files: [FixtureScreen] {
        let thread = MobileRoute.thread(FilesFixture.ref)
        return [
            FixtureScreen(name: "files-tree", hosts: FilesFixture.hosts(), routes: [thread], prepare: { app in
                let model = FilesFixture.present(app)
                await model.loadIfNeeded()
                await model.toggle("Widgets")
                await model.toggle("Intents")
            }),
            FixtureScreen(name: "files-file", hosts: FilesFixture.hosts(), routes: [thread], prepare: { app in
                let model = FilesFixture.present(app)
                await model.loadIfNeeded()
                await model.toggle("Widgets")
                await model.open("Widgets/NeedsYouWidget.swift")
            }),
            FixtureScreen(name: "files-unavailable", hosts: FilesFixture.emptyHosts(), prepare: { app in
                guard let host = app.hosts.host(FilesFixture.ref.host), host.phase.isConnected,
                      host.agent(FilesFixture.ref.agent) == nil else {
                    FixtureCheck.fail("Files unavailable fixture requires a connected host without the thread")
                }
                FilesFixture.presentScreen(app)
            }),
            // iPadPaneFiles: the pane beside the running thread, two tabs, the person's unsaved lines and the agent's.
            FixtureScreen(name: "files-pad-editor", hosts: FilesPadFixture.hosts(), routes: [.thread(FilesPadFixture.ref), .sidePane(.files(FilesPadFixture.ref))],
                          prepare: { app in await FilesPadFixture.edit(app, conflict: false) }),
            // The same, after Save found the file changed on the host: the conflict banner.
            FixtureScreen(name: "files-pad-conflict", hosts: FilesPadFixture.hosts(), routes: [.thread(FilesPadFixture.ref), .sidePane(.files(FilesPadFixture.ref))],
                          prepare: { app in await FilesPadFixture.edit(app, conflict: true) }),
            FixtureScreen(name: "files-old-host", hosts: FilesFixture.hosts(capable: false), routes: [thread], prepare: { app in
                _ = FilesFixture.present(app)
            }),
        ]
    }
}

enum FilesFixture {
    static let ref = FixtureData.ref(FixtureData.preview)

    static let listings: [String: ThreadFileListing] = [
        "": ThreadFileListing(entries: [
            ThreadFileEntry(name: "Intents", kind: .directory), ThreadFileEntry(name: "Sources", kind: .directory),
            ThreadFileEntry(name: "Tests", kind: .directory), ThreadFileEntry(name: "Widgets", kind: .directory),
            ThreadFileEntry(name: "AGENTS.md", kind: .file, size: 3_310), ThreadFileEntry(name: "render.py", kind: .file, size: 1_204),
        ]),
        "Widgets": ThreadFileListing(entries: [ThreadFileEntry(name: "NeedsYouWidget.swift", kind: .file, size: 1_018),
                                               ThreadFileEntry(name: "WorkingCountWidget.swift", kind: .file, size: 744)]),
        "Intents": ThreadFileListing(entries: [ThreadFileEntry(name: "StartThreadIntent.swift", kind: .file, size: 512)]),
    ]

    static let widget = """
    import SwiftUI
    import WidgetKit

    /// The threads waiting on you, newest first.
    struct NeedsYouWidget: Widget {
        let kind = "NeedsYou"

        var body: some WidgetConfiguration {
            StaticConfiguration(kind: kind, provider: NeedsYouProvider()) { entry in
                NeedsYouView(entry: entry)
            }
            .configurationDisplayName("Needs you")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        }
    }

    """

    static func hosts(capable: Bool = true) -> [FixtureHostData] {
        var hosts = FixtureData.hosts()
        if capable {
            hosts[0].reply = { request in
                switch request {
                case .agentQuery(let id, _, .files(let path, _)):
                    guard let listing = listings[path] else { return .error(id: id, code: "not_found", message: "No such file or folder") }
                    return .agentResult(id: id, result: .files(listing))
                case .agentQuery(let id, _, .fileRead(let path)):
                    guard path == "Widgets/NeedsYouWidget.swift" else { return .error(id: id, code: "not_found", message: "No such file or folder") }
                    return .agentResult(id: id, result: .fileData(Data(widget.utf8)))
                default: return nil
                }
            }
        } else {
            hosts[0].capabilities = hosts[0].defaultCapabilities.filter { $0 != RemoteProtocol.filesCapability }
        }
        return hosts
    }

    static func emptyHosts() -> [FixtureHostData] {
        var hosts = hosts()
        hosts[0].state = ShepherdState()
        hosts[0].threads = [:]
        return hosts
    }

    /// Presents Files over the thread, full screen in its own navigation stack, and returns its tree.
    @MainActor static func present(_ app: MobileApp) -> ThreadFilesModel {
        presentScreen(app)
        return ThreadFilesStores.shared.model(for: ref, hosts: app.hosts)
    }

    @MainActor static func presentScreen(_ app: MobileApp) {
        let root = NavigationStack { ThreadFilesScreen(thread: ref) }.environment(app.hosts).environment(app.threads).environment(app.navigator)
        let controller = UIHostingController(rootView: root)
        // Over, not instead of, the window's root: a removed root unregisters the window and the hosts disconnect.
        controller.modalPresentationStyle = .overFullScreen
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.keyWindow
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        top?.present(controller, animated: false)
    }
}

/// iPadPaneFiles's data: a made-up checkout app on build-01, its agent editing PromoField.tsx.
@MainActor
enum FilesPadFixture {
    static let agent = AgentID(rawValue: "agent-pay-jump")
    static let ref = FixtureData.ref(agent, on: FixtureData.buildBox)
    static let space = Space(id: SpaceID(rawValue: "space-acme-web"), name: "acme-web", path: "/Users/dev/acme-web")
    static let checkout = "src/components/Checkout.tsx"

    static func dir(_ name: String) -> ThreadFileEntry { ThreadFileEntry(name: name, kind: .directory) }
    static func file(_ name: String) -> ThreadFileEntry { ThreadFileEntry(name: name, kind: .file, size: 2_048) }

    static let listings: [String: ThreadFileListing] = [
        "": ThreadFileListing(entries: [dir("public"), dir("src"), dir("tests"), file("AGENTS.md"), file("package.json"), file("vite.config.ts")]),
        "src": ThreadFileListing(entries: [dir("components"), dir("hooks"), dir("pages"), dir("styles"), file("main.tsx")]),
        "src/components": ThreadFileListing(entries: [file("Checkout.tsx"), file("OrderSummary.tsx"), file("PromoField.tsx"), file("PromoList.tsx")]),
        "src/styles": ThreadFileListing(entries: [file("tokens.css")]),
    ]

    /// Checkout.tsx before the agent's change, after it, and the person's unsaved edit over that.
    static let before = """
    export function Checkout({ cart }: Props) {
      const [promoOpen, setPromoOpen] = useState(false);
      const pay = usePayment(cart.id);

      return (
        <form className="checkout" onSubmit={pay.submit}>
          <ContactFields />
          <CardFields />
          <OrderSummary cart={cart} />
          {promoOpen && <PromoField onApply={cart.applyPromo} />}
          <div className="checkout-actions">
            <Button className="pay" size="lg">
              {payLabel}
            </Button>
          </div>
        </form>
      );
    }

    """
    static let agentText = """
    export function Checkout({ cart }: Props) {
      const [promoOpen, setPromoOpen] = useState(false);
      const pay = usePayment(cart.id);

      return (
        <form className="checkout" onSubmit={pay.submit}>
          <ContactFields />
          <CardFields />
          {promoOpen ? (
            <PromoField onApply={cart.applyPromo} />
          ) : (
            <LinkButton onClick={openPromo}>Have a promo code?</LinkButton>
          )}
          <OrderSummary cart={cart} />
          <div className="checkout-actions">
            <Button className="pay" size="lg">
              {payLabel}
            </Button>
          </div>
        </form>
      );
    }

    """
    static let mine = agentText
        .replacingOccurrences(of: "<Button className=\"pay\" size=\"lg\">", with: "<Button className=\"pay\" size=\"lg\" disabled={pay.pending}>")
        .replacingOccurrences(of: "{payLabel}", with: "{pay.pending ? <Spinner /> : payLabel}")
    static let theirs = agentText.replacingOccurrences(of: "<OrderSummary cart={cart} />", with: "<OrderSummary cart={cart} compact />")

    /// Reads of Checkout.tsx: the version before the agent's change first, the agent's after it.
    final class Reads: @unchecked Sendable {
        let lock = NSLock()
        var count = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
    }

    static func hosts() -> [FixtureHostData] {
        let started = Date().timeIntervalSince1970 * 1000 - FixtureData.start - 12_000
        let thread = FixtureData.snapshot([
            FixtureData.user("p1", "The promo list isn’t keyboard friendly. Can you fix that? I’ll add the loading state myself.", at: started - 60_000),
            FixtureData.tool("p2", "read", args: #"{"path":"src/components/PromoList.tsx"}"#, output: "export function PromoList", at: started - 40_000),
            FixtureData.tool("p3", "read", args: #"{"path":"src/components/PromoField.tsx"}"#, output: "export function PromoField", at: started - 30_000),
            FixtureData.tool("p4", "edit", args: #"{"path":"src/components/PromoField.tsx","oldText":"onKeyDown","newText":"arrow keys + Enter"}"#,
                             status: "running", at: started),
        ], running: true)
        let reads = Reads()
        var host = FixtureHostData(id: FixtureData.buildBox, name: "build-01", state: ShepherdState(spaces: [space], agents: [
            Agent(id: agent, name: "Fix pay button jump", spaceID: space.id, tabID: TabID(rawValue: "tab-pay-jump"), status: .working,
                  nameIsFinal: true, worktreeBranch: "fix/pay-jump", checkout: AgentCheckout(branch: "fix/pay-jump", changedFiles: 2)),
        ]), threads: [agent: thread])
        host.reply = { request in
            switch request {
            case .agentQuery(let id, _, .files(let path, _)):
                guard let listing = listings[path] else { return .error(id: id, code: "not_found", message: "No such file or folder") }
                return .agentResult(id: id, result: .files(listing))
            case .agentQuery(let id, _, .fileRead(let path)):
                let text = path == checkout ? (reads.next() == 1 ? before : agentText) : "export function \((path as NSString).lastPathComponent)() {}\n"
                return .agentResult(id: id, result: .fileData(Data(text.utf8)))
            case .agentQuery(let id, _, .fileWrite):
                return .agentResult(id: id, result: .fileWrite(.changed(theirs)))
            default: return nil
            }
        }
        return [host]
    }

    static func edit(_ app: MobileApp, conflict: Bool) async {
        // The board's thread has its sidebar hidden, so the pane is wide enough for the tree beside the editor.
        app.navigator.padColumns = .detailOnly
        let model = ThreadFilesStores.shared.model(for: ref, hosts: app.hosts)
        await FixtureCheck.wait("the Files tree", seconds: 20) { model.phase == .loaded }
        for folder in ["src", "src/components", "src/styles"] { await model.toggle(folder) }
        await model.open(checkout)
        await model.checkDisk()
        await model.open("src/components/PromoField.tsx")
        await model.open(checkout)
        model.setText(mine, for: checkout)
        if conflict { await model.save() }
        // Until it holds: the split view may write its own columns back while it settles its first layout.
        await FixtureCheck.wait("the thread without its sidebar", seconds: 10) {
            if app.navigator.padColumns != .detailOnly { app.navigator.padColumns = .detailOnly }
            return splitView()?.displayMode == .secondaryOnly && splitView()?.transitionCoordinator == nil
        }
        let edit = model.edits[checkout]
        let ok = edit?.isDirty == true && edit?.before == before && (conflict ? edit?.conflict == theirs : edit?.conflict == nil)
        FixtureCheck.report("FIXTURE CHECK \(ok ? "ok" : "FAILED"): Checkout.tsx has unsaved edits over the agent's change\(conflict ? " and a conflict" : "")")
    }

    static func splitView() -> UISplitViewController? {
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.keyWindow
        func find(_ controller: UIViewController?) -> UISplitViewController? {
            guard let controller else { return nil }
            if let split = controller as? UISplitViewController { return split }
            return controller.children.lazy.compactMap(find).first ?? find(controller.presentedViewController)
        }
        return find(window?.rootViewController)
    }
}
