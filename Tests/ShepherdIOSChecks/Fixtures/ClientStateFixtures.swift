import Foundation
import UIKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

extension FixtureCatalog {
    static var clientState: [FixtureScreen] {
        [FixtureScreen(name: "client-state-regressions", hosts: NewThreadFixtures.hosts(), prepare: { app in
            await ClientStateChecks.run(app)
        })]
    }
}

/// Real app models with only the asynchronous request boundary substituted. The fixture host
/// still refuses mutations; none of these checks asks it to create an agent or change files.
@MainActor
enum ClientStateChecks {
    static func check(_ condition: Bool, _ name: String) {
        print("FIXTURE CHECK \(condition ? "ok" : "FAILED") client-state: \(name)")
    }

    static func run(_ app: MobileApp) async {
        navigation()
        await creation(app)
        await review(app)
    }

    static func navigation() {
        let a = FixtureData.ref(FixtureData.preview)
        let b = AgentRef(host: a.host, agent: AgentID(rawValue: "another-thread"))
        let routes: [MobileRoute] = [.review(.diff(b, path: "file.swift")), .subagents(.list(b)), .terminal(.panes(b))]
        for route in routes {
            let nav = MobileNavigator()
            nav.adopt(.pad)
            nav.open(.thread(a))
            nav.adopt(.phone)
            nav.homePath = [.thread(b), route]
            check(nav.selectedThread == b, "a compact child route belongs to its current thread")
            nav.adopt(.pad)
            check(nav.padSelection == b && nav.padPath == [route], "widening keeps the pushed screen, not stale thread A")
            let restored = MobileNavigator()
            restored.restore(nav.restoration, hosts: [a.host])
            restored.adopt(.phone)
            check(restored.homePath == [.thread(b), route], "restoration at another width keeps the whole stack")
        }
        let fromNeedsYou = MobileNavigator()
        fromNeedsYou.homePath = [.home(.needsYou), .thread(b), .review(.diff(b, path: "file.swift"))]
        let chain = fromNeedsYou.homePath
        fromNeedsYou.adopt(.pad)
        check(fromNeedsYou.selectedThread == b, "a pushed thread after Home still owns its child screen")
        fromNeedsYou.adopt(.phone)
        check(fromNeedsYou.homePath == chain, "a Home prefix and thread stack round trip without duplication")
        let nav = MobileNavigator()
        nav.padSelection = a
        nav.tab = .settings
        nav.settingsPath = [.settings(.instructions)]
        nav.adopt(.pad)
        check(nav.padSelection == nil && nav.padPath.last == .settings(.instructions), "Settings never revives an old thread")
        nav.adopt(.phone)
        check(nav.tab == .settings && nav.settingsPath == [.settings(.instructions)], "Settings stays in its own tab")
        nav.settingsPath = []
        nav.adopt(.pad)
        check(nav.padPath == [.settings(.root)], "the empty Settings stack is Settings, not Home")
        nav.adopt(.phone)
        check(nav.tab == .settings && nav.settingsPath.isEmpty, "Settings root round trips")
        nav.tab = .home
        nav.homePath = [.home(.more)]
        nav.adopt(.pad)
        nav.adopt(.phone)
        check(nav.homePath == [.home(.more)], "a non-thread destination round trips")
    }

    static func creation(_ app: MobileApp) async {
        let route = MobileRoute.newThread(.compose(host: nil))
        let original = FixtureData.ref(FixtureData.preview)
        for replacement in [nil, route, .settings(.host(nil))] as [MobileRoute?] {
            let nav = MobileNavigator()
            nav.open(.thread(original))
            nav.present(route)
            let gate = ClientStateGate<AgentID>()
            var received: (NewThreadCreation, [NativeImage])?
            let model = NewThreadModel(hosts: app.hosts, threads: app.threads, navigator: nav, preferredHost: original.host,
                                       context: original, create: { _, request, images in
                received = (request, images)
                return try await gate.wait()
            })
            model.begin()
            model.setWorktree(false)
            model.prompt = "Inspect this image"
            guard let attachment = NewThreadFixtures.image(.systemTeal, name: "reference") else {
                check(false, "image fixture prepared"); return
            }
            model.add(attachment)
            await FixtureWindows.wait(seconds: 5) { model.blocker == nil }
            guard model.blocker == nil else { check(false, "creation became ready"); return }
            let starting = model.start()
            await FixtureWindows.wait(seconds: 5) { gate.isWaiting }
            guard gate.isWaiting else { check(false, "creation reached the gate"); return }
            check(received?.0.initialPrompt == "Inspect this image" && received?.1 == [attachment.image],
                  "prompt and images are captured by one creation request")
            if let replacement { nav.dismissPresented(); nav.present(replacement) }
            let owner = nav.presented?.id
            let created = AgentID(rawValue: "fixture-created")
            gate.finish(.success(created))
            await starting?.value
            if replacement != nil {
                check(nav.presented?.id == owner && nav.selectedThread == original, "an old creation cannot dismiss a replacement sheet")
            } else {
                await FixtureWindows.wait(seconds: 5) { nav.selectedThread?.agent == created }
                check(nav.presented == nil && nav.selectedThread?.agent == created, "the owning sheet opens the created thread")
            }
        }
        // The actual client's frame preflight rejects before any create reaches FixtureHost.
        if let client = app.hosts.host(original.host)?.connectedClient,
           let space = app.hosts.host(original.host)?.state.spaces.first,
           client.capabilities.contains(RemoteProtocol.createAgentImagesCapability) {
            do {
                _ = try await client.createAgent(spaceID: space.id, cwd: nil, model: nil, thinking: nil,
                                                 initialPrompt: "Inspect", initialImages: [NativeImage(mimeType: "image/png", data: Data(count: 1_000_000))])
                check(false, "oversized encoded image was refused before creation")
            } catch RemoteHostClientError.rejected(let code, _) {
                check(code == "too_large", "an image under maxBytes but over the encoded frame cap is refused")
            } catch { check(false, "frame preflight returned the wrong failure") }
        } else { check(false, "fixture host supports atomic image creation") }
        // A rejected create retains the form's attachments; there is no one-shot first-send task.
        let nav = MobileNavigator()
        nav.present(route)
        let model = NewThreadModel(hosts: app.hosts, threads: app.threads, navigator: nav, preferredHost: original.host,
                                   context: original, create: { _, _, _ in
            throw RemoteHostClientError.rejected(code: "too_large", message: "Image exceeds the frame limit.")
        })
        model.begin()
        model.setWorktree(false)
        model.prompt = "Inspect this image"
        if let image = NewThreadFixtures.image(.systemTeal, name: "retained") { model.add(image) }
        let attachments = model.attachments.map(\.id)
        await FixtureWindows.wait(seconds: 5) { model.blocker == nil }
        await model.start()?.value
        check(!model.starting && model.errorText != nil && model.attachments.map(\.id) == attachments && nav.presented != nil,
              "creation rejection preserves images and the form")
    }

    static func review(_ app: MobileApp) async {
        let path = "file.swift"
        let revision = ChangesRevision(old: "aaaa", new: "bbbb")
        let entry = ChangesFile(path: path, status: .modified, added: 1, removed: 1)
        let oldGate = ClientStateGate<RemoteAgentResult>()
        let newGate = ClientStateGate<RemoteAgentResult>()
        var requests: [ChangesOptions] = []
        func diff(_ word: String) -> ChangesFileDiff {
            ChangesFileDiff(file: DiffFile(oldPath: path, newPath: path, displayPath: path,
                                          isNew: false, isDeleted: false, isRenamed: false, isBinary: false,
                                          hunks: [DiffHunk(header: "@@ -1 +1 @@", lines: [DiffLine(kind: .added, text: word, oldLine: nil, newLine: 1, id: 1)])]))
        }
        let store = ReviewStore(ref: FixtureData.ref(FixtureData.preview)) { _, _, query in
            switch query {
            case .changesList(let scope, _):
                return .changesList(ChangesList(scope: scope, revision: revision,
                                               comparison: ChangesComparison(head: "working", base: "HEAD"), files: [entry]))
            case .changesFile(_, _, _, let options):
                requests.append(options)
                if requests.count == 1 { return try await oldGate.wait() }
                if requests.count == 2 { return try await newGate.wait() }
                return .changesFile(diff(options.fullFiles ? "whole" : "ignore whitespace"))
            default: throw RemoteHostClientError.rejected(code: "fixture", message: "No overview needed")
            }
        }
        await store.load(hosts: app.hosts)
        let originalLoad = store.ensure(path)
        await FixtureWindows.wait(seconds: 5) { oldGate.isWaiting }
        guard oldGate.isWaiting else { check(false, "review reached the file gate"); return }
        store.setIgnoreWhitespace(true)
        await FixtureWindows.wait(seconds: 5) { newGate.isWaiting }
        guard newGate.isWaiting else {
            oldGate.finish(.success(.changesFile(diff("stale"))))
            await originalLoad?.value
            check(false, "new options reached the file gate"); return
        }
        check(requests.count == 2 && requests.last?.ignoreWhitespace == true, "same-revision options fetch new hunks")
        oldGate.finish(.success(.changesFile(diff("stale"))))
        await originalLoad?.value
        check(store.diff(path) == nil, "an old-options response cannot replace current hunks")
        check(store.ensure(path) == nil, "an old completion cannot clear the newer request's in-flight marker")
        newGate.finish(.success(.changesFile(diff("ignore whitespace"))))
        await FixtureWindows.wait(seconds: 5) { store.diff(path)?.hunks.first?.lines.first?.text == "ignore whitespace" }
        check(store.diff(path)?.hunks.first?.lines.first?.text == "ignore whitespace", "new-options hunks are shown")
        store.setFullFiles(true)
        await FixtureWindows.wait(seconds: 5) { store.diff(path)?.hunks.first?.lines.first?.text == "whole" }
        check(requests.last?.fullFiles == true && !store.opensGaps, "Full files loads whole-file hunks at the same revision")
    }
}

@MainActor
private final class ClientStateGate<Value> {
    private var continuation: CheckedContinuation<Value, Error>?
    var isWaiting: Bool { continuation != nil }
    func wait() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish(_ result: Result<Value, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}
