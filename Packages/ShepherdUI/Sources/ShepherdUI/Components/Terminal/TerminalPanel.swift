import SwiftUI

/// The terminal panel's measures (TerminalSplit and TerminalStates boards on the Mac, iPadTerminal
/// on iPad): a strip of tabs over the terminal, under the thread and its composer.
public enum SHTerminalMetrics {
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
    public static let buttonSize: CGFloat = SH.Height.controlS
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
    /// The bar that sends a selection to the agent (TerminalPane): 4pt in, 4pt apart, and this
    /// far from the selection and the terminal's edge.
    public static let selectionBarPadding: CGFloat = 4
    public static let selectionBarRadius: CGFloat = 9
    public static let selectionBarInset: CGFloat = 8
    /// The new terminal menu (NewTerminalMenu).
    public static let menuWidth: CGFloat = 290
    public static let menuTallRowHeight: CGFloat = 36
    public static let menuRadius: CGFloat = 10
}

/// One tab in the panel (TerminalTab · states board).
public struct SHTerminalTab: Equatable, Identifiable, Sendable {
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

    public init(id: String, title: String, host: String? = nil, activity: Activity = .idle) {
        self.id = id
        self.title = title
        self.host = host
        self.activity = activity
    }
}

/// The panel's tab strip: the tabs, + for a new one, then the panel's own controls (maximize,
/// hide) at the trailing end. The selected tab carries its close button.
public struct SHTerminalTabBar<Trailing: View>: View {
    let tabs: [SHTerminalTab]
    let selection: String?
    let select: (String) -> Void
    let close: ((String) -> Void)?
    let newTab: (() -> Void)?
    let newTabHelp: String
    let menu: ((_ tab: String?, _ anchor: CGFloat) -> Void)?
    @ViewBuilder let trailing: () -> Trailing
    /// Where + and each tab sit along the strip, for the menu to hang from.
    @State private var anchors: [String: CGRect] = [:]
    /// The part of the strip the tabs scroll in: a tab scrolled out of it takes no right-click.
    @State private var visibleTabs: CGRect = .null

    /// `menu`, where given, opens the new terminal menu (NewTerminalMenu) from + (`tab` nil) and
    /// from a right-click on a tab, at `anchor` along the strip; + then opens the menu rather
    /// than a tab.
    public init(_ tabs: [SHTerminalTab], selection: String?, select: @escaping (String) -> Void,
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

    private static var space: String { "shTerminalTabBar" }
    private static var plusAnchor: String { "+" }

    public var body: some View {
        HStack(spacing: SH.Space.xxs) {
            ScrollView(.horizontal) {
                HStack(spacing: SH.Space.xxs) {
                    ForEach(tabs) { tab in
                        SHTerminalTabView(tab: tab, isSelected: tab.id == selection, select: { select(tab.id) },
                                          close: close.map { close in { close(tab.id) } })
                            .modifier(AnchorReader(id: tab.id, anchors: $anchors))
                    }
                    if let newTab {
                        Button {
                            if let menu { menu(nil, anchors[Self.plusAnchor]?.minX ?? 0) } else { newTab() }
                        } label: { Image(systemName: "plus") }
                            .buttonStyle(.shIcon(size: SHTerminalMetrics.buttonSize))
                            .shHelp(newTabHelp)
                            .accessibilityLabel(newTabHelp)
                            .modifier(AnchorReader(id: Self.plusAnchor, anchors: $anchors))
                    }
                }
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { visibleTabs = $0 }
            Spacer(minLength: SH.Space.m)
            HStack(spacing: SH.Space.xxs) { trailing() }
                .buttonStyle(.shIcon(size: SHTerminalMetrics.buttonSize))
        }
        .padding(.horizontal, SH.Space.m)
        .frame(minHeight: SHTerminalMetrics.tabBarHeight)
        .frame(maxWidth: .infinity)
        // A strip of chrome over the terminal: it grows with Dynamic Type, but not past a size
        // that leaves room for the terminal under it.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .background(Color.sh.bgWindow)
        .overlay(alignment: .top) { SHHairline(color: .sh.lineStrong) }
        .overlay(alignment: .bottom) { SHHairline() }
        #if os(macOS)
        // A right-click (or ⌃-click) on a tab opens the menu from it.
        .background {
            if let menu {
                SHSecondaryClickRegions(regions: tabs.compactMap { tab in
                    anchors[tab.id].map { (tab.id, $0.intersection(visibleTabs)) }.flatMap { $0.1.isNull ? nil : $0 }
                }) { id in
                    menu(id, anchors[id]?.minX ?? 0)
                }
            }
        }
        #endif
        .coordinateSpace(.named(Self.space))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Terminal tabs")
    }

    /// Notes where a tab or + starts along the strip, scrolled or not.
    private struct AnchorReader: ViewModifier {
        let id: String
        @Binding var anchors: [String: CGRect]

        func body(content: Content) -> some View {
            content.onGeometryChange(for: CGRect.self) { $0.frame(in: .named(SHTerminalTabBar.space)) } action: {
                anchors[id] = $0
            }
        }
    }
}

/// A tab: the terminal glyph (a spinner while a command runs), the title in mono, the host of a
/// selected remote tab, a running-blue dot for output you have not seen, and the selected tab's close.
public struct SHTerminalTabView: View {
    let tab: SHTerminalTab
    let isSelected: Bool
    let select: () -> Void
    let close: (() -> Void)?
    @State private var hovering = false

    public init(tab: SHTerminalTab, isSelected: Bool, select: @escaping () -> Void, close: (() -> Void)? = nil) {
        self.tab = tab
        self.isSelected = isSelected
        self.select = select
        self.close = close
    }

    public var body: some View {
        let sh = Color.sh
        HStack(spacing: 0) {
            Button(action: select) {
                HStack(spacing: SH.Space.s) {
                    glyph
                    Text(tab.title)
                        .font(.sh(.mono))
                        .foregroundStyle(isSelected ? sh.textPrimary : sh.textSecondary)
                        .lineLimit(1)
                    // The selected tab names its host (TerminalTab · states); the rest share it.
                    if isSelected, let host = tab.host {
                        Label(host, systemImage: "desktopcomputer")
                            .labelStyle(SHTerminalHostLabelStyle())
                            .font(.sh(.micro, weight: .regular))
                            .foregroundStyle(sh.textTertiary)
                            .lineLimit(1)
                    }
                    if tab.activity == .unseen {
                        Circle().fill(sh.running).frame(width: 6, height: 6)
                    }
                }
                .padding(.leading, SH.Space.m)
                .padding(.trailing, isSelected && close != nil ? SH.Space.xs : SH.Space.m)
                .frame(minHeight: SHTerminalMetrics.tabHeight)
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
                        .foregroundStyle(sh.textTertiary)
                        .frame(width: SHTerminalMetrics.tabHeight * 0.75)
                        .frame(minHeight: SHTerminalMetrics.tabHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .shTouchTarget(height: SHTerminalMetrics.tabHeight, width: SHTerminalMetrics.tabHeight * 0.75)
                .shHelp("Close terminal")
                .accessibilityLabel("Close \(tab.title)")
            }
        }
        .background(isSelected ? sh.bgSelected : hovering ? sh.bgHover : .clear,
                    in: RoundedRectangle(cornerRadius: SH.Radius.s))
        .onHover { hovering = $0 }
        .shAnimation(.hover, value: hovering)
        .fixedSize()
    }

    @ViewBuilder private var glyph: some View {
        let sh = Color.sh
        switch tab.activity {
        case .running:
            ProgressView().progressViewStyle(SHSpinnerStyle(size: 11))
        case .exited(let failed):
            Image(systemName: "terminal")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(failed ? sh.failed : sh.textTertiary)
        case .idle, .unseen:
            Image(systemName: "terminal")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isSelected ? sh.textPrimary : sh.textTertiary)
        }
    }

    private var accessibilityLabel: String {
        var parts = [tab.title]
        if let host = tab.host { parts.append("on \(host)") }
        switch tab.activity {
        case .idle: break
        case .running: parts.append("running")
        case .unseen: parts.append("new output")
        case .exited(let failed): parts.append(failed ? "exited with an error" : "exited")
        }
        return parts.joined(separator: ", ")
    }
}

private struct SHTerminalHostLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: SH.Space.xxs) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// One key of the touch key row.
public struct SHTerminalKeycap: Equatable, Identifiable, Sendable {
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
public struct SHTerminalKeyRow: View {
    let keys: [SHTerminalKeycap]
    let press: (String) -> Void

    public init(_ keys: [SHTerminalKeycap], press: @escaping (String) -> Void) {
        self.keys = keys
        self.press = press
    }

    public var body: some View {
        let half = (keys.count + 1) / 2
        ViewThatFits(in: .horizontal) {
            HStack(spacing: SH.Space.s) { keycaps(keys, fill: false) }
                .padding(.horizontal, SH.Space.l)
            VStack(spacing: 0) {
                HStack(spacing: SH.Space.s) { keycaps(Array(keys.prefix(half)), fill: true) }
                HStack(spacing: SH.Space.s) { keycaps(Array(keys.dropFirst(half)), fill: true) }
            }
            .padding(.horizontal, SH.Space.l)
            ScrollView(.horizontal) {
                HStack(spacing: SH.Space.s) { keycaps(keys, fill: false) }
                    .padding(.horizontal, SH.Space.l)
            }
            .scrollIndicators(.visible)
            .scrollIndicatorsFlash(onAppear: true)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .padding(.vertical, SH.Space.m)
        .frame(maxWidth: .infinity)
        .background(Color.sh.bgWindow)
        .overlay(alignment: .top) { SHHairline() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Terminal keys")
    }

    /// `fill`: the keys share their row's width equally (the wrapped rows).
    private func keycaps(_ keys: [SHTerminalKeycap], fill: Bool) -> some View {
        ForEach(keys) { key in
            Button { press(key.id) } label: {
                Text(key.label)
                    .font(.sh(.code))
                    .foregroundStyle(key.isLatched ? Color.sh.lanternText : Color.sh.textPrimary)
                    .lineLimit(1)
                    // A key never truncates: where its row can't hold it, the row scrolls instead.
                    .fixedSize()
                    .padding(.horizontal, SH.Space.m)
                    .frame(minWidth: SHTerminalMetrics.keyMinWidth, maxWidth: fill ? .infinity : nil,
                           minHeight: SHTerminalMetrics.keyHeight)
                    .background(key.isLatched ? Color.sh.lanternTint : Color.sh.bgRaised,
                                in: RoundedRectangle(cornerRadius: SH.Radius.s))
                    .shBorder(key.isLatched ? Color.sh.lantern : Color.sh.lineSubtle, radius: SH.Radius.s)
                    .contentShape(Rectangle())
            }
            .buttonStyle(SHKeycapPressStyle())
            .shTouchTarget(height: SHTerminalMetrics.keyHeight)
            .accessibilityLabel(key.spokenLabel)
            .accessibilityAddTraits(key.isLatched ? .isSelected : [])
        }
    }
}

/// A pressed keycap dims, as a key does.
private struct SHKeycapPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// A terminal's quiet state line in place of its screen ("attaching…", "session exited (1)"):
/// mono, tertiary, at the top left, as docs/design/terminal.md › Terminal panes has it.
public struct SHTerminalNotice: View {
    let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text)
            .font(.sh(.micro, weight: .regular))
            .foregroundStyle(Color.sh.textTertiary)
            .padding(SHTerminalMetrics.contentPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The thread folded to one line while the panel is maximized (TerminalStates › TerminalPanel ·
/// maximized): its title, its state, and Show the thread, which restores the panel.
public struct SHTerminalFoldedThread: View {
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
        HStack(spacing: SHTerminalMetrics.foldedThreadGap) {
            Text(title)
                .font(.shSans(12.5, .semibold))
                .foregroundStyle(Color.sh.textPrimary)
                .lineLimit(1)
            SHStatusPill(state)
            Spacer(minLength: 0)
            Button(action: restore) { Image(systemName: "chevron.down") }
                .buttonStyle(.shIcon(size: SHTerminalMetrics.buttonSize))
                .shHelp("Show the thread", shortcut: restoreShortcut)
                .accessibilityLabel("Show the thread")
        }
        .padding(.leading, SHTerminalMetrics.foldedThreadLeading)
        .padding(.trailing, SHTerminalMetrics.foldedThreadTrailing)
        .frame(height: SHTerminalMetrics.foldedThreadHeight)
        .frame(maxWidth: .infinity)
        .background(Color.sh.bgWindow)
        .overlay(alignment: .bottom) { SHHairline() }
        .accessibilityElement(children: .contain)
    }
}

/// Beside a selection in a terminal (TerminalPane): Add to message puts the selection in the
/// thread's composer, and Copy copies it.
public struct SHTerminalSelectionBar: View {
    let add: () -> Void
    let copy: () -> Void

    public init(add: @escaping () -> Void, copy: @escaping () -> Void) {
        self.add = add
        self.copy = copy
    }

    public var body: some View {
        HStack(spacing: SHTerminalMetrics.selectionBarPadding) {
            Button(action: add) { Label("Add to message", systemImage: "plus") }
                .buttonStyle(.sh(.primary, size: .s))
                .help("Add the selection to your message")
            Button(action: copy) { Label("Copy", systemImage: "doc.on.doc") }
                .buttonStyle(.sh(.ghost, size: .s))
                .help("Copy the selection")
        }
        .padding(SHTerminalMetrics.selectionBarPadding)
        .fixedSize()
        .shPopover(radius: SHTerminalMetrics.selectionBarRadius)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Selection")
    }
}

/// The new terminal menu (NewTerminalMenu: + or a right-click on a tab): 290pt, 6pt in, radius
/// 10, the popover's fill, line and shadow. Its rows are the Changes menus' rows
/// (`SHChangesMenuRow`), two-line ones at least 36pt, with their chords as keycaps.
public struct SHTerminalMenu<Content: View>: View {
    let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(SH.Space.s)
            .frame(width: SHTerminalMetrics.menuWidth)
            .shPopover(radius: SHTerminalMetrics.menuRadius)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
    }
}

#if os(macOS)
import AppKit

/// Secondary clicks (right-click, ⌃-click) on regions of the view it backs, found by an event
/// monitor while the view is on screen: nothing sits over the regions, so every other click
/// reaches them as before. `regions` are in the backed view's space, top-left origin.
struct SHSecondaryClickRegions: NSViewRepresentable {
    let regions: [(String, CGRect)]
    let action: (String) -> Void

    func makeNSView(context: Context) -> Monitor { Monitor() }

    func updateNSView(_ view: Monitor, context: Context) {
        view.regions = regions
        view.action = action
    }

    static func dismantleNSView(_ view: Monitor, coordinator: ()) { view.stop() }

    final class Monitor: NSView {
        var regions: [(String, CGRect)] = []
        var action: ((String) -> Void)?
        private var monitor: Any?

        override var isFlipped: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
                guard let self, let id = self.region(for: event) else { return event }
                self.action?(id)
                return nil
            }
        }

        /// The region a secondary click in this view's window lands in, while it shows.
        func region(for event: NSEvent) -> String? {
            let secondary = event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            guard secondary, event.window === window, !isHiddenOrHasHiddenAncestor else { return nil }
            let point = convert(event.locationInWindow, from: nil)
            return regions.first { $0.1.contains(point) }?.0
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
#endif
