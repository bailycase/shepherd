import Foundation
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
}
