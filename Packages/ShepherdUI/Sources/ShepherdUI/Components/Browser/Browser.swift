import SwiftUI

// The side pane's Browser (PaneBrowser, PaneStates › Browser): its toolbar and address field,
// the page when nothing is open, the viewport menu, a picked element's popover, the composer's
// element chip, and the console drawer. The page itself is a web view the app hosts.

public enum SHBrowserMetrics {
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
    /// A notice's first line, so its glyph sits on it.
    public static let noticeLine: CGFloat = 18
}

/// The element glyph: a dashed square with a pointer.
public let shElementGlyph = "cursorarrow.and.square.on.square.dashed"

// MARK: Toolbar

/// What the toolbar's buttons can do now.
public struct SHBrowserToolbarState: Equatable, Sendable {
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
public struct SHBrowserToolbar<Address: View>: View {
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

    let state: SHBrowserToolbarState
    let selectShortcut: String?
    let actions: Actions
    let address: Address

    public init(state: SHBrowserToolbarState, selectShortcut: String? = nil, actions: Actions, @ViewBuilder address: () -> Address) {
        self.state = state
        self.selectShortcut = selectShortcut
        self.actions = actions
        self.address = address()
    }

    public var body: some View {
        HStack(spacing: SH.Space.xxs) {
            icon("chevron.left", "Back", enabled: state.canGoBack, action: actions.back)
            icon("chevron.right", "Forward", enabled: state.canGoForward, action: actions.forward)
            icon(state.isLoading ? "xmark" : "arrow.clockwise", state.isLoading ? "Stop loading" : "Reload",
                 enabled: state.canReload, action: actions.reload)
            address
                .padding(.horizontal, SH.Space.s)
            Button(action: actions.select) { Image(systemName: shElementGlyph) }
                .buttonStyle(.shIcon(isOn: state.selecting))
                .disabled(!state.canReload)
                .opacity(state.canReload ? 1 : SHBrowserToolbar.disabledOpacity)
                .shHelp(state.selecting ? "Stop selecting" : "Select an element", shortcut: selectShortcut)
                .accessibilityLabel("Select an element")
                .accessibilityAddTraits(state.selecting ? .isSelected : [])
            Button(action: actions.viewport) { Image(systemName: "iphone") }
                .buttonStyle(.shIcon)
                .background(state.viewportMenuOpen ? Color.sh.bgSelected : .clear, in: Circle())
                .shHelp("Viewport size")
                .accessibilityLabel("Viewport size")
            icon("arrow.up.forward.square", "Open in your browser", enabled: state.canOpenExternally, action: actions.openExternally)
        }
        .padding(.horizontal, SH.Space.m)
        .frame(height: SHBrowserMetrics.toolbarHeight)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottom) { SHHairline() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Browser toolbar")
    }

    private func icon(_ symbol: String, _ label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.shIcon)
            .disabled(!enabled)
            .opacity(enabled ? 1 : SHBrowserToolbar.disabledOpacity)
            .shHelp(label)
            .accessibilityLabel(label)
    }
}

extension SHBrowserToolbar {
    /// A button that can't act.
    public static var disabledOpacity: Double { 0.4 }
}

/// The address capsule (PaneBrowser): 30pt on `bgSunken` with a `lineSubtle` line, a 12pt
/// `textTertiary` glyph, the URL in Geist Mono 12 (the host `textPrimary`, the path
/// `textSecondary`), truncating, and the host chip. Empty, "Search or enter a URL". While it has
/// the keyboard it edits the whole URL.
public struct SHBrowserAddressField: View {
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
        let sh = Color.sh
        HStack(spacing: SH.Space.m) {
            Image(systemName: "globe")
                .font(.system(size: SHBrowserMetrics.addressGlyph))
                .foregroundStyle(sh.textTertiary)
                .accessibilityHidden(true)
            ZStack(alignment: .leading) {
                TextField(text: $text, prompt: Text(Self.placeholder).foregroundStyle(sh.textTertiary)) { Text("Address") }
                    .textFieldStyle(.plain)
                    .font(.shMono(12))
                    .foregroundStyle(sh.textPrimary)
                    .focused(isFocused)
                    .onSubmit(submit)
                    .onKeyPress(.escape) {
                        cancel()
                        return .handled
                    }
                    .opacity(isFocused.wrappedValue || host == nil ? 1 : 0)
                if !isFocused.wrappedValue, let host {
                    (Text(host).foregroundStyle(sh.textPrimary) + Text(path ?? "").foregroundStyle(sh.textSecondary))
                        .font(.shMono(12))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { isFocused.wrappedValue = true }
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity)
            SHBrowserHostChip(hostChip)
        }
        .padding(.leading, SHBrowserMetrics.addressLeading)
        .padding(.trailing, SHBrowserMetrics.addressTrailing)
        .frame(height: SHBrowserMetrics.addressHeight)
        .frame(maxWidth: .infinity)
        .background(sh.bgSunken, in: Capsule())
        .shBorder(sh.lineSubtle, in: Capsule())
    }
}

/// The host chip in the address field: a 20pt capsule on `bgRaised` with a 10pt server glyph and
/// the host in Geist 11 `textSecondary` ("This Mac", "build-01").
public struct SHBrowserHostChip: View {
    let host: String

    public init(_ host: String) { self.host = host }

    public var body: some View {
        let sh = Color.sh
        HStack(spacing: 5) {
            Image(systemName: "display").font(.system(size: SHBrowserMetrics.hostChipGlyph))
            Text(host).font(.shSans(11)).lineLimit(1)
        }
        .foregroundStyle(sh.textSecondary)
        .padding(.horizontal, SHBrowserMetrics.hostChipPadding)
        .frame(height: SHBrowserMetrics.hostChipHeight)
        .background(sh.bgRaised, in: Capsule())
        .shBorder(sh.lineSubtle, in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("On \(host)")
    }
}

/// What stops a page, floating under the toolbar (a remote thread's port that can't be forwarded
/// because something else on this Mac uses it): a 12pt `lanternText` glyph, the words in `ui` (up to
/// three lines) and a close button. The card is `bgRaised`, radius 12, a `lantern` line and the
/// popover's shadow, 12pt from the pane's sides, as the agent's card is. No board draws it: the
/// words come from the app.
public struct SHBrowserNotice: View {
    let message: String
    let dismiss: () -> Void

    public init(message: String, dismiss: @escaping () -> Void) {
        self.message = message
        self.dismiss = dismiss
    }

    public var body: some View {
        let sh = Color.sh
        HStack(alignment: .top, spacing: SHBrowserAgentMetrics.cardGap) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: SHBrowserAgentMetrics.cardGlyph))
                .foregroundStyle(sh.lanternText)
                .frame(height: SHBrowserMetrics.noticeLine)
                .accessibilityHidden(true)
            Text(message)
                .font(.sh(.ui, weight: .regular))
                .foregroundStyle(sh.textPrimary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.shIcon(size: SHBrowserMetrics.consoleToggle))
                .shHelp("Dismiss")
                .accessibilityLabel("Dismiss")
        }
        .padding(.leading, SHBrowserAgentMetrics.cardLeading)
        .padding([.vertical, .trailing], SHBrowserAgentMetrics.cardOther)
        .shPopover(radius: SH.Radius.l, line: sh.lantern)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(message)
    }
}

// MARK: Nothing open

/// A dev server found in the repository, as the empty page offers it.
public struct SHDevServerItem: Identifiable, Equatable, Sendable {
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
public struct SHBrowserEmpty: View {
    let message: String
    let servers: [SHDevServerItem]
    let openShortcut: String?
    let start: (SHDevServerItem) -> Void
    let openURL: () -> Void

    public init(message: String, servers: [SHDevServerItem], openShortcut: String? = nil,
                start: @escaping (SHDevServerItem) -> Void, openURL: @escaping () -> Void) {
        self.message = message
        self.servers = servers
        self.openShortcut = openShortcut
        self.start = start
        self.openURL = openURL
    }

    public var body: some View {
        let sh = Color.sh
        VStack(spacing: 14) {
            Image(systemName: "globe")
                .font(.system(size: SHBrowserMetrics.emptyGlyph))
                .foregroundStyle(sh.textSecondary)
                .frame(width: SHBrowserMetrics.emptyCircle, height: SHBrowserMetrics.emptyCircle)
                .background(sh.bgSelected, in: Circle())
                .accessibilityHidden(true)
            Text("No page open")
                .font(.shSans(14, .semibold))
                .foregroundStyle(sh.textPrimary)
            Text(message)
                .font(.sh(.ui, weight: .regular))
                .foregroundStyle(sh.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: SHBrowserMetrics.emptyTextWidth)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: SH.Space.m) {
                ForEach(servers) { server in
                    SHDevServerCard(server) { start(server) }
                }
                Button(action: openURL) {
                    HStack(spacing: SH.Space.m) {
                        Image(systemName: "globe").font(.system(size: 12)).foregroundStyle(sh.textSecondary)
                        Text("Open a URL").font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textPrimary)
                        Spacer(minLength: SH.Space.m)
                        if let openShortcut { SHKeycap(openShortcut) }
                    }
                    .padding(.horizontal, SH.Space.l)
                    .padding(.vertical, 10)
                    .background(sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Radius.m))
                    .shBorder(sh.lineSubtle, radius: SH.Radius.m)
                    .contentShape(RoundedRectangle(cornerRadius: SH.Radius.m))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open a URL")
            }
            .padding(.top, SH.Space.m)
            .frame(maxWidth: SHBrowserMetrics.emptyWidth)
        }
        .padding(SH.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One dev server (PaneStates): the command in Geist Mono 12 over where it came from in Geist 11
/// `textTertiary`, and Start (secondary `s`).
public struct SHDevServerCard: View {
    let server: SHDevServerItem
    let start: () -> Void

    public init(_ server: SHDevServerItem, start: @escaping () -> Void) {
        self.server = server
        self.start = start
    }

    public var body: some View {
        let sh = Color.sh
        HStack(spacing: SH.Space.m) {
            Image(systemName: "terminal").font(.system(size: 12)).foregroundStyle(sh.textSecondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(server.command).font(.shMono(12)).foregroundStyle(sh.textPrimary).lineLimit(1)
                Text(server.detail).font(.shSans(11)).foregroundStyle(sh.textTertiary).lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: start) {
                Label(server.startTitle, systemImage: "play.fill")
            }
            .buttonStyle(.sh(.secondary, size: .s))
            .accessibilityLabel("\(server.startTitle) \(server.command)")
        }
        .padding(.horizontal, SH.Space.l)
        .padding(.vertical, 10)
        .background(sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Radius.m))
        .shBorder(sh.lineSubtle, radius: SH.Radius.m)
    }
}

// MARK: Viewport menu

/// One width the viewport menu offers.
public struct SHViewportOption: Identifiable, Equatable, Sendable {
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
public struct SHViewportMenu: View {
    let options: [SHViewportOption]
    let selection: String
    let dark: Bool
    let choose: (SHViewportOption) -> Void
    let toggleDark: () -> Void

    public init(options: [SHViewportOption], selection: String, dark: Bool, choose: @escaping (SHViewportOption) -> Void,
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
            SHChangesMenuDivider()
            Row(title: "Dark appearance", trailing: nil, checked: dark, action: toggleDark)
        }
        .padding(SH.Space.s)
        .frame(width: SHBrowserMetrics.viewportMenuWidth)
        .shPopover()
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
            let sh = Color.sh
            HStack(spacing: SH.Space.m) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(sh.textPrimary)
                    .opacity(checked ? 1 : 0)
                    .frame(width: SHChangesMenuMetrics.glyphWidth)
                Text(title).font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textPrimary).lineLimit(1)
                Spacer(minLength: SH.Space.m)
                if let trailing { Text(trailing).font(.shMono(11)).foregroundStyle(sh.textTertiary) }
            }
            .padding(.horizontal, SH.Space.m)
            .frame(height: SHChangesMenuMetrics.rowHeight)
            .background(hovering ? sh.bgHover : .clear, in: RoundedRectangle(cornerRadius: SH.Radius.s))
            .contentShape(RoundedRectangle(cornerRadius: SH.Radius.s))
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
public struct SHElementPopover: View {
    let source: String?
    let add: () -> Void
    let copy: () -> Void

    public init(source: String?, add: @escaping () -> Void, copy: @escaping () -> Void) {
        self.source = source
        self.add = add
        self.copy = copy
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.s) {
            if let source {
                Text(source)
                    .font(.shMono(10.5))
                    .foregroundStyle(Color.sh.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .padding(.horizontal, SH.Space.xxs)
            }
            Button(action: add) {
                Label("Add to message", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.sh(.primary, size: .s))
            Button(action: copy) {
                Label("Copy selector", systemImage: "doc.on.doc").frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.sh(.ghost, size: .s))
        }
        .padding(SH.Space.m)
        .frame(width: SHBrowserMetrics.popoverWidth)
        .shPopover()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Picked element")
    }
}

/// An element picked in the Browser, as a chip (PaneBrowser's composer; docs/design/composer.md › Composer):
/// 26pt, padding 0×8, radius 6, a `lineStrong` line, the 12pt element glyph, the label in Geist
/// Mono 12, the source in Geist Mono 10.5 `textTertiary` when known, and a 9pt remove × in the
/// composer. `.compact` is the queue's read-only chip: 22pt, an 11pt `textSecondary` glyph, the
/// label in mono 11.
public struct SHElementChip: View {
    let label: String
    let source: String?
    let size: SHAttachmentChip.Size
    let remove: (() -> Void)?

    public init(_ label: String, source: String? = nil, size: SHAttachmentChip.Size = .regular, remove: (() -> Void)? = nil) {
        self.label = label
        self.source = source
        self.size = size
        self.remove = remove
    }

    public var body: some View {
        let sh = Color.sh
        let compact = size == .compact
        HStack(spacing: compact ? SH.Space.xs : SH.Space.s) {
            Image(systemName: shElementGlyph)
                .font(.system(size: compact ? 11 : SHBrowserMetrics.chipGlyph))
                .foregroundStyle(sh.textSecondary)
                .accessibilityHidden(true)
            Text(label)
                .font(.shMono(compact ? 11 : 12))
                .foregroundStyle(sh.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let source, !compact {
                Text(source).font(.shMono(10.5)).foregroundStyle(sh.textTertiary).lineLimit(1).truncationMode(.head)
            }
            if let remove {
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.system(size: SHBrowserMetrics.chipRemove - 1, weight: .semibold))
                        .foregroundStyle(sh.textTertiary)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(label)")
            }
        }
        .padding(.horizontal, compact ? SH.Space.s : SH.Space.m)
        .frame(height: compact ? SHBrowserMetrics.compactChipHeight : SHBrowserMetrics.chipHeight)
        .shBorder(sh.lineStrong, radius: compact ? SH.Radius.xs : SH.Radius.s)
        .fixedSize(horizontal: compact, vertical: false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel([label, source].compactMap { $0 }.joined(separator: ", "))
    }
}

// MARK: Console

/// A console line's kind.
public enum SHConsoleLevel: String, Equatable, Sendable {
    case log, warning, error
}

/// One console line, as its row draws it.
public struct SHConsoleLine: Identifiable, Equatable, Sendable {
    public let id: Int
    /// "14:02:11".
    public let time: String
    public let text: String
    public let level: SHConsoleLevel

    public init(id: Int, time: String, text: String, level: SHConsoleLevel = .log) {
        self.id = id
        self.time = time
        self.text = text
        self.level = level
    }
}

/// The console drawer's bar (PaneBrowser): 32pt on `bgBase` under a `lineStrong` line.
/// "Console", "Network" with its count, the warnings (the page's own errors show as warnings
/// too: no board draws a separate count) in `lanternText`, and Hide console (Show console while
/// the drawer is closed).
public struct SHConsoleBar: View {
    let network: Int
    let warnings: Int
    let open: Bool
    let toggle: () -> Void

    public init(network: Int, warnings: Int, open: Bool, toggle: @escaping () -> Void) {
        self.network = network
        self.warnings = warnings
        self.open = open
        self.toggle = toggle
    }

    public var body: some View {
        let sh = Color.sh
        HStack(spacing: SHBrowserMetrics.consoleGap) {
            Text("Console").font(.shSans(12, .semibold)).foregroundStyle(sh.textPrimary)
            HStack(spacing: SH.Space.xs) {
                Text("Network").font(.shSans(12)).foregroundStyle(sh.textSecondary)
                Text("\(network)").font(.shMono(10.5)).foregroundStyle(sh.textTertiary).shContentTransition(.numeric())
            }
            if warnings > 0 {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 12))
                    Text("\(warnings) warning\(warnings == 1 ? "" : "s")").font(.shSans(11.5))
                }
                .foregroundStyle(sh.lanternText)
            }
            Spacer(minLength: 0)
            Button(action: toggle) { Image(systemName: open ? "chevron.down" : "chevron.up") }
                .buttonStyle(.shIcon(size: SHBrowserMetrics.consoleToggle))
                .shHelp(open ? "Hide console" : "Show console")
                .accessibilityLabel(open ? "Hide console" : "Show console")
        }
        .padding(.leading, 14)
        .padding(.trailing, SH.Space.m)
        .frame(height: SHBrowserMetrics.consoleBarHeight)
        .background(sh.bgBase)
        .overlay(alignment: .top) { SHHairline(color: sh.lineStrong) }
        .accessibilityElement(children: .contain)
    }
}

/// A console line (PaneBrowser): at least 22pt, 14pt sides, Geist Mono 11: the time in
/// `textTertiary`, the message in `textSecondary`, truncating. A warning (the page's own errors
/// included: no board draws them apart) sits on `lanternTint` in `lanternText`.
public struct SHConsoleRow: View, Equatable {
    let line: SHConsoleLine

    public init(_ line: SHConsoleLine) { self.line = line }

    public var body: some View {
        let _ = SHRenderProbe.tick("browser.consoleRow")
        let sh = Color.sh
        HStack(spacing: 10) {
            Text(line.time).foregroundStyle(sh.textTertiary)
            Text(line.text)
                .foregroundStyle(line.level == .warning ? sh.lanternText : sh.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .font(.shMono(11))
        .padding(.horizontal, 14)
        .frame(minHeight: SHBrowserMetrics.consoleRowHeight)
        .background(line.level == .warning ? sh.lanternTint : .clear)
        .help(line.text)
    }
}
