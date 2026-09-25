import Foundation
import UIKit
import ShepherdCore
import ShepherdProtocol

// New thread track's screens: the form, Where it runs (the iPad's Run on popover), the model
// picker, Add repo's folder browser, a host on an older Shepherd, images, an error, and every
// host offline. Hosts answer creationOptions and listDir here; creating anything is refused.
extension FixtureCatalog {
    static var newThread: [FixtureScreen] {
        [
            FixtureScreen(name: "newthread", hosts: NewThreadFixtures.hosts(),
                          routes: NewThreadFixtures.behind, presented: NewThreadFixtures.compose,
                          prepare: { _ in await NewThreadFixtures.form() }),
            FixtureScreen(name: "newthread-where", hosts: NewThreadFixtures.hosts(),
                          routes: NewThreadFixtures.behind, presented: NewThreadFixtures.compose,
                          prepare: { app in await NewThreadFixtures.form { $0.panel = app.navigator.layout == .pad ? .host : .workspace } }),
            FixtureScreen(name: "newthread-repo", hosts: NewThreadFixtures.hosts(),
                          routes: NewThreadFixtures.behind, presented: NewThreadFixtures.compose,
                          prepare: { app in await NewThreadFixtures.form { $0.panel = app.navigator.layout == .pad ? .repo : .workspace } }),
            FixtureScreen(name: "newthread-worktree", hosts: NewThreadFixtures.hosts(),
                          routes: NewThreadFixtures.behind, presented: NewThreadFixtures.compose,
                          prepare: { app in await NewThreadFixtures.form { $0.panel = app.navigator.layout == .pad ? .worktree : .workspace } }),
            FixtureScreen(name: "newthread-models", hosts: NewThreadFixtures.hosts(),
                          routes: NewThreadFixtures.behind, presented: NewThreadFixtures.compose,
                          prepare: { _ in await NewThreadFixtures.form { $0.panel = .model } }),
            FixtureScreen(name: "newthread-folders", hosts: NewThreadFixtures.hosts(),
                          routes: NewThreadFixtures.behind, presented: NewThreadFixtures.compose,
                          prepare: { app in
                              await NewThreadFixtures.form { form in
                                  form.panel = app.navigator.layout == .pad ? .repo : .workspace
                              }
                              try? await Task.sleep(for: .seconds(1))
                              NewThreadModel.active?.browseFolders()
                          }),
            FixtureScreen(name: "newthread-oldhost", hosts: NewThreadFixtures.hosts(oldBuildHost: true),
                          routes: NewThreadFixtures.behind, presented: .newThread(.compose(host: FixtureData.buildBox)),
                          prepare: { app in await NewThreadFixtures.form { $0.panel = app.navigator.layout == .pad ? .host : .workspace } }),
            FixtureScreen(name: "newthread-images", hosts: NewThreadFixtures.hosts(),
                          routes: NewThreadFixtures.behind, presented: NewThreadFixtures.compose,
                          prepare: { _ in
                              await NewThreadFixtures.form { form in
                                  for (index, color) in [UIColor.systemTeal, .systemOrange].enumerated() {
                                      if let image = NewThreadFixtures.image(color, name: "screenshot-\(index + 1)") { form.add(image) }
                                  }
                              }
                          }),
            FixtureScreen(name: "newthread-error", hosts: NewThreadFixtures.hosts(),
                          routes: NewThreadFixtures.behind, presented: NewThreadFixtures.compose,
                          prepare: { _ in
                              await NewThreadFixtures.form { form in
                                  form.errorText = "A branch named \(NewThreadFixtures.branch) already exists on Studio."
                              }
                          }),
            FixtureScreen(name: "newthread-offline", hosts: [NewThreadFixtures.hosts()[2]],
                          presented: NewThreadFixtures.compose,
                          prepare: { _ in await NewThreadFixtures.form() }),
        ]
    }
}

enum NewThreadFixtures {
    static let prompt = "Make tool rows show the command or path instead of “complete”, and add a regression test for it."
    static let branch = "worktree/calm-otter-4821"
    static let compose = MobileRoute.newThread(.compose(host: nil))
    /// The thread the iPad board shows behind the sheet.
    static let behind = [MobileRoute.thread(FixtureData.ref(FixtureData.preview))]

    static let shepherd = Space(id: FixtureData.shepherdSpace.id, name: "shepherd", path: "/Users/dev/code/shepherd")
    static let dashboard = Space(id: SpaceID(rawValue: "space-dashboard"), name: "dashboard-web", path: "/Users/dev/code/dashboard-web")
    static let orders = Space(id: FixtureData.shepherdSpace.id, name: "orders-svc", path: "/home/ci/orders-svc")

    /// FixtureData's hosts with the boards' repos, answering creationOptions and listDir.
    /// `oldBuildHost` makes build-01 an older Shepherd: no creation options, worktrees or
    /// images.
    static func hosts(oldBuildHost: Bool = false) -> [FixtureHostData] {
        var hosts = FixtureData.hosts()
        hosts[0].state.spaces = [shepherd, dashboard, FixtureData.horizonSpace]
        hosts[0].reply = reply
        hosts[1].state.spaces = [orders]
        hosts[1].reply = oldBuildHost ? oldReply : reply
        return hosts
    }

    @Sendable static func reply(_ request: RemoteRequest) -> RemoteReply? {
        switch request {
        case .creationOptions(let id, _, let cwd, let fetchFirst):
            // As a host answers: the base only when asked for a directory.
            return .creationOptions(id: id, options: RemoteCreationOptions(
                base: cwd == nil ? "" : "origin/main", note: cwd == nil ? "" : "origin fetched just now",
                fetchFirst: fetchFirst ?? true, model: "anthropic/claude-opus", thinking: .medium))
        case .listDir(let id, let path):
            let resolved = path.isEmpty ? "/Users/dev" : path
            return .dirListing(id: id, path: resolved, parent: resolved == "/" ? nil : (resolved as NSString).deletingLastPathComponent,
                               dirs: [".config", ".ssh", "code", "Desktop", "Documents", "Downloads", "go", "notes", "src"])
        default:
            return nil
        }
    }

    @Sendable static func oldReply(_ request: RemoteRequest) -> RemoteReply? {
        if case .hello(let id, _, _, _, _) = request {
            return .helloOk(id: id, protocolVersion: RemoteProtocol.version,
                            capabilities: [RemoteProtocol.nativeThreadCapability, RemoteProtocol.pasteCapability])
        }
        return reply(request)
    }

    /// Waits for the form and its host's defaults, fills the board's prompt and branch, then
    /// runs `change`.
    @MainActor static func form(_ change: (NewThreadModel) -> Void = { _ in }) async {
        var model: NewThreadModel?
        for _ in 0..<200 {
            model = NewThreadModel.active
            if let model, model.defaults.ready || model.host?.phase.isConnected != true { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard let model else { return }
        model.prompt = prompt
        if model.usesWorktree { model.setBranch(branch) }
        for _ in 0..<100 where model.usesWorktree && !model.base.resolved {
            try? await Task.sleep(for: .milliseconds(50))
        }
        change(model)
    }

    /// A small screenshot-like image, prepared as an attached one is.
    @MainActor static func image(_ color: UIColor, name: String) -> NewThreadAttachment? {
        let size = CGSize(width: 320, height: 200)
        let rendered = UIGraphicsImageRenderer(size: size).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.white.withAlphaComponent(0.6).setFill()
            context.fill(CGRect(x: 24, y: 24, width: 180, height: 16))
            context.fill(CGRect(x: 24, y: 52, width: 240, height: 12))
            context.fill(CGRect(x: 24, y: 72, width: 200, height: 12))
        }
        guard let data = rendered.pngData() else { return nil }
        return NewThreadImages.prepare(data, name: name)
    }
}
