import SwiftUI

/// What one row of Settings ▸ MCP servers draws. A plain value: the list compares rows, so a
/// row redraws only when what it shows changed.
public struct MCPServerRowModel: Equatable, Identifiable, Sendable {
    public enum Kind: Sendable, Hashable { case remote, local }

    /// The Sign-in column.
    public enum SignIn: Equatable, Sendable {
        /// Signed in with OAuth: the account, or "Signed in".
        case account(String)
        /// OAuth and no token: a lantern Sign in.
        case signIn
        /// The token can't be refreshed: "Expired" and Sign in.
        case expired
        /// A 403 asked for more: the missing scopes and Sign in again.
        case moreAccess([String])
        /// A header's value comes from pi's environment: `$GITHUB_TOKEN`.
        case variable(String)
        /// One secret in Keychain: `DATABASE_URI`.
        case secret(String)
        /// Several environment variables.
        case variables(Int)
        /// A `${keychain:…}` value isn't in Keychain.
        case missingSecret(String)
        case none
    }

    /// What replaces the endpoint line: "Starting…", or an error in red.
    public enum Note: Equatable, Sendable {
        case starting(String)
        case error(String)
    }

    public var name: String
    public var kind: Kind
    public var endpoint: String
    public var status: MCPDotState
    public var note: Note?
    public var signIn: SignIn
    /// nil until the tools are known: a dash.
    public var tools: Int?
    public var enabled: Bool

    public var id: String { name }

    public init(name: String, kind: Kind, endpoint: String, status: MCPDotState, note: Note? = nil, signIn: SignIn,
                tools: Int?, enabled: Bool = true) {
        self.name = name
        self.kind = kind
        self.endpoint = endpoint
        self.status = status
        self.note = note
        self.signIn = signIn
        self.tools = tools
        self.enabled = enabled
    }
}

/// The list's column labels: Server, Sign-in, Tools.
public struct MCPServerListHeader: View {
    public init() {}

    public var body: some View {
        let M = NWMCPMetrics.self
        HStack(spacing: M.columnGap) {
            Color.clear.frame(width: M.switchColumn)
            label("Server").frame(maxWidth: .infinity, alignment: .leading)
            label("Sign-in").frame(width: M.signInColumn, alignment: .leading)
            label("Tools").frame(width: M.toolsColumn, alignment: .trailing)
            Color.clear.frame(width: M.chevronColumn)
        }
        .padding(.horizontal, M.rowSides)
        .frame(height: M.headerHeight)
        .background(Color.nw.bgSunken)
        .overlay(alignment: .bottom) { NWHairline() }
        .accessibilityHidden(true)
    }

    private func label(_ text: String) -> some View {
        Text(text).nwSettingsLabel(table: true).lineLimit(1)
    }
}

/// One server: its switch, dot, name, Remote or Local, endpoint (or what it's doing), how it
/// signs in, and how many tools it has. Clicking it opens its detail in place.
public struct MCPServerRow: View, Equatable {
    public struct Actions {
        public var toggle: (Bool) -> Void
        public var open: () -> Void
        public var signIn: () -> Void

        public init(toggle: @escaping (Bool) -> Void, open: @escaping () -> Void, signIn: @escaping () -> Void) {
            self.toggle = toggle
            self.open = open
            self.signIn = signIn
        }
    }

    let model: MCPServerRowModel
    let open: Bool
    let first: Bool
    let actions: Actions
    @State private var hovering = false

    public init(_ model: MCPServerRowModel, open: Bool, first: Bool, actions: Actions) {
        self.model = model
        self.open = open
        self.first = first
        self.actions = actions
    }

    public nonisolated static func == (a: MCPServerRow, b: MCPServerRow) -> Bool {
        a.model == b.model && a.open == b.open && a.first == b.first
    }

    public var body: some View {
        let _ = NWRenderProbe.tick("mcp.row")
        let nw = Color.nw
        let M = NWMCPMetrics.self
        HStack(spacing: M.columnGap) {
            Toggle(model.name, isOn: Binding(get: { model.enabled }, set: actions.toggle))
                .toggleStyle(.nwSwitch)
                .labelsHidden()
                .frame(width: M.switchColumn)
            VStack(alignment: .leading, spacing: NW.Space.xs) {
                HStack(spacing: NW.Space.m) {
                    MCPStatusDot(model.status)
                    Text(model.name)
                        .font(.nwMono(M.nameSize, .semibold))
                        .foregroundStyle(model.enabled ? nw.textPrimary : nw.textTertiary)
                        .lineLimit(1)
                    MCPKindTag(model.kind)
                }
                noteLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(model.enabled ? 1 : NWMCPMetrics.offOpacity)
            signIn.frame(width: M.signInColumn, alignment: .leading)
                .opacity(model.enabled ? 1 : NWMCPMetrics.offOpacity)
            Text(model.tools.map(String.init) ?? "—")
                .font(.nwSans(M.cellSize))
                .monospacedDigit()
                .foregroundStyle(model.tools == nil ? nw.textTertiary : nw.textSecondary)
                .frame(width: M.toolsColumn, alignment: .trailing)
                .opacity(model.enabled ? 1 : NWMCPMetrics.offOpacity)
            Image(systemName: open ? "chevron.down" : "chevron.right")
                .font(.nwSans(M.cellSize - 1, .semibold))
                .foregroundStyle(nw.textTertiary)
                .frame(width: M.chevronColumn)
                .accessibilityHidden(true)
        }
        .padding(.vertical, M.rowVertical)
        .padding(.horizontal, M.rowSides)
        .frame(minHeight: M.rowMinHeight)
        .background(open || hovering ? nw.bgHover : Color.clear)
        .overlay(alignment: .top) { if !first { NWHairline() } }
        .contentShape(Rectangle())
        .onTapGesture(perform: actions.open)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(model.name), \(model.status.label)")
        .accessibilityAction(named: open ? "Close" : "Open", actions.open)
    }

    @ViewBuilder private var noteLine: some View {
        let nw = Color.nw
        let M = NWMCPMetrics.self
        switch model.note {
        case .starting(let text):
            Text(text).font(.nwSans(M.cellSize)).foregroundStyle(nw.textSecondary).lineLimit(1)
        case .error(let text):
            Text(text).font(.nwSans(M.cellSize)).foregroundStyle(nw.failed).lineLimit(1).help(text)
        case nil:
            Text(model.endpoint)
                .font(.nwMono(M.endpointSize))
                .foregroundStyle(nw.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(model.endpoint)
        }
    }

    @ViewBuilder private var signIn: some View {
        let nw = Color.nw
        let M = NWMCPMetrics.self
        switch model.signIn {
        case .account(let account):
            cell("person.crop.circle", account)
        case .signIn:
            Button("Sign in", action: actions.signIn).buttonStyle(.nw(.primary, size: .s))
        case .expired:
            HStack(spacing: NW.Space.m) {
                Text("Expired").font(.nwSans(M.cellSize)).foregroundStyle(nw.lanternText)
                Button("Sign in", action: actions.signIn).buttonStyle(.nw(.secondary, size: .s))
            }
        case .moreAccess(let scopes):
            HStack(spacing: NW.Space.m) {
                Text(scopes.map { "+" + $0 }.joined(separator: " "))
                    .font(.nwMono(M.endpointSize))
                    .foregroundStyle(nw.lanternText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Button("Sign in again", action: actions.signIn).buttonStyle(.nw(.secondary, size: .s)).fixedSize()
            }
        case .variable(let name):
            cell("key", name, mono: true)
        case .secret(let name):
            cell("lock", name, mono: true)
        case .variables(let count):
            cell("lock", "\(count) variables")
        case .missingSecret(let name):
            HStack(spacing: NW.Space.s + NW.Space.xxs) {
                Image(systemName: "lock").font(.nwSans(M.cellSize - 1)).foregroundStyle(nw.lanternText).accessibilityHidden(true)
                Text("\(name) isn’t set").font(.nwSans(M.cellSize)).foregroundStyle(nw.lanternText).lineLimit(1)
            }
        case .none:
            Text("None").font(.nwSans(M.cellSize)).foregroundStyle(nw.textTertiary)
        }
    }

    private func cell(_ symbol: String, _ text: String, mono: Bool = false) -> some View {
        let nw = Color.nw
        let M = NWMCPMetrics.self
        return HStack(spacing: NW.Space.s + NW.Space.xxs) {
            Image(systemName: symbol).font(.nwSans(M.cellSize - 1)).foregroundStyle(nw.textTertiary).accessibilityHidden(true)
            Text(text)
                .font(mono ? .nwMono(M.endpointSize) : .nwSans(M.cellSize))
                .foregroundStyle(nw.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// "Remote" with a globe, or "Local" with a terminal: how the server is reached.
public struct MCPKindTag: View {
    let kind: MCPServerRowModel.Kind

    public init(_ kind: MCPServerRowModel.Kind) {
        self.kind = kind
    }

    public var body: some View {
        let nw = Color.nw
        let M = NWMCPMetrics.self
        HStack(spacing: NW.Space.xs) {
            Image(systemName: kind == .remote ? "globe" : "terminal").font(.nwSans(M.tagIconSize)).accessibilityHidden(true)
            Text(kind == .remote ? "Remote" : "Local").font(.nwSans(M.tagTextSize))
        }
        .foregroundStyle(nw.textSecondary)
        .padding(.horizontal, M.tagSides)
        .frame(height: M.tagHeight)
        .background(nw.bgSelected, in: RoundedRectangle(cornerRadius: NW.Radius.xs))
        .fixedSize()
    }
}
