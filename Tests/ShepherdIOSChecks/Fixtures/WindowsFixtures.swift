import Foundation
import UIKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// Windows' screens (iPadSplitView, iPadPalette boards): two Shepherd windows side by side, one
// of them holding text sent from the other's thread, a real new window, and the palette's Open
// in new window. Render them with run-simulator.sh -w (an app that supports multiple windows).
extension FixtureCatalog {
    static var windows: [FixtureScreen] {
        let preview = FixtureData.ref(FixtureData.preview)
        let running = FixtureData.ref(FixtureData.extensions)
        return [
            FixtureScreen(name: "windows-palette", hosts: SearchFixtures.hosts(), routes: [.thread(preview)],
                          presented: .search(.palette(query: "review"))),
            FixtureScreen(name: "windows-split", routes: [.thread(running)],
                          prepare: { app in await WindowsFixtures.open(preview, in: app, beside: true) }),
            FixtureScreen(name: "windows-sent", routes: [.thread(running)],
                          prepare: { app in
                              await WindowsFixtures.open(preview, in: app, beside: true)
                              // What Send to… leaves in the other window: the message, in its composer.
                              let store = app.threads.store(for: preview)
                              store.draft = ComposerInsertion.inserting("Reading the extension points first.", into: store.draft)
                          }),
            // A real second window: the simulator's full-screen mode shows it over the first.
            FixtureScreen(name: "windows-new", routes: [.thread(running)],
                          prepare: { app in await WindowsFixtures.open(preview, in: app, beside: false) }),
            // Real scenes, not the split fixture's two views. The runner folds and reopens Duo
            // at the checkpoints, while navigation and both renderers stay alive.
            FixtureScreen(name: "windows-fold", hosts: DesignPadFixtures.hosts(), routes: [.thread(running)],
                          prepare: { app in await WindowsFixtures.fold(preview, in: app) }),
        ]
    }
}

@MainActor
enum WindowsFixtures {
    /// Opens `thread` in a second window, beside the first or as the system opens one, and
    /// waits for it to load.
    static func open(_ thread: AgentRef, in app: MobileApp, beside: Bool) async {
        if beside { FixtureWindows.shared.openBeside(.thread(thread)) } else { FixtureWindows.shared.open(.thread(thread)) }
        await FixtureWindows.wait(seconds: 10) {
            app.windows.open.contains { $0.navigator.selectedThread == thread } && app.threads.store(for: thread).snapshot != nil
        }
        print("FIXTURE WINDOWS \(app.windows.open.count)")
    }

    static func fold(_ thread: AgentRef, in app: MobileApp) async {
        await rendering(app, label: "first scene")
        let waitingView = UIView()
        PadDesignStage.shared.hold(waitingView)
        defer { waitingView.removeFromSuperview() }
        guard let previous = waitingView.window else { FixtureCheck.fail("Renderer must start in the first scene") }
        // SwiftUI opens a real second scene. The existing renderer must follow it, without
        // another hold/add call, when the system backgrounds the first scene.
        await open(thread, in: app, beside: false)
        await FixtureWindows.wait("renderer follows scene activation", seconds: 10) {
            previous.windowScene?.activationState == .background && waitingView.window !== previous
                && waitingView.window?.windowScene?.activationState == .foregroundActive
        }
        FixtureCheck.report("FIXTURE CHECK ok: an existing renderer moves when its scene backgrounds")
        await FixtureWindows.wait("two real window scenes", seconds: 10) { UIApplication.shared.connectedScenes.count == 2 }
        let ids = Set(UIApplication.shared.connectedScenes.map(\.session.persistentIdentifier))
        let threads = Set(app.windows.open.compactMap { $0.navigator.selectedThread })
        FixtureCheck.report("FIXTURE CHECK \(threads.count == 2 ? "ok" : "FAILED"): two scenes keep distinct threads")
        await rendering(app, label: "before folding")

        for (pose, closed) in [("closed", true), ("open", false)] {
            print("FIXTURE POSE \(pose)")
            fflush(stdout)
            await FixtureWindows.wait("hinge \(pose) in both scenes", seconds: 20) {
                app.windows.open.allSatisfy { $0.navigator.hingeClosed == closed }
            }
            await FixtureWindows.wait("renderer in foreground after \(pose)", seconds: 10) {
                let scene = waitingView.window?.windowScene
                return scene?.activationState == .foregroundActive && waitingView.window === DesignRenderAnchor.window
            }
            let sameScenes = ids == Set(UIApplication.shared.connectedScenes.map(\.session.persistentIdentifier))
            let sameThreads = threads == Set(app.windows.open.compactMap { $0.navigator.selectedThread })
            FixtureCheck.report("FIXTURE CHECK \(sameScenes && sameThreads ? "ok" : "FAILED"): \(pose) preserves both scenes and threads")
            await rendering(app, label: pose)
        }
    }

    private static func rendering(_ app: MobileApp, label: String) async {
        let ref = HostDesignRef(host: DesignPadFixtures.ref.host, design: DesignPadFixtures.ref.design)
        let designs = MobileDesigns.of(app.hosts)
        guard let snapshot = await designs.sync(ref), let source = designs.source(ref),
              let path = snapshot.snapshot.index.order.first, let board = snapshot.snapshot.index.boards[path] else {
            FixtureCheck.fail("Design files for window rendering")
        }
        // Different keys force a fresh thumbnail through both renderers at each checkpoint.
        let size = CGSize(width: board.w, height: board.h)
        let image = await DesignRendering.shared.image(ref, source: source, path: path, sha256: label, size: size, width: 160)
        let thumbnails = PadDesignThumbnails.shared
        let version = thumbnails.versions[DesignPadFixtures.ref] ?? 0
        thumbnails.update(DesignPadFixtures.ref, path: path, size: size, sha: label, source: source)
        await FixtureWindows.wait("pad thumbnail \(label)", seconds: 20) { thumbnails.versions[DesignPadFixtures.ref, default: 0] > version }
        do {
            for format in DesignExportFormat.allCases {
                let url = try await DesignRendering.shared.export(ref, source: source, path: path, board: board, name: "fold-check", format: format)
                let data = try Data(contentsOf: url)
                FixtureCheck.report("FIXTURE CHECK \(!data.isEmpty ? "ok" : "FAILED"): \(format.rawValue) export \(label)")
                try FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
        } catch { FixtureCheck.fail("Export \(label): \(error)") }
        FixtureCheck.report("FIXTURE CHECK \(image != nil ? "ok" : "FAILED"): both renderers draw \(label)")
    }
}
