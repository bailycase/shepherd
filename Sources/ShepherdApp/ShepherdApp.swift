import SwiftUI
import ShepherdUI
import AppKit
import ShepherdSessions

/// The one main window's scene id.
enum MainWindow {
    static let id = "main"
    /// Opens (or fronts) the main window; set once the window has appeared, used to reopen it
    /// from the Dock after it was closed.
    @MainActor static var open: (() -> Void)?
}

/// The Mac app, exposed as a library so an Xcode app target can provide the
/// entry point. Launch it with `ShepherdMacApp.main()` — SwiftUI must own the
/// instance for the delegate adaptor and state objects to be managed.
@MainActor
public struct ShepherdMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var vm: ShepherdViewModel
    /// Menus rebuild when a shortcut is rebound: the rebindings are passed into each menu.
    private let keys = KeybindingsStore.shared
    private let themes = ThemeManager.shared

    public init() {
        // Geist and Geist Mono ship in the ShepherdUI bundle; register them before any view draws.
        NWFonts.register()
        _vm = State(initialValue: ShepherdViewModel(server: .shared))
    }

    public var body: some Scene {
        // One window, never tabbed. Sessions belong to the app, not the window: closing it
        // leaves every agent running, and the Dock or Window menu brings it back.
        Window("Shepherd", id: MainWindow.id) {
            RootView(vm: vm)
                // Host role: bind the remote listener if this Mac serves its
                // sessions (the toggle persists; a host stays a host). The
                // TCP listener is independent of the extension socket, so
                // ordering against server.start() does not matter.
                .task {
                    vm.applyRemoteListenerSetting()
                    PiUpdateManager.shared.start()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: AppLayout.windowDefaultWidth, height: AppLayout.windowDefaultHeight)
        .windowResizability(.contentMinSize)
        .commands {
            AppSettingsCommands(vm: vm)
            FileCommands(vm: vm, keys: keys, bindings: keys.overrides)
            ViewCommands(vm: vm, menu: vm.menuState, keys: keys, bindings: keys.overrides)
            PaneCommands(vm: vm, keys: keys, bindings: keys.overrides)
            SpaceCommands(vm: vm, menu: vm.menuState)
            AgentCommands(vm: vm, menu: vm.menuState, keys: keys, bindings: keys.overrides)
            MachineCommands(vm: vm, menu: vm.menuState)
            AppearanceCommands(vm: vm, mode: themes.mode)
        }
    }
}

/// Bare SwiftPM executables launch as background processes; promote to a
/// regular app so the window fronts when run from a terminal.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // One window: no tab bar, and no "Show Tab Bar" menu items.
        NSWindow.allowsAutomaticWindowTabbing = false
        do {
            _ = try ShepherdPiTheme.installedPath(for: ThemeManager.shared.current)
        } catch {
            NSLog("Shepherd: initial theme install failed: \(error)")
        }
        ThemeManager.shared.applyApplicationAppearance()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()

        #if DEBUG
        // Dev builds badge the Dock icon so they're distinguishable from the
        // installed copy in the Dock and ⌘Tab. Runtime-only — Release and
        // Finder are untouched.
        if let icon = NSApp.applicationIconImage {
            let badged = NSImage(size: icon.size, flipped: false) { rect in
                icon.draw(in: rect)
                let text = "DEV" as NSString
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.boldSystemFont(ofSize: rect.height * 0.18),
                    .foregroundColor: NSColor.white,
                ]
                let textSize = text.size(withAttributes: attrs)
                let pad = rect.height * 0.05
                let pill = NSRect(
                    x: rect.midX - textSize.width / 2 - pad,
                    y: rect.height * 0.08,
                    width: textSize.width + pad * 2,
                    height: textSize.height + pad
                )
                NSColor.systemOrange.setFill()
                NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
                text.draw(
                    at: NSPoint(x: pill.midX - textSize.width / 2, y: pill.midY - textSize.height / 2),
                    withAttributes: attrs
                )
                return true
            }
            NSApp.applicationIconImage = badged
        }
        #endif

        // Sessions live and die with the app: start the in-process session
        // server (extension socket) and shut it down on quit so every agent
        // stops when Shepherd stops, like any terminal app.
        do {
            try SessionServer.shared.start()
        } catch {
            NSLog("Shepherd: failed to start session server: \(error)")
        }
    }

    /// Agents keep running with the window closed; only Quit stops them.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clicking the Dock icon with the window closed brings it back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { MainWindow.open?() } }
        return true
    }

    /// Quitting kills every agent process (sessions die with the app), so a
    /// quit while agents are mid-turn asks first. Idle/done agents quit
    /// silently — their transcripts are on disk and respawn on relaunch.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let busy = SessionServer.shared.state.agents.filter {
            $0.status == .working || $0.status == .blocked
        }
        guard !busy.isEmpty else { return .terminateNow }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = busy.count == 1
            ? "1 agent is still working"
            : "\(busy.count) agents are still working"
        let names = busy.prefix(5).map(\.name).joined(separator: "\n")
        let more = busy.count > 5 ? "\n…" : ""
        alert.informativeText = "Quitting stops their processes mid-turn. Conversations stay on disk and reopen on next launch.\n\n\(names)\(more)"
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        SessionServer.shared.stop()
    }

}
