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
    @ViewBuilder let trailing: () -> Trailing

    public init(_ tabs: [NWTerminalTab], selection: String?, select: @escaping (String) -> Void,
                close: ((String) -> Void)? = nil, newTab: (() -> Void)? = nil, newTabHelp: String = "New terminal",
                @ViewBuilder trailing: @escaping () -> Trailing) {
        self.tabs = tabs
        self.selection = selection
        self.select = select
        self.close = close
        self.newTab = newTab
        self.newTabHelp = newTabHelp
        self.trailing = trailing
    }

    public var body: some View {
        HStack(spacing: NW.Space.xxs) {
            ScrollView(.horizontal) {
                HStack(spacing: NW.Space.xxs) {
                    ForEach(tabs) { tab in
                        NWTerminalTabView(tab: tab, isSelected: tab.id == selection, select: { select(tab.id) },
                                          close: close.map { close in { close(tab.id) } })
                    }
                    if let newTab {
                        Button(action: newTab) { Image(systemName: "plus") }
                            .buttonStyle(.nwIcon(size: NWTerminalMetrics.buttonSize))
                            .nwHelp(newTabHelp)
                            .accessibilityLabel(newTabHelp)
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
        .frame(height: NWTerminalMetrics.tabBarHeight)
        .frame(maxWidth: .infinity)
        .background(Color.nw.bgWindow)
        .overlay(alignment: .top) { NWHairline(color: .nw.lineStrong) }
        .overlay(alignment: .bottom) { NWHairline() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Terminal tabs")
    }
}

/// A tab: the terminal glyph (a spinner while a command runs), the title in mono, the host of a
/// remote tab, a running-blue dot for output you have not seen, and the selected tab's close.
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
                    if let host = tab.host {
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
                .frame(height: NWTerminalMetrics.tabHeight)
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
                        .frame(width: NWTerminalMetrics.tabHeight * 0.75, height: NWTerminalMetrics.tabHeight)
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

/// The key row over the software keyboard (iPadTerminal board): Esc, Tab, Ctrl, ⌥, the arrows
/// and the symbols a shell needs, as 34pt keycaps with 44pt hit areas. It scrolls when the row
/// is wider than the screen (a large text size, a narrow window).
public struct NWTerminalKeyRow: View {
    let keys: [NWTerminalKeycap]
    let press: (String) -> Void

    public init(_ keys: [NWTerminalKeycap], press: @escaping (String) -> Void) {
        self.keys = keys
        self.press = press
    }

    public var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: NW.Space.s) {
                ForEach(keys) { key in
                    Button { press(key.id) } label: {
                        Text(key.label)
                            .font(.nw(.code))
                            .foregroundStyle(key.isLatched ? Color.nw.lanternText : Color.nw.textPrimary)
                            .lineLimit(1)
                            .padding(.horizontal, NW.Space.m)
                            .frame(minWidth: NWTerminalMetrics.keyMinWidth, minHeight: NWTerminalMetrics.keyHeight)
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
            .padding(.horizontal, NW.Space.l)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .padding(.vertical, NW.Space.m)
        .frame(maxWidth: .infinity)
        .background(Color.nw.bgWindow)
        .overlay(alignment: .top) { NWHairline() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Terminal keys")
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
