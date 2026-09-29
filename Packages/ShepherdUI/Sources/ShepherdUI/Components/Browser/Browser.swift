import SwiftUI

// The side pane's Browser (PaneBrowser, PaneStates › Browser): its toolbar and address field,
// the page when nothing is open, the viewport menu, a picked element's popover, the composer's
// element chip, and the console drawer. The page itself is a web view the app hosts.

public enum NWBrowserMetrics {
    /// The toolbar under the tabs.
    public static let toolbarHeight: CGFloat = 44
    /// The address capsule.
    public static let addressHeight: CGFloat = 30
    public static let addressGlyph: CGFloat = 12
    public static let addressLeading: CGFloat = 12
    public static let addressTrailing: CGFloat = 5
    /// The host chip inside it.
    public static let hostChipHeight: CGFloat = 20
    public static let hostChipPadding: CGFloat = 7
    public static let hostChipGlyph: CGFloat = 10
    /// Nothing open.
    public static let emptyCircle: CGFloat = 44
    public static let emptyGlyph: CGFloat = 20
    public static let emptyTextWidth: CGFloat = 330
    public static let emptyWidth: CGFloat = 400
    /// The viewport menu.
    public static let viewportMenuWidth: CGFloat = 220
    /// A picked element's popover.
    public static let popoverWidth: CGFloat = 188
    /// A chosen width's frame: its top corners.
    public static let frameRadius: CGFloat = 14
    /// The element chip.
    public static let chipHeight: CGFloat = 26
    public static let chipGlyph: CGFloat = 12
    public static let chipRemove: CGFloat = 9
    public static let compactChipHeight: CGFloat = 22
    /// The console drawer.
    public static let consoleBarHeight: CGFloat = 32
    public static let consoleRowHeight: CGFloat = 22
    public static let consoleListHeight: CGFloat = 136
    public static let consoleGap: CGFloat = 14
    public static let consoleToggle: CGFloat = 24
}

/// The element glyph: a dashed square with a pointer.
public let nwElementGlyph = "cursorarrow.and.square.on.square.dashed"

// MARK: Toolbar

/// What the toolbar's buttons can do now.
public struct NWBrowserToolbarState: Equatable, Sendable {
    public var canGoBack: Bool
    public var canGoForward: Bool
    public var canReload: Bool
    public var isLoading: Bool
    public var selecting: Bool
    public var viewportMenuOpen: Bool
    public var canOpenExternally: Bool

    public init(canGoBack: Bool = false, canGoForward: Bool = false, canReload: Bool = false, isLoading: Bool = false,
                selecting: Bool = false, viewportMenuOpen: Bool = false, canOpenExternally: Bool = false) {
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.canReload = canReload
        self.isLoading = isLoading
        self.selecting = selecting
        self.viewportMenuOpen = viewportMenuOpen
        self.canOpenExternally = canOpenExternally
    }
}

/// The Browser's toolbar (PaneBrowser): 44pt, 8pt sides, a hairline beneath. Back, Forward and
/// Reload; the address field; then Select an element (lantern while on), Viewport size (its menu's
/// button is `bgSelected` while the menu is open) and Open in your browser. A button that can't
/// act is at 40%.
public struct NWBrowserToolbar<Address: View>: View {
    public struct Actions {
        public var back: () -> Void
        public var forward: () -> Void
        public var reload: () -> Void
        public var select: () -> Void
        public var viewport: () -> Void
        public var openExternally: () -> Void

        public init(back: @escaping () -> Void = {}, forward: @escaping () -> Void = {}, reload: @escaping () -> Void = {},
                    select: @escaping () -> Void = {}, viewport: @escaping () -> Void = {}, openExternally: @escaping () -> Void = {}) {
            self.back = back
            self.forward = forward
            self.reload = reload
            self.select = select
            self.viewport = viewport
            self.openExternally = openExternally
        }
    }

    let state: NWBrowserToolbarState
    let selectShortcut: String?
    let actions: Actions
    let address: Address

    public init(state: NWBrowserToolbarState, selectShortcut: String? = nil, actions: Actions, @ViewBuilder address: () -> Address) {
        self.state = state
        self.selectShortcut = selectShortcut
        self.actions = actions
        self.address = address()
    }

    public var body: some View {
        HStack(spacing: NW.Space.xxs) {
            icon("chevron.left", "Back", enabled: state.canGoBack, action: actions.back)
            icon("chevron.right", "Forward", enabled: state.canGoForward, action: actions.forward)
            icon(state.isLoading ? "xmark" : "arrow.clockwise", state.isLoading ? "Stop loading" : "Reload",
                 enabled: state.canReload, action: actions.reload)
            address
                .padding(.horizontal, NW.Space.s)
            Button(action: actions.select) { Image(systemName: nwElementGlyph) }
                .buttonStyle(.nwIcon(isOn: state.selecting))
                .disabled(!state.canReload)
                .opacity(state.canReload ? 1 : NWBrowserToolbar.disabledOpacity)
                .nwHelp(state.selecting ? "Stop selecting" : "Select an element", shortcut: selectShortcut)
                .accessibilityLabel("Select an element")
                .accessibilityAddTraits(state.selecting ? .isSelected : [])
            Button(action: actions.viewport) { Image(systemName: "iphone") }
                .buttonStyle(.nwIcon)
                .background(state.viewportMenuOpen ? Color.nw.bgSelected : .clear, in: Circle())
                .nwHelp("Viewport size")
                .accessibilityLabel("Viewport size")
            icon("arrow.up.forward.square", "Open in your browser", enabled: state.canOpenExternally, action: actions.openExternally)
        }
        .padding(.horizontal, NW.Space.m)
        .frame(height: NWBrowserMetrics.toolbarHeight)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottom) { NWHairline() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Browser toolbar")
    }

    private func icon(_ symbol: String, _ label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.nwIcon)
            .disabled(!enabled)
            .opacity(enabled ? 1 : NWBrowserToolbar.disabledOpacity)
            .nwHelp(label)
            .accessibilityLabel(label)
    }
}

extension NWBrowserToolbar {
    /// A button that can't act.
    public static var disabledOpacity: Double { 0.4 }
}

/// The address capsule (PaneBrowser): 30pt on `bgSunken` with a `lineSubtle` line, a 12pt
/// `textTertiary` glyph, the URL in Geist Mono 12 (the host `textPrimary`, the path
/// `textSecondary`), truncating, and the host chip. Empty, "Search or enter a URL". While it has
/// the keyboard it edits the whole URL.
public struct NWBrowserAddressField: View {
    let host: String?
    let path: String?
    let hostChip: String
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    let submit: () -> Void
    let cancel: () -> Void

    public init(host: String?, path: String?, hostChip: String, text: Binding<String>, isFocused: FocusState<Bool>.Binding,
                submit: @escaping () -> Void, cancel: @escaping () -> Void = {}) {
        self.host = host
        self.path = path
        self.hostChip = hostChip
        _text = text
        self.isFocused = isFocused
        self.submit = submit
        self.cancel = cancel
    }

    public static let placeholder = "Search or enter a URL"

    public var body: some View {
        let nw = Color.nw
        HStack(spacing: NW.Space.m) {
            Image(systemName: "globe")
                .font(.system(size: NWBrowserMetrics.addressGlyph))
                .foregroundStyle(nw.textTertiary)
                .accessibilityHidden(true)
            ZStack(alignment: .leading) {
                TextField(text: $text, prompt: Text(Self.placeholder).foregroundStyle(nw.textTertiary)) { Text("Address") }
                    .textFieldStyle(.plain)
                    .font(.nwMono(12))
                    .foregroundStyle(nw.textPrimary)
                    .focused(isFocused)
                    .onSubmit(submit)
                    .onKeyPress(.escape) {
                        cancel()
                        return .handled
                    }
                    .opacity(isFocused.wrappedValue || host == nil ? 1 : 0)
                if !isFocused.wrappedValue, let host {
                    (Text(host).foregroundStyle(nw.textPrimary) + Text(path ?? "").foregroundStyle(nw.textSecondary))
                        .font(.nwMono(12))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { isFocused.wrappedValue = true }
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity)
            NWBrowserHostChip(hostChip)
        }
        .padding(.leading, NWBrowserMetrics.addressLeading)
        .padding(.trailing, NWBrowserMetrics.addressTrailing)
        .frame(height: NWBrowserMetrics.addressHeight)
        .frame(maxWidth: .infinity)
        .background(nw.bgSunken, in: Capsule())
        .nwBorder(nw.lineSubtle, in: Capsule())
    }
}

/// The host chip in the address field: a 20pt capsule on `bgRaised` with a 10pt server glyph and
/// the host in Geist 11 `textSecondary` ("This Mac", "build-01").
public struct NWBrowserHostChip: View {
    let host: String

    public init(_ host: String) { self.host = host }

    public var body: some View {
        let nw = Color.nw
        HStack(spacing: 5) {
            Image(systemName: "display").font(.system(size: NWBrowserMetrics.hostChipGlyph))
            Text(host).font(.nwSans(11)).lineLimit(1)
        }
        .foregroundStyle(nw.textSecondary)
        .padding(.horizontal, NWBrowserMetrics.hostChipPadding)
        .frame(height: NWBrowserMetrics.hostChipHeight)
        .background(nw.bgRaised, in: Capsule())
        .nwBorder(nw.lineSubtle, in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("On \(host)")
    }
}

// MARK: Nothing open

/// A dev server found in the repository, as the empty page offers it.
public struct NWDevServerItem: Identifiable, Equatable, Sendable {
    public let id: String
    /// "pnpm dev".
    public let command: String
    /// "from package.json · acme-web".
    public let detail: String
    /// "Start", or "Start on build-01" for a remote host.
    public let startTitle: String

    public init(id: String, command: String, detail: String, startTitle: String = "Start") {
        self.id = id
        self.command = command
        self.detail = detail
        self.startTitle = startTitle
    }
}

/// Nothing open (PaneStates › BrowserPane · nothing open): a 44pt circle with the globe, "No page
/// open", a line under it, a card per dev server found in the repository with Start, and "Open a
/// URL" with its keycaps.
public struct NWBrowserEmpty: View {
    let message: String
    let servers: [NWDevServerItem]
    let openShortcut: String?
    let start: (NWDevServerItem) -> Void
    let openURL: () -> Void

    public init(message: String, servers: [NWDevServerItem], openShortcut: String? = nil,
                start: @escaping (NWDevServerItem) -> Void, openURL: @escaping () -> Void) {
        self.message = message
        self.servers = servers
        self.openShortcut = openShortcut
        self.start = start
        self.openURL = openURL
    }

    public var body: some View {
        let nw = Color.nw
        VStack(spacing: 14) {
            Image(systemName: "globe")
                .font(.system(size: NWBrowserMetrics.emptyGlyph))
                .foregroundStyle(nw.textSecondary)
                .frame(width: NWBrowserMetrics.emptyCircle, height: NWBrowserMetrics.emptyCircle)
                .background(nw.bgSelected, in: Circle())
                .accessibilityHidden(true)
            Text("No page open")
                .font(.nwSans(14, .semibold))
                .foregroundStyle(nw.textPrimary)
            Text(message)
                .font(.nw(.ui, weight: .regular))
                .foregroundStyle(nw.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: NWBrowserMetrics.emptyTextWidth)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: NW.Space.m) {
                ForEach(servers) { server in
                    NWDevServerCard(server) { start(server) }
                }
                Button(action: openURL) {
                    HStack(spacing: NW.Space.m) {
                        Image(systemName: "globe").font(.system(size: 12)).foregroundStyle(nw.textSecondary)
                        Text("Open a URL").font(.nw(.ui, weight: .regular)).foregroundStyle(nw.textPrimary)
                        Spacer(minLength: NW.Space.m)
                        if let openShortcut { NWKeycap(openShortcut) }
                    }
                    .padding(.horizontal, NW.Space.l)
                    .padding(.vertical, 10)
                    .background(nw.bgRaised, in: RoundedRectangle(cornerRadius: NW.Radius.m))
                    .nwBorder(nw.lineSubtle, radius: NW.Radius.m)
                    .contentShape(RoundedRectangle(cornerRadius: NW.Radius.m))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open a URL")
            }
            .padding(.top, NW.Space.m)
            .frame(maxWidth: NWBrowserMetrics.emptyWidth)
        }
        .padding(NW.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One dev server (PaneStates): the command in Geist Mono 12 over where it came from in Geist 11
/// `textTertiary`, and Start (secondary `s`).
public struct NWDevServerCard: View {
    let server: NWDevServerItem
    let start: () -> Void

    public init(_ server: NWDevServerItem, start: @escaping () -> Void) {
        self.server = server
        self.start = start
    }

    public var body: some View {
        let nw = Color.nw
        HStack(spacing: NW.Space.m) {
            Image(systemName: "terminal").font(.system(size: 12)).foregroundStyle(nw.textSecondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(server.command).font(.nwMono(12)).foregroundStyle(nw.textPrimary).lineLimit(1)
                Text(server.detail).font(.nwSans(11)).foregroundStyle(nw.textTertiary).lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: start) {
                Label(server.startTitle, systemImage: "play.fill")
            }
            .buttonStyle(.nw(.secondary, size: .s))
            .accessibilityLabel("\(server.startTitle) \(server.command)")
        }
        .padding(.horizontal, NW.Space.l)
        .padding(.vertical, 10)
        .background(nw.bgRaised, in: RoundedRectangle(cornerRadius: NW.Radius.m))
        .nwBorder(nw.lineSubtle, radius: NW.Radius.m)
    }
}

// MARK: Viewport menu

/// One width the viewport menu offers.
public struct NWViewportOption: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    /// "393"; nil for Fit the pane.
    public let width: String?

    public init(id: String, title: String, width: String? = nil) {
        self.id = id
        self.title = title
        self.width = width
    }
}

/// The viewport menu (PaneStates › BrowserPane · viewport): a 220pt popover of widths, the chosen
/// one checked, each width trailing in Geist Mono 11 `textTertiary`; a divider; Dark appearance.
public struct NWViewportMenu: View {
    let options: [NWViewportOption]
    let selection: String
    let dark: Bool
    let choose: (NWViewportOption) -> Void
    let toggleDark: () -> Void

    public init(options: [NWViewportOption], selection: String, dark: Bool, choose: @escaping (NWViewportOption) -> Void,
                toggleDark: @escaping () -> Void) {
        self.options = options
        self.selection = selection
        self.dark = dark
        self.choose = choose
        self.toggleDark = toggleDark
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(options) { option in
                Row(title: option.title, trailing: option.width, checked: option.id == selection) { choose(option) }
            }
            NWChangesMenuDivider()
            Row(title: "Dark appearance", trailing: nil, checked: dark, action: toggleDark)
        }
        .padding(NW.Space.s)
        .frame(width: NWBrowserMetrics.viewportMenuWidth)
        .nwPopover()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Viewport size")
    }

    private struct Row: View {
        let title: String
        let trailing: String?
        let checked: Bool
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            let nw = Color.nw
            HStack(spacing: NW.Space.m) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(nw.textPrimary)
                    .opacity(checked ? 1 : 0)
                    .frame(width: NWChangesMenuMetrics.glyphWidth)
                Text(title).font(.nw(.ui, weight: .regular)).foregroundStyle(nw.textPrimary).lineLimit(1)
                Spacer(minLength: NW.Space.m)
                if let trailing { Text(trailing).font(.nwMono(11)).foregroundStyle(nw.textTertiary) }
            }
            .padding(.horizontal, NW.Space.m)
            .frame(height: NWChangesMenuMetrics.rowHeight)
            .background(hovering ? nw.bgHover : .clear, in: RoundedRectangle(cornerRadius: NW.Radius.s))
            .contentShape(RoundedRectangle(cornerRadius: NW.Radius.s))
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(checked ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { action() }
        }
    }
}

// MARK: Picked element

/// A picked element's popover (PaneBrowser): 188pt, padding 8, radius 12, the popover's fill and
/// shadow. The source location only when the page gave one, then Add to message (primary `s`)
/// and Copy selector (ghost `s`).
public struct NWElementPopover: View {
    let source: String?
    let add: () -> Void
    let copy: () -> Void

    public init(source: String?, add: @escaping () -> Void, copy: @escaping () -> Void) {
        self.source = source
        self.add = add
        self.copy = copy
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: NW.Space.s) {
            if let source {
                Text(source)
                    .font(.nwMono(10.5))
                    .foregroundStyle(Color.nw.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .padding(.horizontal, NW.Space.xxs)
            }
            Button(action: add) {
                Label("Add to message", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.nw(.primary, size: .s))
            Button(action: copy) {
                Label("Copy selector", systemImage: "doc.on.doc").frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.nw(.ghost, size: .s))
        }
        .padding(NW.Space.m)
        .frame(width: NWBrowserMetrics.popoverWidth)
        .nwPopover()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Picked element")
    }
}

/// An element picked in the Browser, as a chip (PaneBrowser's composer; DESIGN.md › Composer):
/// 26pt, padding 0×8, radius 6, a `lineStrong` line, the 12pt element glyph, the label in Geist
/// Mono 12, the source in Geist Mono 10.5 `textTertiary` when known, and a 9pt remove × in the
/// composer. `.compact` is the queue's read-only chip: 22pt, an 11pt `textSecondary` glyph, the
/// label in mono 11.
public struct NWElementChip: View {
    let label: String
    let source: String?
    let size: NWAttachmentChip.Size
    let remove: (() -> Void)?

    public init(_ label: String, source: String? = nil, size: NWAttachmentChip.Size = .regular, remove: (() -> Void)? = nil) {
        self.label = label
        self.source = source
        self.size = size
        self.remove = remove
    }

    public var body: some View {
        let nw = Color.nw
        let compact = size == .compact
        HStack(spacing: compact ? NW.Space.xs : NW.Space.s) {
            Image(systemName: nwElementGlyph)
                .font(.system(size: compact ? 11 : NWBrowserMetrics.chipGlyph))
                .foregroundStyle(nw.textSecondary)
                .accessibilityHidden(true)
            Text(label)
                .font(.nwMono(compact ? 11 : 12))
                .foregroundStyle(nw.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let source, !compact {
                Text(source).font(.nwMono(10.5)).foregroundStyle(nw.textTertiary).lineLimit(1).truncationMode(.head)
            }
            if let remove {
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.system(size: NWBrowserMetrics.chipRemove - 1, weight: .semibold))
                        .foregroundStyle(nw.textTertiary)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(label)")
            }
        }
        .padding(.horizontal, compact ? NW.Space.s : NW.Space.m)
        .frame(height: compact ? NWBrowserMetrics.compactChipHeight : NWBrowserMetrics.chipHeight)
        .nwBorder(nw.lineStrong, radius: compact ? NW.Radius.xs : NW.Radius.s)
        .fixedSize(horizontal: compact, vertical: false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel([label, source].compactMap { $0 }.joined(separator: ", "))
    }
}

// MARK: Console

/// A console line's kind.
public enum NWConsoleLevel: String, Equatable, Sendable {
    case log, warning, error
}

/// One console line, as its row draws it.
public struct NWConsoleLine: Identifiable, Equatable, Sendable {
    public let id: Int
    /// "14:02:11".
    public let time: String
    public let text: String
    public let level: NWConsoleLevel

    public init(id: Int, time: String, text: String, level: NWConsoleLevel = .log) {
        self.id = id
        self.time = time
        self.text = text
        self.level = level
    }
}

/// The console drawer's bar (PaneBrowser): 32pt on `bgBase` under a `lineStrong` line.
/// "Console", "Network" with its count, the warnings (and errors) in their colors, and Hide
/// console (Show console while the drawer is closed).
public struct NWConsoleBar: View {
    let network: Int
    let warnings: Int
    let errors: Int
    let open: Bool
    let toggle: () -> Void

    public init(network: Int, warnings: Int, errors: Int = 0, open: Bool, toggle: @escaping () -> Void) {
        self.network = network
        self.warnings = warnings
        self.errors = errors
        self.open = open
        self.toggle = toggle
    }

    public var body: some View {
        let nw = Color.nw
        HStack(spacing: NWBrowserMetrics.consoleGap) {
            Text("Console").font(.nwSans(12, .semibold)).foregroundStyle(nw.textPrimary)
            HStack(spacing: NW.Space.xs) {
                Text("Network").font(.nwSans(12)).foregroundStyle(nw.textSecondary)
                Text("\(network)").font(.nwMono(10.5)).foregroundStyle(nw.textTertiary).nwContentTransition(.numeric())
            }
            if errors > 0 { count(errors, "error", color: nw.failed, symbol: "xmark.octagon") }
            if warnings > 0 { count(warnings, "warning", color: nw.lanternText, symbol: "exclamationmark.triangle") }
            Spacer(minLength: 0)
            Button(action: toggle) { Image(systemName: open ? "chevron.down" : "chevron.up") }
                .buttonStyle(.nwIcon(size: NWBrowserMetrics.consoleToggle))
                .nwHelp(open ? "Hide console" : "Show console")
                .accessibilityLabel(open ? "Hide console" : "Show console")
        }
        .padding(.leading, 14)
        .padding(.trailing, NW.Space.m)
        .frame(height: NWBrowserMetrics.consoleBarHeight)
        .background(nw.bgBase)
        .overlay(alignment: .top) { NWHairline(color: nw.lineStrong) }
        .accessibilityElement(children: .contain)
    }

    private func count(_ value: Int, _ noun: String, color: Color, symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 12))
            Text("\(value) \(noun)\(value == 1 ? "" : "s")").font(.nwSans(11.5))
        }
        .foregroundStyle(color)
    }
}

/// A console line (PaneBrowser): at least 22pt, 14pt sides, Geist Mono 11: the time in
/// `textTertiary`, the message in `textSecondary`, truncating. A warning sits on `lanternTint`
/// in `lanternText`; an error on `failedTint` in `failed`.
public struct NWConsoleRow: View, Equatable {
    let line: NWConsoleLine

    public init(_ line: NWConsoleLine) { self.line = line }

    public var body: some View {
        let _ = NWRenderProbe.tick("browser.consoleRow")
        let nw = Color.nw
        HStack(spacing: 10) {
            Text(line.time).foregroundStyle(nw.textTertiary)
            Text(line.text)
                .foregroundStyle(line.level == .warning ? nw.lanternText : line.level == .error ? nw.failed : nw.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .font(.nwMono(11))
        .padding(.horizontal, 14)
        .frame(minHeight: NWBrowserMetrics.consoleRowHeight)
        .background(line.level == .warning ? nw.lanternTint : line.level == .error ? nw.failedTint : .clear)
        .help(line.text)
    }
}
