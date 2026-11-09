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
            // The host's default model takes no thinking level: no Thinking chip.
            FixtureScreen(name: "newthread-plain-model", hosts: ThreadFixtures.plainModel(NewThreadFixtures.hosts()),
                          routes: NewThreadFixtures.behind, presented: NewThreadFixtures.compose,
                          prepare: { _ in
                              await NewThreadFixtures.form()
                              await FixtureWindows.wait("new thread model catalog", seconds: 5) { NewThreadModel.active?.models != nil }
                          }),
            FixtureScreen(name: "newthread-where", hosts: NewThreadFixtures.hosts(),
                          routes: NewThreadFixtures.behind, presented: NewThreadFixtures.compose,
                          prepare: { app in
                              await NewThreadFixtures.form { $0.panel = app.navigator.layout == .pad ? .host : .workspace }
                              if app.navigator.layout == .pad { await NewThreadPopoverCheck.run("Run on") }
                          }),
            FixtureScreen(name: "newthread-repo", hosts: NewThreadFixtures.hosts(),
                          routes: NewThreadFixtures.behind, presented: NewThreadFixtures.compose,
                          prepare: { app in
                              await NewThreadFixtures.form { $0.panel = app.navigator.layout == .pad ? .repo : .workspace }
                              if app.navigator.layout == .pad { await NewThreadPopoverCheck.run("Repo") }
                          }),
            FixtureScreen(name: "newthread-worktree", hosts: NewThreadFixtures.hosts(),
                          routes: NewThreadFixtures.behind, presented: NewThreadFixtures.compose,
                          prepare: { app in
                              await NewThreadFixtures.form { form in
                                  form.workspaceAnchor = .worktree
                                  form.panel = app.navigator.layout == .pad ? .worktree : .workspace
                              }
                              if app.navigator.layout == .pad { await NewThreadPopoverCheck.run("New worktree") }
                          }),
            // Where it runs' Base row pushed: the repo's branches, as the Mac's base picker lists them.
            FixtureScreen(name: "newthread-branches", hosts: NewThreadFixtures.hosts(),
                          routes: NewThreadFixtures.behind, presented: NewThreadFixtures.compose,
                          prepare: { app in
                              await NewThreadFixtures.form { form in
                                  form.panel = app.navigator.layout == .pad ? .worktree : .workspace
                              }
                              try? await Task.sleep(for: .seconds(1))
                              NewThreadModel.active?.workspacePath = [.branches]
                              await FixtureWindows.wait("new thread branches", seconds: 5) { NewThreadModel.active?.branches != nil }
                              if app.navigator.layout == .pad { await NewThreadPopoverCheck.run("Base") }
                          }),
            // Where it runs' Repo row pushed: every repo, searchable.
            FixtureScreen(name: "newthread-repos", hosts: NewThreadFixtures.hosts(),
                          routes: NewThreadFixtures.behind, presented: NewThreadFixtures.compose,
                          prepare: { app in
                              await NewThreadFixtures.form { $0.panel = app.navigator.layout == .pad ? .repo : .workspace }
                              if app.navigator.layout != .pad {
                                  try? await Task.sleep(for: .seconds(1))
                                  NewThreadModel.active?.workspacePath = [.repo]
                              }
                              if app.navigator.layout == .pad { await NewThreadPopoverCheck.run("Repo") }
                          }),
            FixtureScreen(name: "newthread-models", hosts: NewThreadFixtures.hosts(),
                          routes: NewThreadFixtures.behind, presented: NewThreadFixtures.compose,
                          prepare: { app in
                              await NewThreadFixtures.form { $0.panel = .model }
                              if app.navigator.layout == .pad { await NewThreadPopoverCheck.run("Model") }
                          }),
            FixtureScreen(name: "newthread-folders", hosts: NewThreadFixtures.hosts(),
                          routes: NewThreadFixtures.behind, presented: NewThreadFixtures.compose,
                          prepare: { app in
                              await NewThreadFixtures.form { form in
                                  form.panel = app.navigator.layout == .pad ? .repo : .workspace
                              }
                              try? await Task.sleep(for: .seconds(1))
                              NewThreadModel.active?.browseFolders()
                              if app.navigator.layout == .pad { await NewThreadPopoverCheck.run("Folders") }
                          }),
            FixtureScreen(name: "newthread-oldhost", hosts: NewThreadFixtures.hosts(oldBuildHost: true),
                          routes: NewThreadFixtures.behind, presented: .newThread(.compose(host: FixtureData.buildBox)),
                          prepare: { app in
                              await NewThreadFixtures.form { $0.panel = app.navigator.layout == .pad ? .host : .workspace }
                              if app.navigator.layout == .pad { await NewThreadPopoverCheck.run("Run on") }
                          }),
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
    /// A working Mac's longer repo list, so Where it runs shows how it scrolls.
    static let moreRepos = ["acme-ui", "ledger-sync", "infra-terraform", "mobile-checkout-experiments", "docs-site", "payments-api",
                            "design-tokens", "data-pipelines"].map {
        Space(id: SpaceID(rawValue: "space-\($0)"), name: $0, path: "/Users/dev/code/\($0)")
    }
    /// A host's catalog across providers, the host's default first.
    static let models = ["anthropic/claude-opus", "anthropic/claude-sonnet", "anthropic/claude-haiku", "openai/gpt-5", "openai/gpt-5-mini",
                         "openai-codex/gpt-5.5-codex", "google/gemini-3-pro", "google/gemini-3-flash", "xai/grok-4",
                         "openrouter/deepseek/deepseek-r2", "ollama/qwen3-coder:32b"]

    /// A working repo's branches, newest commit first: the default base, a branch checked out
    /// in another worktree, remote branches and a few long names.
    static let branches: ChangesBranches = {
        let now = Date().timeIntervalSince1970
        let names: [(String, Bool, String?)] = [
            ("main", false, nil), ("origin/main", true, nil), ("worktree/calm-otter-4821", false, "/Users/dev/.shepherd/worktrees/calm-otter-4821"),
            ("feat/mobile-new-thread-pickers", false, nil), ("origin/feat/mobile-new-thread-pickers", true, nil),
            ("worktree/brisk-heron-1907", false, "/Users/dev/.shepherd/worktrees/brisk-heron-1907"),
            ("fix/tool-rows-show-the-command-or-path-instead-of-complete", false, nil), ("origin/release/2.4", true, nil),
            ("feat/ledger-v2", false, nil), ("chore/bump-swift-term", false, nil), ("origin/nightly", true, nil),
            ("spike/duo-fold-aware-composer-layout-experiments", false, nil), ("docs/remote-protocol", false, nil),
            ("origin/release/2.3", true, nil), ("fix/review-scope-menu", false, nil),
        ]
        return ChangesBranches(defaultBase: "origin/main", recents: ["origin/nightly"], branches: names.enumerated().map { index, branch in
            ChangesBranch(name: branch.0, isRemote: branch.1, worktree: branch.2, isCurrent: index == 0,
                          committedAt: now - Double(index) * 5400)
        })
    }()

    /// FixtureData's hosts with the boards' repos, answering creationOptions and listDir.
    /// `oldBuildHost` makes build-01 an older Shepherd: no creation options, worktrees or
    /// images.
    static func hosts(oldBuildHost: Bool = false) -> [FixtureHostData] {
        var hosts = FixtureData.hosts()
        hosts[0].state.spaces = [shepherd, dashboard, FixtureData.horizonSpace] + moreRepos
        hosts[0].models = models
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
        case .creationBranches(let id, _):
            return .agentResult(id: id, result: .changesBranches(branches))
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
        await FixtureWindows.wait("new thread form and online host defaults", seconds: 10) {
            guard let model = NewThreadModel.active else { return false }
            return model.defaults.ready || model.host?.phase.isConnected != true
        }
        guard let model = NewThreadModel.active else { FixtureCheck.fail("New thread form disappeared") }
        model.prompt = prompt
        if model.usesWorktree { model.setBranch(branch) }
        await FixtureWindows.wait("new thread worktree base", seconds: 5) { !model.usesWorktree || model.base.resolved }
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

/// An iPad New thread popover as drawn (ipad-ui-3): it opens under its anchor, it is a header and a row tall or
/// more, and nothing in it starts above its top edge. With little room under the anchor it gets shorter, keeps its
/// header and scrolls the rest.
@MainActor enum NewThreadPopoverCheck {
    struct Sample: Equatable, CustomStringConvertible {
        var frame: CGRect
        var preferred: CGSize
        var top: CGFloat
        var arrow: UIPopoverArrowDirection
        var description: String { "frame=\(frame) preferred=\(preferred) first top=\(top) arrow=\(arrow.rawValue)" }
    }

    static func run(_ name: String) async {
        SidebarAutomationsCheck.enableAccessibility()
        // Settled: presented, drawn, and the same sample for 10 polls (about 0.5 s). A popover can resize after it appears.
        var last: Sample?
        var steady = 0
        await FixtureWindows.wait("the \(name) popover, presented and settled", seconds: 10) {
            guard let sample = measure() else { steady = 0; last = nil; return false }
            if sample == last { steady += 1 } else { steady = 0; print("FIXTURE ELEMENT \(name) popover \(sample)") }
            last = sample
            return steady >= 10
        }
        guard let sample = last else { FixtureCheck.fail("the \(name) popover closed") }
        func check(_ ok: Bool, _ what: String) { FixtureCheck.report("FIXTURE CHECK \(ok ? "ok" : "FAILED"): \(what)") }
        check(sample.arrow == .up, "the \(name) popover opens under its anchor, arrow up (arrow \(sample.arrow.rawValue))")
        check(sample.frame.height >= MobileLayout.rowHeight * 2,
              "the \(name) popover is a header and a row tall or more (\(Int(sample.frame.height))pt, preferred \(Int(sample.preferred.height))pt)")
        check(sample.top >= sample.frame.minY - 1,
              "nothing in the \(name) popover starts above its top edge (\(Int(max(0, sample.frame.minY - sample.top)))pt above, popover \(Int(sample.frame.height))pt)")
    }

    static func measure() -> Sample? {
        guard let popover, popover.transitionCoordinator == nil, popover.view.window != nil,
              let top = elements(in: popover).map(\.accessibilityFrame).filter({ !$0.isEmpty }).map(\.minY).min() else { return nil }
        return Sample(frame: UIAccessibility.convertToScreenCoordinates(popover.view.bounds, in: popover.view),
                      preferred: popover.preferredContentSize, top: top,
                      arrow: popover.popoverPresentationController?.arrowDirection ?? .unknown)
    }

    /// The last popover in the primary scene's presentation chains (the New thread sheet presents it).
    static var popover: UIViewController? {
        var found: UIViewController?
        for window in FixtureWindows.shared.primary?.windows ?? [] {
            var top = window.rootViewController
            while let next = top?.presentedViewController {
                if next.modalPresentationStyle == .popover { found = next }
                top = next
            }
        }
        return found
    }

    /// Its drawn accessibility elements. A hidden view draws none (the worktree page hides its navigation bar).
    static func elements(in controller: UIViewController) -> [NSObject] {
        var found: [NSObject] = []
        collect(controller.view, into: &found)
        return found
    }

    private static func collect(_ object: NSObject, into found: inout [NSObject], depth: Int = 0) {
        guard depth < 60 else { return }
        guard let view = object as? UIView else {
            found.append(object)
            for case let item as NSObject in object.accessibilityElements ?? [] { collect(item, into: &found, depth: depth + 1) }
            return
        }
        guard !view.isHidden, view.alpha > 0.01 else { return }
        if view.isAccessibilityElement { found.append(view) }
        if let list = view.accessibilityElements {
            for case let item as NSObject in list { collect(item, into: &found, depth: depth + 1) }
        } else if !view.isAccessibilityElement {
            let count = view.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                for index in 0..<count {
                    if let item = view.accessibilityElement(at: index) as? NSObject { collect(item, into: &found, depth: depth + 1) }
                }
            }
        }
        for subview in view.subviews { collect(subview, into: &found, depth: depth + 1) }
    }
}
