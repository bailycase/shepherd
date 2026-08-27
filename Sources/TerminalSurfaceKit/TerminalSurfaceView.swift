import AppKit
import Foundation
import GhosttyTerminal
import SwiftUI

public struct TerminalSurfaceView: View {
    @ObservedObject private var model: TerminalSurfaceModel
    private let isFocused: Bool
    private let isRendering: Bool
    @State private var attachmentID = UUID()

    /// - Parameter isRendering: false for a pane that is mounted but hidden.
    ///   Its surface keeps its scrollback and PTY grid, but stops drawing —
    ///   otherwise every background agent runs a render loop against the same
    ///   GPU as the pane you are typing in.
    public init(model: TerminalSurfaceModel, isFocused: Bool, isRendering: Bool = true) {
        self.model = model
        self.isFocused = isFocused
        self.isRendering = isRendering
    }

    public var body: some View {
        GhosttyTerminal.TerminalSurfaceView(context: model.viewState)
            // File/image drops are handled by TerminalDropOverlayView, a
            // window-level AppKit overlay (see TerminalDropOverlay.swift).
            // SwiftUI .onDrop cannot work with permanently mounted hidden
            // panes: drag routing ignores opacity and allowsHitTesting, and
            // a rejected drag never falls through to a sibling.
            // Focus is driven through AppKit, not SwiftUI. See
            // TerminalFocusBridge — both SwiftUI focus approaches were tried
            // and measured to not work here.
            .background(TerminalFocusBridge(model: model, isFocused: isFocused))
            .background(TerminalRenderingBridge(model: model, isRendering: isRendering))
            .onAppear {
                model.surfaceViewAppeared(attachmentID)
            }
            .onDisappear {
                model.surfaceViewDisappeared(attachmentID)
            }
            // libghostty assigns the NSView delegate only in makeNSView. If
            // SwiftUI reuses that NSView for another model, output and input
            // stay wired to the previous agent. Key the whole lifecycle so a
            // model change performs paired disappear/appear callbacks too.
            .id(ObjectIdentifier(model))
    }
}


/// Applies `isFocused` to the model's ghostty surface whenever SwiftUI updates
/// the pane.
///
/// **Why this is AppKit and not SwiftUI focus.** Both SwiftUI approaches were
/// implemented and tested against the running app; both left the terminal
/// unfocused until the user clicked it:
///
/// 1. A private `FocusState<Bool>` per pane (`terminalFocused($flag)`).
///    Instrumented on a real run, the flag was set to true and had reverted to
///    false 300ms later — it never once held true across an agent switch, so
///    `makeFirstResponder` was never even attempted.
/// 2. One shared `FocusState<Tag?>` for the whole workspace, keyed by pane
///    (`terminalFocused($focus, equals: tag)`) — the idiomatic pattern, and
///    supported directly by libghostty. Still required a click.
///
/// The cause is that every agent layout stays mounted so panes never unmount
/// (that is what removed the switching flash). SwiftUI will not hand programmatic
/// focus to a view in an inactive part of the hierarchy, and it owns the timing,
/// so the assignment is discarded before it reaches AppKit.
///
/// A zero-size `NSViewRepresentable` in the pane's `background` runs on every
/// SwiftUI update *and* can reach the real window, so focus is applied where it
/// actually takes effect. Revisit if panes ever stop being permanently mounted.
private struct TerminalFocusBridge: NSViewRepresentable {
    let model: TerminalSurfaceModel
    let isFocused: Bool

    /// Remembers what was last applied for this pane. SwiftUI calls
    /// `updateNSView` constantly — for every mounted pane, on every unrelated
    /// state change — and each focus call walks the window's view tree, so
    /// acting on an unchanged value burned real CPU on every keystroke.
    final class Coordinator {
        var applied: Bool?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard context.coordinator.applied != isFocused else { return }
        context.coordinator.applied = isFocused

        // The terminal NSView may not be in the hierarchy yet on this pass, and
        // AppKit ignores makeFirstResponder for a view with no window. Re-assert
        // on the next run-loop turn, once layout has settled.
        let model = model
        let isFocused = isFocused
        DispatchQueue.main.async {
            guard view.window != nil else { return }
            if isFocused {
                model.takeKeyboardFocus()
            } else {
                model.releaseKeyboardFocus()
            }
        }
    }
}

/// Starts and stops a pane's render loop as it is shown and hidden.
///
/// Mounted-but-hidden panes otherwise keep drawing: libghostty runs a display
/// link per surface and only stops it when the surface is marked not visible.
/// Applied on the next run-loop turn for the same reason as focus — the
/// terminal view may not be in the window yet on this pass.
private struct TerminalRenderingBridge: NSViewRepresentable {
    let model: TerminalSurfaceModel
    let isRendering: Bool

    final class Coordinator {
        var applied: Bool?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard context.coordinator.applied != isRendering else { return }
        context.coordinator.applied = isRendering

        let model = model
        let isRendering = isRendering
        // Deferred: reveals arrive from inside SwiftUI's update pass, and a
        // synchronous surface reconfiguration there can race the still-open
        // layout transaction. The model owns retries — dropping the apply
        // because the bridge view was not yet in a window left revealed
        // panes occluded (stale content) and hidden panes rendering.
        DispatchQueue.main.async {
            model.setRenderingActive(isRendering)
        }
    }
}

/// Finds the AppKit view hosting a specific ghostty surface and drives its
/// first-responder state.
///
/// Panes cannot be told apart by position in the view tree: SwiftUI hosts every
/// mounted layout as siblings under one hosting view, so a pane's own terminal
/// is a cousin of its background bridge, not a descendant (measured on a
/// running app: 14 sibling subviews under one hosting view).
///
/// Identity comes from the view's `delegate`, which libghostty assigns once in
/// `makeNSView` and which is exactly the model's `TerminalViewState`. The
/// surface property would be the obvious handle but is internal to libghostty
/// and not `@objc`, so it is unreachable (verified: `responds(to: "surface")`
/// is false).
@MainActor
enum TerminalFirstResponder {
    /// libghostty's surface view class name, used to collect candidate views
    /// cheaply before checking delegates.
    static let surfaceClassName = "AppTerminalView"

    /// True when `view` is a ghostty surface view.
    static func isSurfaceView(_ view: NSView) -> Bool {
        String(describing: type(of: view)) == surfaceClassName
    }

    /// Every ghostty surface view in the window, in tree order.
    static func surfaceViews(in root: NSView?) -> [NSView] {
        guard let root else { return [] }
        var found: [NSView] = []
        if isSurfaceView(root) {
            found.append(root)
        }
        for subview in root.subviews {
            found.append(contentsOf: surfaceViews(in: subview))
        }
        return found
    }

    /// The view whose delegate is `owner` (a model's `TerminalViewState`),
    /// identified by object identity rather than position in the view tree.
    ///
    /// Stops at the first match instead of collecting every surface first: a
    /// window holds one surface per mounted pane, and this runs on focus
    /// changes.
    static func view(ownedBy owner: AnyObject, in window: NSWindow?) -> NSView? {
        guard let window else { return nil }
        return search(window.contentView, owner: owner)
    }

    private static func search(_ view: NSView?, owner: AnyObject) -> NSView? {
        guard let view else { return nil }
        if let delegate = delegate(of: view), delegate === owner {
            return view
        }
        for subview in view.subviews {
            if let found = search(subview, owner: owner) {
                return found
            }
        }
        return nil
    }

    /// `AppTerminalView.delegate` is public, but the concrete class is not
    /// exported, so read it dynamically. Returns nil before libghostty has
    /// assigned one.
    static func delegate(of view: NSView) -> AnyObject? {
        (view as? AppTerminalView)?.delegate
    }
}
