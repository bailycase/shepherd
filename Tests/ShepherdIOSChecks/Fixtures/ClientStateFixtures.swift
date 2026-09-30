import Foundation
import UIKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

extension FixtureCatalog {
    static var clientState: [FixtureScreen] {
        [FixtureScreen(name: "client-state-regressions", hosts: ClientStateChecks.hosts(), prepare: { app in
            await ClientStateChecks.run(app)
        }), FixtureScreen(name: "forgotten-design-regression", hosts: DesignsFixtures.hosts(updating: false), prepare: { app in
            await ClientStateChecks.forgottenDesign(app)
        }), FixtureScreen(name: "forgotten-automation-regression", hosts: AutomationsFixtureData.fleet(), prepare: { app in
            await ClientStateChecks.forgottenAutomation(app)
        })]
    }
}

/// Real app models with only the asynchronous request boundary substituted. The fixture host
/// still refuses mutations; none of these checks asks it to create an agent or change files.
@MainActor
enum ClientStateChecks {
    nonisolated static func hosts() -> [FixtureHostData] {
        var hosts = NewThreadFixtures.hosts()
        hosts[0].hostSettings = HostSettings(piVersion: "1", defaultModel: "provider/model-a", installedExtensions: ["a"])
        hosts[1].hostSettings = HostSettings(piVersion: "2", defaultModel: "provider/model-b", installedExtensions: ["b", "c"])
        return hosts
    }

    static func check(_ condition: Bool, _ name: String) {
        FixtureCheck.report("FIXTURE CHECK \(condition ? "ok" : "FAILED") client-state: \(name)")
    }

    static func run(_ app: MobileApp) async {
        navigation()
        sceneOwnershipAndForget(app)
        await selectedHostSummaries(app)
        await sentImagesKeepTheNextAttachment()
        await commitAndQueueOwnership()
        await creation(app)
        await review(app)
    }

    static func sentImagesKeepTheNextAttachment() async {
        for outcome in ["accepted", "rejected", "unknown"] {
            let store = NativeThreadStore(pause: { _ in
                let (stream, continuation) = AsyncStream<Void>.makeStream()
                for await _ in stream {}
                continuation.finish()
                throw CancellationError()
            })
            var snapshot = FixtureData.snapshot([])
            snapshot.supportedActions.append("sendImages")
            let gate = ClientStateGate<NativeThreadResult>()
            var submitted: [NativeImage] = []
            var operation: UUID?
            let serving = Task {
                await store.run { request in
                    switch request {
                    case .snapshot: return .snapshot(value: snapshot)
                    case .send(_, _, let id, _, _, let images, _, _, _):
                        operation = id
                        submitted = images ?? []
                        return try await gate.wait()
                    default: return .failure(code: "fixture", message: "Unexpected request")
                    }
                }
            }
            await FixtureWindows.wait(seconds: 5) { store.isLive }
            guard store.isLive else { serving.cancel(); check(false, "send fixture became live"); return }
            let state = ComposerState()
            guard let first = NewThreadFixtures.image(.systemTeal, name: "first"),
                  let second = NewThreadFixtures.image(.systemOrange, name: "next") else {
                serving.cancel(); store.stop(); check(false, "send images prepared"); return
            }
            await state.attach([(first.image.data, "first.png")])
            guard let a = state.attachments.first else {
                serving.cancel(); store.stop(); check(false, "first attachment loaded"); return
            }
            store.draft = "Inspect this"
            let sending = ThreadComposer.send(.followUp, store: store, state: state)
            await FixtureWindows.wait(seconds: 5) { gate.isWaiting }
            guard gate.isWaiting, let operation else {
                serving.cancel(); store.stop(); check(false, "actual composer send reached gate"); return
            }
            // Image preparation is asynchronous too: B must finish while A's send is held.
            await state.attach([(second.image.data, "next.png")])
            guard let b = state.attachments.last, b.id != a.id else {
                gate.finish(.success(.failure(code: "fixture", message: "Image preparation failed")))
                await sending.value
                serving.cancel(); store.stop(); check(false, "next attachment loaded while awaiting send"); return
            }
            check(submitted == [a.image], "only captured image A went to the delayed send")
            switch outcome {
            case "accepted": gate.finish(.success(.accepted(operationID: operation)))
            case "rejected": gate.finish(.success(.failure(code: "refused", message: "Not accepted")))
            default: gate.finish(.failure(RemoteHostClientError.outcomeUnknown(message: "Connection lost")))
            }
            await sending.value
            check(state.attachments.map(\.id) == (outcome == "accepted" ? [b.id] : [a.id, b.id]),
                  "\(outcome) send removes only its acknowledged image IDs")
            check(store.sentCount == (outcome == "accepted" ? 1 : 0), "attachment cleanup follows acceptance")
            serving.cancel()
            store.stop()
            await serving.value
        }
    }

    static func selectedHostSummaries(_ app: MobileApp) async {
        let settings = SettingsStore.of(app.hosts)
        await settings.refresh()
        for host in settings.hosts where host.isConnected {
            guard let value = settings.hostSettings.settings(of: host) else { check(false, "summary host loaded"); continue }
            let nav = MobileNavigator()
            nav.settingsSelection.chosenHost = host.id
            check(settings.defaultsValue(chosenHost: nav.settingsSelection.chosenHost) == HostSettingsPresentation.defaultsValue(value)
                  && settings.extensionsValue(chosenHost: nav.settingsSelection.chosenHost) == HostSettingsPresentation.extensionsValue(value)
                  && settings.agentVersion(chosenHost: nav.settingsSelection.chosenHost) == HostSettingsPresentation.agentVersion(value),
                  "Settings and More summaries follow the scene-selected host")
        }
    }

    static func commitAndQueueOwnership() async {
        let info = CommitFixture.info(drafts: false)
        let readGate = ClientStateGate<RemoteAgentResult>()
        var reads = 0
        let commit = ReviewCommitStore { _ in
            reads += 1
            return try await readGate.wait()
        }
        let opening = Task { await commit.begin() }
        await FixtureWindows.wait(seconds: 5) { readGate.isWaiting }
        guard readGate.isWaiting else { check(false, "commit load reached gate"); return }
        await commit.begin()
        check(reads == 1, "a second commit viewer joins the in-flight load")
        readGate.finish(.success(.commitInfo(info)))
        await opening.value
        commit.title = "Window A's unsaved message"
        let selected = commit.selected
        await commit.begin()
        check(reads == 1 && commit.title == "Window A's unsaved message" && commit.selected == selected,
              "opening a second commit window preserves the shared form")
        for operation in [false, true] {
            let gate = ClientStateGate<RemoteAgentResult>()
            let store = ReviewCommitStore { _ in try await gate.wait() }
            let id = UUID()
            if operation { store.adopt(RemoteWorktreeOperation(id: id, finished: false)) }
            let waiting = Task { if operation { _ = await store.pollOnce() } else { await store.begin() } }
            await FixtureWindows.wait(seconds: 5) { gate.isWaiting }
            guard gate.isWaiting else { check(false, "forget commit reached gate"); return }
            store.invalidate()
            gate.finish(.success(operation ? .worktreeOperation(RemoteWorktreeOperation(id: id, finished: true)) : .commitInfo(info)))
            await waiting.value
            check(store.info == nil && store.operationID == nil && store.operation == nil && store.title.isEmpty,
                  "Forget invalidates late commit load/operation without rollback")
        }
        let state = ComposerState(), a = ComposerPresentation(), b = ComposerPresentation()
        guard let message = ThreadFixtures.queued().queue?.items.first else { check(false, "queue fixture has a message"); return }
        check(state.beginQueueEdit(message, presentation: a), "window A owns the queue editor")
        check(!state.beginQueueEdit(message, presentation: b) && b.editing == nil && a.editing?.id == message.id,
              "window B cannot steal the host's single queue hold")
        let thread = NativeThreadStore()
        let releaseGate = ClientStateGate<NativeThreadResult>()
        var releaseID: UUID?
        let serving = Task {
            await thread.run { request in
                switch request {
                case .snapshot: return .snapshot(value: ThreadFixtures.queued())
                case .queue(_, _, let id, _):
                    releaseID = id
                    return try await releaseGate.wait()
                default: return .failure(code: "fixture", message: "Unexpected request")
                }
            }
        }
        await FixtureWindows.wait(seconds: 5) { thread.isLive }
        await state.closeQueueEdit(presentation: b, store: thread, save: false)
        check(a.editing?.id == message.id && releaseID == nil, "closing a non-owner sends no hold release")
        let closing = Task { await state.closeQueueEdit(presentation: a, store: thread, save: false) }
        await FixtureWindows.wait(seconds: 5) { releaseGate.isWaiting }
        guard releaseGate.isWaiting, let releaseID else {
            serving.cancel(); thread.stop(); check(false, "queue release reached gate"); return
        }
        check(!state.beginQueueEdit(message, presentation: b), "new editor waits until the old hold release finishes")
        releaseGate.finish(.success(.accepted(operationID: releaseID)))
        await closing.value
        check(state.beginQueueEdit(message, presentation: b), "queue editor transfers after acknowledged release")
        serving.cancel()
        thread.stop()
        await serving.value
    }

    static func forgottenDesign(_ app: MobileApp) async {
        let ref = DesignsFixtures.ref(DesignsFixtures.checkout)
        let libraries = HostDesignLibraries.of(app.hosts)
        let phone = MobileDesigns.of(app.hosts)
        let pad = PadDesigns.of(app.hosts)
        await phone.refresh()
        _ = await phone.sync(ref)
        await phone.loadComments(ref)
        weak var canvas = pad.canvas(PadDesignRef(host: ref.host, design: ref.design))
        check(canvas != nil && phone.indexes[ref] != nil, "design data seeded before full host Forget")
        let kept = RemoteDesignCache.Key(host: FixtureData.buildBox, design: DesignID(rawValue: "kept"))
        let bytes = Data("other host".utf8), sha = RemoteDesignCache.sha256(bytes)
        libraries.cache.store(bytes, sha256: sha, in: kept)
        libraries.cache.setPaths(["kept": sha], for: kept)
        do { try app.forget(host: ref.host) } catch { check(false, "fixture full host Forget succeeded"); return }
        check(canvas == nil, "full Forget releases the unmounted iPad canvas")
        check(phone.indexes[ref] == nil && phone.comments[ref] == nil && phone.source(ref) == nil,
              "full Forget evicts phone indexes/comments/source")
        check(libraries.cache.paths(.init(host: ref.host, design: ref.design)).isEmpty
              && libraries.cache.file(kept, path: "kept") == bytes, "full Forget purges only this host's design cache")
        weak var transient = pad.canvas(PadDesignRef(host: ref.host, design: ref.design))
        check(transient == nil && libraries.cache.isForgotten(host: ref.host), "stale design lookup cannot recreate the canvas cache")
    }

    static func forgottenAutomation(_ app: MobileApp) async {
        let gate = ClientStateGate<[AutomationRun]>()
        var reads = 0
        let store = AutomationsStore.of(app.hosts, readRuns: { _, _ in
            reads += 1
            if reads == 1 { return try await gate.wait() }
            return []
        })
        guard let gone = app.hosts.hosts.first(where: { !$0.state.automations.isEmpty }),
              let automation = gone.state.automations.first else { check(false, "automation fixture has a host"); return }
        let key = AutomationKey(host: gone.id, automation: automation.id)
        store.chosen = key
        store.confirming = .init(key: key, kind: .stop)
        let task = Task { await store.refreshRuns() }
        await FixtureWindows.wait(seconds: 5) { gate.isWaiting }
        guard gate.isWaiting else { check(false, "automation read reached gate"); return }
        AutomationsStore.forget(host: gone.id, in: app.hosts)
        gate.finish(.success([]))
        await task.value
        AutomationsStore.choose(key)
        store.chosen = key
        store.confirming = .init(key: key, kind: .stop)
        check(store.chosen == nil && store.confirming == nil && store.details.keys.allSatisfy { $0.host != gone.id },
              "forgotten automation replies and selection cannot recreate host state")
        check(store.model.rows.allSatisfy { $0.key.host != gone.id } && !store.model.rows.isEmpty,
              "forget removes only one host's automations")
    }

    static func sceneOwnershipAndForget(_ app: MobileApp) {
        let a = MobileNavigator(), b = MobileNavigator()
        let ref = FixtureData.ref(FixtureData.preview)
        a.settingsSelection.chosenHost = ref.host
        a.settingsSelection.page = .instructions
        a.settingsSelection.instructionsHost = ref.host
        a.composerPresentation.state(for: ref).choosingModel = true
        a.composerPresentation.state(for: ref).showingContext = true
        a.commitPopover = ref
        check(b.settingsSelection.chosenHost == nil && b.settingsSelection.instructionsHost == nil && b.settingsSelection.page == .appearance,
              "Settings host and page belong to their window")
        check(!b.composerPresentation.state(for: ref).choosingModel && !b.composerPresentation.state(for: ref).showingContext,
              "composer sheets open in one window only")
        b.commitPopover = nil
        check(a.commitPopover == ref, "closing another window's commit does not close this one")
        a.forget(host: ref.host)
        check(a.settingsSelection.chosenHost == nil && a.settingsSelection.instructionsHost == nil && a.commitPopover == nil
              && !a.composerPresentation.state(for: ref).showingContext, "forget clears scene-local host state")

        let forgotten = AgentRef(host: UUID(), agent: AgentID(rawValue: "forgotten"))
        let kept = AgentRef(host: UUID(), agent: AgentID(rawValue: "kept"))
        weak var composer = ComposerStates.shared.state(for: forgotten)
        weak var review = ReviewStores.shared.store(for: forgotten)
        weak var commit = CommitStores.shared.store(for: forgotten, hosts: app.hosts)
        let keptComposer = ComposerStates.shared.state(for: kept)
        let keptReview = ReviewStores.shared.store(for: kept)
        ComposerStates.shared.forget(host: forgotten.host)
        ReviewStores.shared.forget(host: forgotten.host)
        CommitStores.shared.forget(host: forgotten.host)
        check(composer == nil && review == nil && commit == nil, "forget releases unmounted per-host stores")
        check(ComposerStates.shared.state(for: kept) === keptComposer && ReviewStores.shared.store(for: kept) === keptReview,
              "forget keeps other hosts' drafts and reviews")
        ComposerStates.shared.forget(host: kept.host)
        ReviewStores.shared.forget(host: kept.host)
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
