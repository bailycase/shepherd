import SwiftUI

/// The terminal panel's measures (TerminalSplit and TerminalStates boards on the Mac, iPadTerminal
/// on iPad): a strip of tabs over the terminal, under the thread and its composer.
public enum NWTerminalMetrics {
    #if os(iOS)
    public static let panelHeight: CGFloat = 340
    public static let tabBarHeight: CGFloat = 46
    public static let tabHeight: CGFloat = 32
    /// The tab bar's icon buttons are drawn this size and hit at 44.
    public static let buttonSize: CGFloat = 34
    public static let contentPadding = EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)
    #else
    public static let panelHeight: CGFloat = 330
    public static let tabBarHeight: CGFloat = 38
    public static let tabHeight: CGFloat = 26
    public static let buttonSize: CGFloat = NW.Height.controlS
    public static let contentPadding = EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)
    #endif
    /// Never shorter than a tab bar and a few lines.
    public static let minimumPanelHeight: CGFloat = 120
    /// What the thread keeps above the panel.
    public static let minimumThreadHeight: CGFloat = 160
    /// How near a third, a half or two-thirds a drag snaps to it.
    public static let snapTolerance: CGFloat = 12
    /// The divider's drag area along the panel's top edge.
    public static let dividerHitHeight: CGFloat = 9
    /// The key row (touch only): 34pt keycaps at least 44 wide.
    public static let keyHeight: CGFloat = 34
    public static let keyMinWidth: CGFloat = 44
    /// The thread folded to one line over a maximized panel (TerminalStates): 40pt, 14pt in
    /// before and 10 after, 10pt gaps.
    public static let foldedThreadHeight: CGFloat = 40
    public static let foldedThreadLeading: CGFloat = 14
    public static let foldedThreadTrailing: CGFloat = 10
    public static let foldedThreadGap: CGFloat = 10
    /// A pane's header in a tab of several panes (TerminalPane): 26pt, 10pt in at both sides.
    public static let paneHeaderHeight: CGFloat = 26
    public static let paneHeaderPadding: CGFloat = 10
    /// The bar that sends a selection to the agent (TerminalPane): 4pt in, 4pt apart, and this
    /// far from the selection and the pane's edge.
    public static let selectionBarPadding: CGFloat = 4
    public static let selectionBarRadius: CGFloat = 9
    public static let selectionBarInset: CGFloat = 8
    /// The new terminal menu (NewTerminalMenu).
    public static let menuWidth: CGFloat = 290
    public static let menuTallRowHeight: CGFloat = 36
    public static let menuRadius: CGFloat = 10
}

/// One tab in the panel (TerminalTab · states board).
public struct NWTerminalTab: Equatable, Identifiable, Sendable {
    public enum Activity: Equatable, Sendable {
        /// The shell waits at its prompt.
        case idle
        /// A command runs in it.
        case running
        /// It printed something since it was last on screen.
        case unseen
        /// Its process exited; its output stays until the host closes it.
        case exited(failed: Bool)
    }

    public let id: String
    /// The shell or the running command ("zsh", "make dev").
    public let title: String
    /// The host a remote tab runs on; nil on this Mac.
    public let host: String?
    public let activity: Activity
    /// How many panes the tab splits into, when more than one.
    public let panes: Int

    public init(id: String, title: String, host: String? = nil, activity: Activity = .idle, panes: Int = 1) {
        self.id = id
        self.title = title
        self.host = host
        self.activity = activity
        self.panes = panes
    }
}

/// The panel's tab strip: the tabs, + for a new one, then the panel's own controls (split,
/// maximize, hide) at the trailing end. The selected tab carries its close button.
public struct NWTerminalTabBar<Trailing: View>: View {
    let tabs: [NWTerminalTab]
    let selection: String?
    let select: (String) -> Void
    let close: ((String) -> Void)?
    let newTab: (() -> Void)?
    let newTabHelp: String
    let menu: ((_ tab: String?, _ anchor: CGFloat) -> Void)?
    @ViewBuilder let trailing: () -> Trailing
    /// Where + and each tab start along the strip, for the menu to hang from.
    @State private var anchors: [String: CGFloat] = [:]

    /// `menu`, where given, opens the new terminal menu (NewTerminalMenu) from + (`tab` nil) and
    /// from a right-click on a tab, at `anchor` along the strip; + then opens the menu rather
    /// than a tab.
    public init(_ tabs: [NWTerminalTab], selection: String?, select: @escaping (String) -> Void,
                close: ((String) -> Void)? = nil, newTab: (() -> Void)? = nil, newTabHelp: String = "New terminal",
                menu: ((_ tab: String?, _ anchor: CGFloat) -> Void)? = nil,
                @ViewBuilder trailing: @escaping () -> Trailing) {
        self.tabs = tabs
        self.selection = selection
        self.select = select
        self.close = close
        self.newTab = newTab
        self.newTabHelp = newTabHelp
        self.menu = menu
        self.trailing = trailing
    }

    private static var space: String { "nwTerminalTabBar" }
    private static var plusAnchor: String { "+" }

    public var body: some View {
        HStack(spacing: NW.Space.xxs) {
            ScrollView(.horizontal) {
                HStack(spacing: NW.Space.xxs) {
                    ForEach(tabs) { tab in
                        NWTerminalTabView(tab: tab, isSelected: tab.id == selection, select: { select(tab.id) },
                                          close: close.map { close in { close(tab.id) } })
                            .modifier(AnchorReader(id: tab.id, anchors: $anchors))
                            #if os(macOS)
                            .nwSecondaryClick(enabled: menu != nil) { menu?(tab.id, anchors[tab.id] ?? 0) }
                            #endif
                    }
                    if let newTab {
                        Button {
                            if let menu { menu(nil, anchors[Self.plusAnchor] ?? 0) } else { newTab() }
                        } label: { Image(systemName: "plus") }
                            .buttonStyle(.nwIcon(size: NWTerminalMetrics.buttonSize))
                            .nwHelp(newTabHelp)
                            .accessibilityLabel(newTabHelp)
                            .modifier(AnchorReader(id: Self.plusAnchor, anchors: $anchors))
                    }
                }
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            Spacer(minLength: NW.Space.m)
            HStack(spacing: NW.Space.xxs) { trailing() }
                .buttonStyle(.nwIcon(size: NWTerminalMetrics.buttonSize))
        }
        .padding(.horizontal, NW.Space.m)
        .frame(minHeight: NWTerminalMetrics.tabBarHeight)
        .frame(maxWidth: .infinity)
        // A strip of chrome over the terminal: it grows with Dynamic Type, but not past a size
        // that leaves room for the terminal under it.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .background(Color.nw.bgWindow)
        .overlay(alignment: .top) { NWHairline(color: .nw.lineStrong) }
        .overlay(alignment: .bottom) { NWHairline() }
        .coordinateSpace(.named(Self.space))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Terminal tabs")
    }

    /// Notes where a tab or + starts along the strip, scrolled or not.
    private struct AnchorReader: ViewModifier {
        let id: String
        @Binding var anchors: [String: CGFloat]

        func body(content: Content) -> some View {
            content.onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(NWTerminalTabBar.space)).minX } action: {
                anchors[id] = $0
            }
        }
    }
}

/// A tab: the terminal glyph (a spinner while a command runs), the title in mono, the host of a
/// selected remote tab, a running-blue dot for output you have not seen, and the selected tab's close.
public struct NWTerminalTabView: View {
    let tab: NWTerminalTab
    let isSelected: Bool
    let select: () -> Void
    let close: (() -> Void)?
    @State private var hovering = false

    public init(tab: NWTerminalTab, isSelected: Bool, select: @escaping () -> Void, close: (() -> Void)? = nil) {
        self.tab = tab
        self.isSelected = isSelected
        self.select = select
        self.close = close
    }

    public var body: some View {
        let nw = Color.nw
        HStack(spacing: 0) {
            Button(action: select) {
                HStack(spacing: NW.Space.s) {
                    glyph
                    Text(tab.title)
                        .font(.nw(.mono))
                        .foregroundStyle(isSelected ? nw.textPrimary : nw.textSecondary)
                        .lineLimit(1)
                    if tab.panes > 1 {
                        Text("\(tab.panes)")
                            .font(.nw(.micro, weight: .regular))
                            .foregroundStyle(nw.textTertiary)
                    }
                    // The selected tab names its host (TerminalTab · states); the rest share it.
                    if isSelected, let host = tab.host {
                        Label(host, systemImage: "desktopcomputer")
                            .labelStyle(NWTerminalHostLabelStyle())
                            .font(.nw(.micro, weight: .regular))
                            .foregroundStyle(nw.textTertiary)
                            .lineLimit(1)
                    }
                    if tab.activity == .unseen {
                        Circle().fill(nw.running).frame(width: 6, height: 6)
                    }
                }
                .padding(.leading, NW.Space.m)
                .padding(.trailing, isSelected && close != nil ? NW.Space.xs : NW.Space.m)
                .frame(minHeight: NWTerminalMetrics.tabHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityActions {
                if let close { Button("Close", action: close) }
            }
            if isSelected, let close {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(nw.textTertiary)
                        .frame(width: NWTerminalMetrics.tabHeight * 0.75)
                        .frame(minHeight: NWTerminalMetrics.tabHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .nwTouchTarget(height: NWTerminalMetrics.tabHeight, width: NWTerminalMetrics.tabHeight * 0.75)
                .nwHelp("Close terminal")
                .accessibilityLabel("Close \(tab.title)")
            }
        }
        .background(isSelected ? nw.bgSelected : hovering ? nw.bgHover : .clear,
                    in: RoundedRectangle(cornerRadius: NW.Radius.s))
        .onHover { hovering = $0 }
        .nwAnimation(.hover, value: hovering)
        .fixedSize()
    }

    @ViewBuilder private var glyph: some View {
        let nw = Color.nw
        switch tab.activity {
        case .running:
            ProgressView().progressViewStyle(NWSpinnerStyle(size: 11))
        case .exited(let failed):
            Image(systemName: "terminal")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(failed ? nw.failed : nw.textTertiary)
        case .idle, .unseen:
            Image(systemName: "terminal")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isSelected ? nw.textPrimary : nw.textTertiary)
        }
    }

    private var accessibilityLabel: String {
        var parts = [tab.title]
        if let host = tab.host { parts.append("on \(host)") }
        if tab.panes > 1 { parts.append("\(tab.panes) panes") }
        switch tab.activity {
        case .idle: break
        case .running: parts.append("running")
        case .unseen: parts.append("new output")
        case .exited(let failed): parts.append(failed ? "exited with an error" : "exited")
        }
        return parts.joined(separator: ", ")
    }
}

private struct NWTerminalHostLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: NW.Space.xxs) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// One key of the touch key row.
public struct NWTerminalKeycap: Equatable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let spokenLabel: String
    /// A modifier latched for the next key (Ctrl, ⌥): drawn on.
    public let isLatched: Bool

    public init(id: String, label: String, spokenLabel: String, isLatched: Bool = false) {
        self.id = id
        self.label = label
        self.spokenLabel = spokenLabel
        self.isLatched = isLatched
    }
}

/// The key row over the software keyboard (iPadTerminal board): Esc, Tab, Ctrl, ⌥, the symbols
/// a shell needs and the arrows, as 34pt keycaps at least 44 wide with 44pt hit areas. One row
/// where it fits (iPad, a phone in landscape); on a phone in portrait it wraps into two rows of
/// equal keys, so every key shows. Only where two rows don't fit either (a large text size in a
/// narrow window) does it scroll, with its scroll bar showing.
public struct NWTerminalKeyRow: View {
    let keys: [NWTerminalKeycap]
    let press: (String) -> Void

    public init(_ keys: [NWTerminalKeycap], press: @escaping (String) -> Void) {
        self.keys = keys
        self.press = press
    }

    public var body: some View {
        let half = (keys.count + 1) / 2
        ViewThatFits(in: .horizontal) {
            HStack(spacing: NW.Space.s) { keycaps(keys, fill: false) }
                .padding(.horizontal, NW.Space.l)
            VStack(spacing: 0) {
                HStack(spacing: NW.Space.s) { keycaps(Array(keys.prefix(half)), fill: true) }
                HStack(spacing: NW.Space.s) { keycaps(Array(keys.dropFirst(half)), fill: true) }
            }
            .padding(.horizontal, NW.Space.l)
            ScrollView(.horizontal) {
                HStack(spacing: NW.Space.s) { keycaps(keys, fill: false) }
                    .padding(.horizontal, NW.Space.l)
            }
            .scrollIndicators(.visible)
            .scrollIndicatorsFlash(onAppear: true)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .padding(.vertical, NW.Space.m)
        .frame(maxWidth: .infinity)
        .background(Color.nw.bgWindow)
        .overlay(alignment: .top) { NWHairline() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Terminal keys")
    }

    /// `fill`: the keys share their row's width equally (the wrapped rows).
    private func keycaps(_ keys: [NWTerminalKeycap], fill: Bool) -> some View {
        ForEach(keys) { key in
            Button { press(key.id) } label: {
                Text(key.label)
                    .font(.nw(.code))
                    .foregroundStyle(key.isLatched ? Color.nw.lanternText : Color.nw.textPrimary)
                    .lineLimit(1)
                    // A key never truncates: where its row can't hold it, the row scrolls instead.
                    .fixedSize()
                    .padding(.horizontal, NW.Space.m)
                    .frame(minWidth: NWTerminalMetrics.keyMinWidth, maxWidth: fill ? .infinity : nil,
                           minHeight: NWTerminalMetrics.keyHeight)
                    .background(key.isLatched ? Color.nw.lanternTint : Color.nw.bgRaised,
                                in: RoundedRectangle(cornerRadius: NW.Radius.s))
                    .nwBorder(key.isLatched ? Color.nw.lantern : Color.nw.lineSubtle, radius: NW.Radius.s)
                    .contentShape(Rectangle())
            }
            .buttonStyle(NWKeycapPressStyle())
            .nwTouchTarget(height: NWTerminalMetrics.keyHeight)
            .accessibilityLabel(key.spokenLabel)
            .accessibilityAddTraits(key.isLatched ? .isSelected : [])
        }
    }
}

/// A pressed keycap dims, as a key does.
private struct NWKeycapPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// A terminal's quiet state line in place of its screen ("attaching…", "session exited (1)"):
/// mono, tertiary, at the top left, as DESIGN.md › Terminal panes has it.
public struct NWTerminalNotice: View {
    let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text)
            .font(.nw(.micro, weight: .regular))
            .foregroundStyle(Color.nw.textTertiary)
            .padding(NWTerminalMetrics.contentPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The thread folded to one line while the panel is maximized (TerminalStates › TerminalPanel ·
/// maximized): its title, its state, and Show the thread, which restores the panel.
public struct NWTerminalFoldedThread: View {
    let title: String
    let state: AgentState
    let restore: () -> Void
    let restoreShortcut: String?

    /// `restoreShortcut` is the chord that restores too, for the button's tooltip.
    public init(title: String, state: AgentState, restoreShortcut: String? = nil, restore: @escaping () -> Void) {
        self.title = title
        self.state = state
        self.restoreShortcut = restoreShortcut
        self.restore = restore
    }

    public var body: some View {
        HStack(spacing: NWTerminalMetrics.foldedThreadGap) {
            Text(title)
                .font(.nwSans(12.5, .semibold))
                .foregroundStyle(Color.nw.textPrimary)
                .lineLimit(1)
            NWStatusPill(state)
            Spacer(minLength: 0)
            Button(action: restore) { Image(systemName: "chevron.down") }
                .buttonStyle(.nwIcon(size: NWTerminalMetrics.buttonSize))
                .nwHelp("Show the thread", shortcut: restoreShortcut)
                .accessibilityLabel("Show the thread")
        }
        .padding(.leading, NWTerminalMetrics.foldedThreadLeading)
        .padding(.trailing, NWTerminalMetrics.foldedThreadTrailing)
        .frame(height: NWTerminalMetrics.foldedThreadHeight)
        .frame(maxWidth: .infinity)
        .background(Color.nw.bgWindow)
        .overlay(alignment: .bottom) { NWHairline() }
        .accessibilityElement(children: .contain)
    }
}

/// A pane's header in a tab split into several panes (TerminalPane): the terminal glyph, what
/// the pane runs in mono, and its host at the trailing end. The focused pane's reads in
/// `textPrimary`; the others' are quiet. A tab of one pane has none: the tab names it.
public struct NWTerminalPaneHeader: View {
    let title: String
    let host: String?
    let isFocused: Bool

    public init(title: String, host: String? = nil, isFocused: Bool) {
        self.title = title
        self.host = host
        self.isFocused = isFocused
    }

    public var body: some View {
        let nw = Color.nw
        let color = isFocused ? nw.textPrimary : nw.textTertiary
        HStack(spacing: NW.Space.s) {
            Image(systemName: "terminal")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(color)
            Text(title)
                .font(.nwMono(11))
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: NW.Space.s)
            if let host {
                HStack(spacing: 3) {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(nw.textTertiary)
                    Text(host)
                        .font(.nw(.micro, weight: .regular))
                        .foregroundStyle(color)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, NWTerminalMetrics.paneHeaderPadding)
        .frame(height: NWTerminalMetrics.paneHeaderHeight)
        .frame(maxWidth: .infinity)
        .background(Color.nw.bgWindow)
        .overlay(alignment: .bottom) { NWHairline() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(host.map { "\(title), on \($0)" } ?? title)
    }
}

/// Beside a selection in a terminal (TerminalPane): Add to message puts the selection in the
/// thread's composer, and Copy copies it.
public struct NWTerminalSelectionBar: View {
    let add: () -> Void
    let copy: () -> Void

    public init(add: @escaping () -> Void, copy: @escaping () -> Void) {
        self.add = add
        self.copy = copy
    }

    public var body: some View {
        HStack(spacing: NWTerminalMetrics.selectionBarPadding) {
            Button(action: add) { Label("Add to message", systemImage: "plus") }
                .buttonStyle(.nw(.primary, size: .s))
                .help("Add the selection to your message")
            Button(action: copy) { Label("Copy", systemImage: "doc.on.doc") }
                .buttonStyle(.nw(.ghost, size: .s))
                .help("Copy the selection")
        }
        .padding(NWTerminalMetrics.selectionBarPadding)
        .fixedSize()
        .nwPopover(radius: NWTerminalMetrics.selectionBarRadius)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Selection")
    }
}

/// The new terminal menu (NewTerminalMenu: + or a right-click on a tab): 290pt, 6pt in, radius
/// 10, the popover's fill, line and shadow. Its rows are the Changes menus' rows
/// (`NWChangesMenuRow`), two-line ones at least 36pt, with their chords as keycaps.
public struct NWTerminalMenu<Content: View>: View {
    let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(NW.Space.s)
            .frame(width: NWTerminalMetrics.menuWidth)
            .nwPopover(radius: NWTerminalMetrics.menuRadius)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
    }
}

#if os(macOS)
import AppKit

extension View {
    /// A right-click (or a Control-click) on the view calls `action`; every other click passes
    /// through to the view as before.
    public func nwSecondaryClick(enabled: Bool = true, _ action: @escaping () -> Void) -> some View {
        overlay { if enabled { NWSecondaryClickCatcher(action: action) } }
    }
}

private struct NWSecondaryClickCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> Catcher {
        let view = Catcher()
        view.action = action
        return view
    }

    func updateNSView(_ view: Catcher, context: Context) { view.action = action }

    final class Catcher: NSView {
        var action: (() -> Void)?

        /// Only a secondary click lands here; everything else falls to the views under it.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            let secondary = event.type == .rightMouseDown
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            return secondary ? super.hitTest(point) : nil
        }

        override func rightMouseDown(with event: NSEvent) { action?() }
        override func mouseDown(with event: NSEvent) { action?() }
    }
}
#endif
