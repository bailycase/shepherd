import AppKit
import SwiftUI
import ShepherdCore
import ShepherdUI

/// What quitting asks while agents are busy. Quitting kills every agent process (sessions die
/// with the app), so an agent mid-turn or waiting on an answer is listed; idle and done agents
/// quit silently, since their transcripts are on disk and respawn on relaunch.
struct QuitPrompt: Equatable {
    struct Row: Identifiable, Equatable {
        let id: AgentID
        let name: String
        let state: AgentState

        /// The sidebar's trailing word for the state.
        var word: String { state == .attention ? "needs you" : "working" }
    }

    /// Longer lists end in "and n more".
    static let listLimit = 5

    /// Every busy agent, listed or not.
    let count: Int
    /// The first `listLimit` of them, in the workspace's order.
    let rows: [Row]

    /// Nil when no agent is working or waiting on an answer.
    init?(agents: [Agent]) {
        let busy = agents.filter { $0.status == .working || $0.status == .blocked }
        guard !busy.isEmpty else { return nil }
        count = busy.count
        rows = busy.prefix(Self.listLimit).map { Row(id: $0.id, name: $0.name, state: AgentState($0.status)) }
    }

    var title: String {
        count == 1 ? "Quit and stop the working agent?" : "Quit and stop every working agent?"
    }

    var subtitle: String {
        count == 1
            ? "1 agent is still working. Its conversation stays on disk and reopens on next launch."
            : "\(count) agents are still working. Their conversations stay on disk and reopen on next launch."
    }

    /// "and 2 more" under a list cut at `listLimit`.
    var more: String? { count > rows.count ? "and \(count - rows.count) more" : nil }
}

/// Whether a quit asks first.
enum QuitPolicy {
    enum Decision: Equatable {
        case quit
        case ask(QuitPrompt)
        /// A quit while the dialog already asks: the first quit still waits on its answer.
        case keepAsking
    }

    /// A log out, restart or shut down never waits on the dialog, even one already showing:
    /// the user already chose to stop everything, and a sheet would hold up the system until
    /// it gave up on the app. `asking` is whether the dialog is up.
    static func decide(agents: [Agent], systemPoweringOff: Bool, asking: Bool) -> Decision {
        if systemPoweringOff { return .quit }
        if asking { return .keepAsking }
        return QuitPrompt(agents: agents).map(Decision.ask) ?? .quit
    }

    /// The `kAEQuitReason` values loginwindow sends with its quit event when the user logs out,
    /// restarts or shuts down.
    static let powerOffReasons: Set<OSType> = [OSType(kAELogOut), OSType(kAEReallyLogOut), OSType(kAERestart), OSType(kAEShutDown)]

    static let loginWindow = "com.apple.loginwindow"

    /// A quit event is a log out, restart or shut down when its reason says so, or when
    /// NSWorkspace announced one and loginwindow sent the event. The announcement alone is not
    /// enough: it stays set after another app cancels the log out, and a later quit from the
    /// Dock or the app switcher must still ask.
    static func isPowerOff(quitReason: OSType?, senderBundleID: String?, workspacePoweringOff: Bool) -> Bool {
        if let quitReason, powerOffReasons.contains(quitReason) { return true }
        return workspacePoweringOff && senderBundleID == loginWindow
    }
}

/// The dialog on the main window while a quit waits for an answer.
struct QuitDialog: View {
    let prompt: QuitPrompt
    let quit: () -> Void
    let cancel: () -> Void

    var body: some View {
        DialogSheet(title: prompt.title, subtitle: prompt.subtitle,
                    actions: [
                        DialogAction("Cancel", kind: .cancel, action: cancel),
                        DialogAction("Quit", kind: .destructive, action: quit),
                    ]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(prompt.rows) { row in
                    HStack(spacing: NW.Space.m) {
                        NWStatusDot(row.state)
                        Text(row.name)
                            .font(.nw(.ui))
                            .foregroundStyle(Color.nw.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: NW.Space.m)
                        Text(row.word)
                            .nwText(.caption)
                            .foregroundStyle(row.state == .attention ? Color.nw.lanternText : Color.nw.textTertiary)
                    }
                    .frame(minHeight: NW.Height.rowCompact)
                    .accessibilityElement(children: .combine)
                }
                if let more = prompt.more {
                    Text(more)
                        .nwText(.caption)
                        .foregroundStyle(Color.nw.textTertiary)
                        .frame(minHeight: NW.Height.rowCompact)
                }
            }
            .padding(.horizontal, NWDialogMetrics.inset)
        }
    }
}

/// Asks before a quit stops working agents. `applicationShouldTerminate` answers
/// `.terminateLater` and the dialog goes on the main window as a sheet, over any sheet already
/// there; the choice becomes `reply(toApplicationShouldTerminate:)`. With the window closed it
/// is reopened first. Only one quit asks at a time.
@MainActor
final class QuitConfirmation {
    static let shared = QuitConfirmation()

    /// Set once NSWorkspace announces a log out, restart or shut down.
    private var workspacePoweringOff = false
    /// The question while a quit waits on it.
    private var pending: QuitPrompt?
    /// The dialog once shown.
    private var panel: NSPanel?

    func watchForPowerOff() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil,
                                                          queue: .main) { _ in
            MainActor.assumeIsolated { QuitConfirmation.shared.workspacePoweringOff = true }
        }
    }

    func shouldTerminate(agents: [Agent]) -> NSApplication.TerminateReply {
        switch QuitPolicy.decide(agents: agents, systemPoweringOff: systemPoweringOff, asking: pending != nil) {
        case .quit:
            dismiss()
            return .terminateNow
        case .ask(let prompt):
            pending = prompt
            present()
            return .terminateLater
        case .keepAsking:
            reveal()
            return .terminateCancel
        }
    }

    /// Only the quit loginwindow sends counts: a log out that another app cancelled must not
    /// let a later quit through unasked, from ⌘Q or from another app's quit event.
    private var systemPoweringOff: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == AEEventClass(kCoreEventClass), event.eventID == AEEventID(kAEQuitApplication) else {
            return false
        }
        let keyword = AEKeyword(kAEQuitReason)
        let reason = event.attributeDescriptor(forKeyword: keyword) ?? event.paramDescriptor(forKeyword: keyword)
        let sender = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))
            .flatMap { NSRunningApplication(processIdentifier: $0.int32Value)?.bundleIdentifier }
        return QuitPolicy.isPowerOff(quitReason: reason?.typeCodeValue, senderBundleID: sender,
                                     workspacePoweringOff: workspacePoweringOff)
    }

    /// The main window (re)appeared: a quit waiting for it asks there, once the window has
    /// finished coming on screen.
    func mainWindowAppeared(_ window: NSWindow) {
        guard pending != nil, panel == nil else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { self.attach(to: window) } }
    }

    private func present() {
        guard let prompt = pending else { return }
        NSApp.unhide(nil)
        NSApp.activate()
        if let window = MainWindow.window, window.isVisible || window.isMiniaturized {
            attach(to: window)
        } else if let open = MainWindow.open {
            // A new window reports itself through `mainWindowAppeared`; one SwiftUI kept and
            // only brings back has no new view to report it, so look for it too.
            open()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let window = MainWindow.window, window.isVisible { self.attach(to: window) }
                }
            }
        } else {
            presentAlone(prompt)
        }
    }

    private func attach(to window: NSWindow) {
        guard let prompt = pending, panel == nil else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        let panel = makePanel(prompt)
        panel.appearance = window.effectiveAppearance
        self.panel = panel
        // Critical: shown at once, even over a sheet the window already has.
        window.beginCriticalSheet(panel)
    }

    /// No main window to ask in (it never appeared): the dialog in a window of its own.
    private func presentAlone(_ prompt: QuitPrompt) {
        guard panel == nil else { return }
        let panel = makePanel(prompt, alone: true)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.level = .modalPanel
        panel.center()
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
    }

    /// A second quit brings the question back to the front, in a window of its own if the main
    /// window never came back.
    private func reveal() {
        NSApp.activate()
        if let panel {
            (panel.sheetParent ?? panel).makeKeyAndOrderFront(nil)
        } else if let pending {
            presentAlone(pending)
        }
    }

    private func finish(quit: Bool) {
        guard pending != nil else { return }
        dismiss()
        NSApp.reply(toApplicationShouldTerminate: quit)
    }

    private func dismiss() {
        pending = nil
        if let panel {
            if let parent = panel.sheetParent { parent.endSheet(panel) } else { panel.orderOut(nil) }
        }
        panel = nil
    }

    /// A sheet has no title bar; a window of its own (`alone`) keeps an empty, transparent one
    /// that the dialog runs under.
    private func makePanel(_ prompt: QuitPrompt, alone: Bool = false) -> NSPanel {
        let host = NSHostingController(rootView: QuitDialog(prompt: prompt, quit: { [weak self] in self?.finish(quit: true) },
                                                            cancel: { [weak self] in self?.finish(quit: false) }))
        host.safeAreaRegions = []
        let panel = QuitPanel(contentViewController: host)
        panel.isReleasedWhenClosed = false
        panel.styleMask = alone ? [.titled, .fullSizeContentView] : [.titled]
        panel.setContentSize(host.view.fittingSize)
        panel.cancel = { [weak self] in self?.finish(quit: false) }
        return panel
    }
}

/// Esc cancels even when no button has focus.
private final class QuitPanel: NSPanel {
    var cancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        cancel?()
    }
}
