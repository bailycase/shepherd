import SwiftUI

/// What an open server row shows under it: its sign-in, its tools and how the agent reaches
/// them, and its connection.
public struct MCPServerDetailModel: Equatable, Sendable {
    public enum SignIn: Equatable, Sendable {
        /// Signed in with OAuth.
        case signedIn(account: String?, scopes: [String], note: String)
        /// OAuth that needs you: `title` says why ("Not signed in", "Expired", "Needs issues:write").
        case needsSignIn(title: String, note: String, again: Bool)
        /// A header whose value comes from a variable.
        case header(name: String, variable: String)
        /// Environment variables; `missing` are the Keychain ones that aren't set.
        case secrets(names: [String], missing: [String])
        case none
    }

    public struct Host: Equatable, Sendable {
        public enum Mark: Sendable { case done, working, offline, failed, none }
        public var name: String
        public var detail: String
        public var mark: Mark

        public init(name: String, detail: String, mark: Mark) {
            self.name = name
            self.detail = detail
            self.mark = mark
        }
    }

    public var signIn: SignIn
    public var toolNames: [String]
    /// nil until the tools are known.
    public var toolCount: Int?
    public var direct: Bool
    public var proxyCost: String
    public var directCost: String
    /// "5 of 21 chosen" when only some tools are visible.
    public var chosenNote: String?
    public var transport: String
    public var startOptions: [String]
    public var start: Int
    public var hosts: [Host]
    public var message: String?

    public init(signIn: SignIn, toolNames: [String], toolCount: Int?, direct: Bool, proxyCost: String, directCost: String,
                chosenNote: String? = nil, transport: String, startOptions: [String], start: Int, hosts: [Host],
                message: String? = nil) {
        self.signIn = signIn
        self.toolNames = toolNames
        self.toolCount = toolCount
        self.direct = direct
        self.proxyCost = proxyCost
        self.directCost = directCost
        self.chosenNote = chosenNote
        self.transport = transport
        self.startOptions = startOptions
        self.start = start
        self.hosts = hosts
        self.message = message
    }
}

public struct MCPServerDetail: View {
    public struct Actions {
        public var signIn: () -> Void
        public var signOut: () -> Void
        public var setDirect: (Bool) -> Void
        public var chooseTools: () -> Void
        public var setStart: (Int) -> Void
        public var edit: () -> Void
        public var reconnect: () -> Void
        public var copyJSON: () -> Void
        public var remove: () -> Void

        public init(signIn: @escaping () -> Void, signOut: @escaping () -> Void, setDirect: @escaping (Bool) -> Void,
                    chooseTools: @escaping () -> Void, setStart: @escaping (Int) -> Void, edit: @escaping () -> Void,
                    reconnect: @escaping () -> Void, copyJSON: @escaping () -> Void, remove: @escaping () -> Void) {
            self.signIn = signIn
            self.signOut = signOut
            self.setDirect = setDirect
            self.chooseTools = chooseTools
            self.setStart = setStart
            self.edit = edit
            self.reconnect = reconnect
            self.copyJSON = copyJSON
            self.remove = remove
        }

        public static let none = Actions(signIn: {}, signOut: {}, setDirect: { _ in }, chooseTools: {}, setStart: { _ in },
                                         edit: {}, reconnect: {}, copyJSON: {}, remove: {})
    }

    let model: MCPServerDetailModel
    let actions: Actions

    public init(_ model: MCPServerDetailModel, actions: Actions) {
        self.model = model
        self.actions = actions
    }

    public var body: some View {
        let nw = Color.nw
        let M = NWMCPMetrics.self
        VStack(alignment: .leading, spacing: M.detailPadding) {
            HStack(alignment: .top, spacing: M.detailColumnGap) {
                block("Sign-in") { signIn }.frame(maxWidth: .infinity, alignment: .leading)
                block(model.toolCount.map { "Tools · \($0)" } ?? "Tools") { tools }.frame(maxWidth: .infinity, alignment: .leading)
                block("Connection") { connection }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let message = model.message {
                Text(message)
                    .nwText(size: M.detailNoteSize, lineHeight: 1.5)
                    .foregroundStyle(nw.failed)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack(spacing: NW.Space.s) {
                Button(action: actions.edit) { Label("Edit…", systemImage: "pencil") }
                    .buttonStyle(.nw(.secondary, size: .s))
                Button(action: actions.reconnect) { Label("Reconnect", systemImage: "arrow.clockwise") }
                    .buttonStyle(.nw(.ghost, size: .s))
                Button(action: actions.copyJSON) { Label("Copy JSON", systemImage: "doc.on.doc") }
                    .buttonStyle(.nw(.ghost, size: .s))
                    .help("Copies the entry as mcpServers JSON; secrets stay references.")
                Spacer(minLength: NW.Space.m)
                Button("Remove", action: actions.remove).buttonStyle(.nw(.danger, size: .s))
            }
            .padding(.top, M.detailPadding)
            .overlay(alignment: .top) { NWHairline() }
        }
        .padding(.vertical, M.detailPadding)
        .padding(.leading, M.detailLeading)
        .padding(.trailing, M.rowSides)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(nw.bgSunken)
        .overlay(alignment: .top) { NWHairline() }
    }

    @ViewBuilder private var signIn: some View {
        let nw = Color.nw
        let M = NWMCPMetrics.self
        switch model.signIn {
        case .signedIn(let account, let scopes, let note):
            HStack(spacing: NW.Space.m) {
                Image(systemName: "person.crop.circle").foregroundStyle(nw.textSecondary).accessibilityHidden(true)
                if let account {
                    Text("Signed in as \(Text(account).fontWeight(.semibold))")
                } else {
                    Text("Signed in")
                }
            }
            .font(.nwSans(M.detailTextSize))
            .foregroundStyle(nw.textPrimary)
            if !scopes.isEmpty { MCPChipFlow(scopes.map { MCPChip($0) }) }
            noteText(note)
            HStack(spacing: NW.Space.s) {
                Button("Sign in again", action: actions.signIn).buttonStyle(.nw(.secondary, size: .s))
                Button("Sign out", action: actions.signOut).buttonStyle(.nw(.ghost, size: .s))
            }
        case .needsSignIn(let title, let note, let again):
            Text(title).font(.nwSans(M.detailTextSize)).foregroundStyle(nw.lanternText)
            noteText(note)
            Button(again ? "Sign in again" : "Sign in", action: actions.signIn).buttonStyle(.nw(.primary, size: .s))
        case .header(let name, let variable):
            HStack(spacing: NW.Space.m) {
                Image(systemName: "key").foregroundStyle(nw.textSecondary).accessibilityHidden(true)
                Text(variable).font(.nwMono(M.detailOptionSize)).foregroundStyle(nw.textPrimary)
            }
            noteText("Sent as the \(name) header, read from your login shell’s environment.")
        case .secrets(let names, let missing):
            VStack(alignment: .leading, spacing: NW.Space.xs) {
                ForEach(names, id: \.self) { name in
                    HStack(spacing: NW.Space.s + NW.Space.xxs) {
                        Image(systemName: "lock").font(.nwSans(M.detailNoteSize)).accessibilityHidden(true)
                        Text(name).font(.nwMono(M.detailNoteSize))
                        if missing.contains(name) { Text("isn’t set").font(.nwSans(M.detailNoteSize)) }
                    }
                    .foregroundStyle(missing.contains(name) ? nw.lanternText : nw.textSecondary)
                }
            }
            noteText(missing.isEmpty ? "Values marked with a lock live in Keychain." : "Set it with Edit…, then Reconnect.")
        case .none:
            Text("None").font(.nwSans(M.detailTextSize)).foregroundStyle(nw.textSecondary)
            noteText("This server needs no sign-in.")
        }
    }

    @ViewBuilder private var tools: some View {
        let nw = Color.nw
        let M = NWMCPMetrics.self
        if model.toolNames.isEmpty {
            noteText(model.toolCount == 0 ? "It lists no tools." : "Listed once it connects.")
        } else {
            let shown = Array(model.toolNames.prefix(M.visibleToolChips))
            let more = max(0, (model.toolCount ?? model.toolNames.count) - shown.count)
            MCPChipFlow(shown.map { MCPChip($0) }, more: more > 0 ? "+\(more)" : nil, moreAction: actions.chooseTools)
        }
        VStack(alignment: .leading, spacing: NW.Space.s) {
            option("Through one mcp tool", cost: model.proxyCost, selected: !model.direct) { actions.setDirect(false) }
            option("Each tool on its own", cost: model.directCost, selected: model.direct) { actions.setDirect(true) }
        }
        HStack(spacing: NW.Space.m) {
            Button("Choose which tools…", action: actions.chooseTools)
                .buttonStyle(.nwLink)
                .font(.nwSans(M.detailNoteSize))
                .disabled(model.toolNames.isEmpty)
            if let chosen = model.chosenNote {
                Text(chosen).font(.nwSans(M.detailNoteSize)).foregroundStyle(nw.textTertiary)
            }
        }
    }

    @ViewBuilder private var connection: some View {
        let nw = Color.nw
        let M = NWMCPMetrics.self
        Text(model.transport).font(.nwSans(M.detailOptionSize)).foregroundStyle(nw.textSecondary)
        Menu {
            ForEach(Array(model.startOptions.enumerated()), id: \.offset) { index, option in
                Button(option) { actions.setStart(index) }
            }
        } label: {
            HStack(spacing: NW.Space.m) {
                Text("Start: \(Text(model.startOptions.indices.contains(model.start) ? model.startOptions[model.start] : "").foregroundStyle(nw.textPrimary))")
                    .foregroundStyle(nw.textTertiary)
                Image(systemName: "chevron.down").font(.nwSans(9, .semibold)).foregroundStyle(nw.textTertiary)
            }
            .font(.nwSans(M.cellSize))
            .padding(.leading, NW.Space.m + NW.Space.xxs)
            .padding(.trailing, NW.Space.m)
            .frame(height: NW.Height.controlM)
            .background(nw.bgRaised, in: RoundedRectangle(cornerRadius: NW.Radius.s))
            .nwBorder(nw.lineStrong, radius: NW.Radius.s)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Start")
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.hosts, id: \.name) { host in
                MCPHostRow(host)
            }
        }
    }

    private func option(_ title: String, cost: String, selected: Bool, action: @escaping () -> Void) -> some View {
        let nw = Color.nw
        let M = NWMCPMetrics.self
        return Button(action: action) {
            HStack(spacing: NW.Space.m) {
                NWRadioMark(selected: selected)
                Text(title).font(.nwSans(M.detailOptionSize)).foregroundStyle(selected ? nw.textPrimary : nw.textSecondary)
                Text(cost).font(.nwMono(M.tagTextSize)).foregroundStyle(nw.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func noteText(_ text: String) -> some View {
        Text(text)
            .nwText(size: NWMCPMetrics.detailNoteSize, lineHeight: 1.5)
            .foregroundStyle(Color.nw.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func block<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: NWMCPMetrics.detailBlockGap) {
            Text(title).nwSettingsLabel(table: true)
            content()
        }
    }
}

/// A host's line under Connection: "This Mac  connected".
public struct MCPHostRow: View {
    let host: MCPServerDetailModel.Host

    public init(_ host: MCPServerDetailModel.Host) {
        self.host = host
    }

    public var body: some View {
        let nw = Color.nw
        let M = NWMCPMetrics.self
        HStack(spacing: NW.Space.m) {
            Group {
                switch host.mark {
                case .done:
                    Image(systemName: "checkmark").font(.nwSans(M.cellSize - 2, .bold)).foregroundStyle(nw.done)
                case .working:
                    Circle().fill(nw.running).frame(width: M.dotSize, height: M.dotSize)
                case .offline:
                    Circle().strokeBorder(nw.textTertiary, lineWidth: M.dotStroke).frame(width: M.dotSize, height: M.dotSize)
                case .failed:
                    Image(systemName: "xmark").font(.nwSans(M.cellSize - 2, .bold)).foregroundStyle(nw.failed)
                case .none:
                    Color.clear
                }
            }
            .frame(width: M.cellSize)
            .accessibilityHidden(true)
            Text(host.name)
                .font(.nwMono(M.cellSize))
                .foregroundStyle(nw.textPrimary)
                .lineLimit(1)
                .frame(width: M.hostNameWidth, alignment: .leading)
            Text(host.detail)
                .font(.nwSans(M.cellSize))
                .foregroundStyle(host.mark == .failed ? nw.failed : nw.textTertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(minHeight: M.hostRowHeight)
        .accessibilityElement(children: .combine)
    }
}

/// A mono chip: a scope or a tool's name.
public struct MCPChip: View, Hashable {
    let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        let nw = Color.nw
        let M = NWMCPMetrics.self
        Text(text)
            .font(.nwMono(M.tagTextSize))
            .foregroundStyle(nw.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, M.chipSides)
            .frame(height: M.chipHeight)
            .nwBorder(nw.lineSubtle, radius: M.chipRadius)
            .fixedSize()
    }
}

/// Chips that wrap, with a "+17" link after them.
struct MCPChipFlow: View {
    let chips: [MCPChip]
    let more: String?
    let moreAction: () -> Void

    init(_ chips: [MCPChip], more: String? = nil, moreAction: @escaping () -> Void = {}) {
        self.chips = chips
        self.more = more
        self.moreAction = moreAction
    }

    var body: some View {
        NWFlowLayout(spacing: NW.Space.s, lineSpacing: NW.Space.s) {
            ForEach(chips, id: \.self) { $0 }
            if let more {
                Button(more, action: moreAction)
                    .buttonStyle(.nwLink)
                    .font(.nwSans(NWMCPMetrics.cellSize))
                    .frame(height: NWMCPMetrics.chipHeight)
            }
        }
    }
}
