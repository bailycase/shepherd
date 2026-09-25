import SwiftUI
import UIKit
import ShepherdUI
import ShepherdRemote

/// Where other screens reach the app's windows (iPadSplitView, iPadPalette boards): "Open in new
/// window" for a thread, "Send to…" for text, and the composer's text drop. On iPhone (one
/// window) the window items draw nothing.
@MainActor
enum WindowHooks {
    /// Shows `thread` in a window of its own: the window already showing it, brought forward,
    /// or a new one opened on it.
    static func open(_ thread: AgentRef, from window: MobileWindowSeed, windows: MobileWindows, openWindow: OpenWindowAction) {
        if let existing = windows.window(showing: thread, except: window.id) {
            openWindow(value: existing)
        } else {
            openWindow(value: MobileWindowSeed(opening: .thread(thread)))
        }
    }

    /// Adds `text` to `thread`'s composer (the draft every window shares), then brings forward
    /// the window that shows it.
    static func send(_ text: String, to target: WindowTarget<AgentRef>, threads: ThreadStores, windows: MobileWindows,
                     openWindow: OpenWindowAction) {
        let store = threads.store(for: target.thread)
        let draft = ComposerInsertion.inserting(text, into: store.draft)
        if draft != store.draft { store.draft = draft }
        if let seed = windows.seed(target.window) { openWindow(value: seed) }
    }
}

/// "Open in new window" for a thread: a menu item in the thread's options, the sidebar's and
/// the palette's row menus, or, with `prominent`, the palette preview's button beside Open.
/// `before` runs first (the palette closes).
struct OpenInNewWindowButton: View {
    let thread: AgentRef
    var prominent = false
    var before: (() -> Void)?
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @Environment(\.openWindow) private var openWindow
    @Environment(MobileWindows.self) private var windows
    @Environment(\.mobileWindow) private var window

    var body: some View {
        if supportsMultipleWindows {
            let button = Button("Open in new window", systemImage: "macwindow.badge.plus") {
                before?()
                WindowHooks.open(thread, from: window, windows: windows, openWindow: openWindow)
            }
            if prominent {
                button
                    .labelStyle(.titleOnly)
                    .buttonStyle(.nw(.secondary, size: .l))
                    .nwTouchTarget(height: NW.Height.controlL)
            } else {
                button
            }
        }
    }
}

/// "Send to…": the threads other windows show, each with its host; choosing one adds `text` to
/// that thread's composer and brings its window forward. Nothing while no other window shows a
/// thread.
struct SendToMenu: View {
    let text: String
    /// The thread the text comes from, never offered as a target.
    let source: AgentRef?
    @Environment(MobileHosts.self) private var hosts
    @Environment(ThreadStores.self) private var threads
    @Environment(MobileWindows.self) private var windows
    @Environment(\.mobileWindow) private var window
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let targets = windows.targets(from: window.id, excluding: source)
        if !targets.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Menu {
                ForEach(targets, id: \.self) { target in
                    let host = hosts.host(target.thread.host)
                    Button {
                        WindowHooks.send(text, to: target, threads: threads, windows: windows, openWindow: openWindow)
                    } label: {
                        Text(host?.agent(target.thread.agent)?.name ?? "Thread")
                        if let host { Text(host.name) }
                    }
                }
            } label: {
                Label("Send to", systemImage: "arrow.up.forward.app")
            }
        }
    }
}

/// A turn in a thread on iPad: long-press (or a secondary click) offers Copy and "Send to…",
/// and the turn drags out as text, into another window's composer or another app. Its text is
/// read only when the menu opens or a drag starts.
private struct TurnTransfer: ViewModifier {
    let row: NativeThreadRow
    let thread: AgentRef
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows

    func body(content: Content) -> some View {
        if supportsMultipleWindows {
            content
                .contextMenu {
                    let text = Self.text(row)
                    Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
                        .disabled(text.isEmpty)
                    SendToMenu(text: text, source: thread)
                }
                .draggable(Self.text(row))
        } else {
            content
        }
    }

    /// A user turn's messages, or a reply's text as its footer's Copy takes it.
    static func text(_ row: NativeThreadRow) -> String {
        row.isUser ? row.turn.bubbles.map(\.text).joined(separator: "\n\n") : row.presentation?.copyText ?? ""
    }
}

/// The composer takes text dropped on it: added to the draft after a blank line, the drop
/// target ringed while text is over it. Text dropped on the field itself lands where it falls.
private struct ComposerTextDrop: ViewModifier {
    let thread: AgentRef
    @Environment(ThreadStores.self) private var threads
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .nwFocusRing(targeted, radius: NW.Radius.l)
            .dropDestination(for: String.self) { items, _ in
                let store = threads.store(for: thread)
                let draft = items.reduce(store.draft) { ComposerInsertion.inserting($1, into: $0) }
                guard draft != store.draft else { return false }
                store.draft = draft
                return true
            } isTargeted: { targeted = $0 }
    }
}

extension View {
    /// Copy, "Send to…" and dragging for a turn's text (iPad).
    func turnTransfer(_ row: NativeThreadRow, thread: AgentRef) -> some View {
        modifier(TurnTransfer(row: row, thread: thread))
    }

    /// Text dropped on a thread's composer joins its draft.
    func composerTextDrop(_ thread: AgentRef) -> some View {
        modifier(ComposerTextDrop(thread: thread))
    }
}
