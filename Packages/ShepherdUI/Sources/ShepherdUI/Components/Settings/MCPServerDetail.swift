import SwiftUI

/// What an open server row shows under it: its sign-in, its tools and how the agent reaches
/// them, and its connection.
public struct MCPServerDetailModel: Equatable, Sendable {
    public enum SignIn: Equatable, Sendable {
        /// Signed in with OAuth.
        case signedIn(account: String?, scopes: [String], note: String, title: String = "Signed in")
        /// OAuth that needs you: `title` says why ("Not signed in", "Expired", "Needs issues:write").
        case needsSignIn(title: String, note: String, again: Bool)
        /// A header whose value comes from a variable.
        case header(name: String, variable: String)
        /// Environment variables; `missing` are the Keychain ones that aren't set.
        case secrets(names: [String], missing: [String])
        case unverified(String)
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
    public var toolsNote: String?
    /// Tool exposure: Direct declares every tool in every prompt, Search (the default) leaves them
    /// out until the agent searches for one.
    public var direct: Bool?
    public var searchCost: String
    public var directCost: String
    /// "5 of 21 chosen" when only some tools are visible.
    public var chosenNote: String?
    public var transport: String
    public var hosts: [Host]
    public var message: String?

    public init(signIn: SignIn, toolNames: [String], toolCount: Int?, direct: Bool?, searchCost: String, directCost: String,
                chosenNote: String? = nil, transport: String, hosts: [Host], message: String? = nil, toolsNote: String? = nil) {
        self.signIn = signIn
        self.toolNames = toolNames
        self.toolCount = toolCount
        self.toolsNote = toolsNote
        self.direct = direct
        self.searchCost = searchCost
        self.directCost = directCost
        self.chosenNote = chosenNote
        self.transport = transport
        self.hosts = hosts
        self.message = message
    }
}

public struct MCPServerDetail: View {
    public struct Actions {
        public var signIn: () -> Void
        public var signOut: () -> Void
        public var setDirect: ((Bool) -> Void)?
        public var chooseTools: (() -> Void)?
        public var edit: () -> Void
        public var reconnect: (() -> Void)?
        public var copyJSON: () -> Void
        public var remove: () -> Void

        public init(signIn: @escaping () -> Void, signOut: @escaping () -> Void, setDirect: ((Bool) -> Void)?,
                    chooseTools: (() -> Void)?, edit: @escaping () -> Void,
                    reconnect: (() -> Void)?, copyJSON: @escaping () -> Void, remove: @escaping () -> Void) {
            self.signIn = signIn
            self.signOut = signOut
            self.setDirect = setDirect
            self.chooseTools = chooseTools
            self.edit = edit
            self.reconnect = reconnect
            self.copyJSON = copyJSON
            self.remove = remove
        }

        public static let none = Actions(signIn: {}, signOut: {}, setDirect: { _ in }, chooseTools: {},
                                         edit: {}, reconnect: {}, copyJSON: {}, remove: {})
    }

    let model: MCPServerDetailModel
    let actions: Actions

    public init(_ model: MCPServerDetailModel, actions: Actions) {
        self.model = model
        self.actions = actions
    }

    public var body: some View {
        let sh = Color.sh
        let M = SHMCPMetrics.self
        VStack(alignment: .leading, spacing: M.detailPadding) {
            HStack(alignment: .top, spacing: M.detailColumnGap) {
                block("Sign-in") { signIn }.frame(maxWidth: .infinity, alignment: .leading)
                block(model.toolCount.map { "Tools · \($0)" } ?? "Tools") { tools }.frame(maxWidth: .infinity, alignment: .leading)
                block("Connection") { connection }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let message = model.message {
                Text(message)
                    .shText(size: M.detailNoteSize, lineHeight: 1.5)
                    .foregroundStyle(sh.failed)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack(spacing: SH.Space.s) {
                Button(action: actions.edit) { Label("Edit…", systemImage: "pencil") }
                    .buttonStyle(.sh(.secondary, size: .s))
                if let reconnect = actions.reconnect {
                    Button(action: reconnect) { Label("Reconnect", systemImage: "arrow.clockwise") }
                        .buttonStyle(.sh(.ghost, size: .s))
                }
                Button(action: actions.copyJSON) { Label("Copy JSON", systemImage: "doc.on.doc") }
                    .buttonStyle(.sh(.ghost, size: .s))
                    .help("Copies the entry as mcpServers JSON; secrets stay references.")
                Spacer(minLength: SH.Space.m)
                Button("Remove", action: actions.remove).buttonStyle(.sh(.danger, size: .s))
            }
            .padding(.top, M.detailPadding)
            .overlay(alignment: .top) { SHHairline() }
        }
        .padding(.vertical, M.detailPadding)
        .padding(.leading, M.detailLeading)
        .padding(.trailing, M.rowSides)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(sh.bgSunken)
        .overlay(alignment: .top) { SHHairline() }
    }

    @ViewBuilder private var signIn: some View {
        let sh = Color.sh
        let M = SHMCPMetrics.self
        switch model.signIn {
        case .signedIn(let account, let scopes, let note, let title):
            HStack(spacing: SH.Space.m) {
                Image(systemName: "person.crop.circle").foregroundStyle(sh.textSecondary).accessibilityHidden(true)
                if let account {
                    Text("Signed in as \(Text(account).fontWeight(.semibold))")
                } else {
                    Text(title)
                }
            }
            .font(.shSans(M.detailTextSize))
            .foregroundStyle(sh.textPrimary)
            if !scopes.isEmpty { MCPChipFlow(scopes.map { MCPChip($0) }) }
            noteText(note)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: SH.Space.s) { signedInActions }.fixedSize()
                VStack(alignment: .leading, spacing: SH.Space.s) { signedInActions }
            }
        case .needsSignIn(let title, let note, let again):
            Text(title).font(.shSans(M.detailTextSize)).foregroundStyle(sh.lanternText)
            noteText(note)
            Button(again ? "Sign in again" : "Sign in", action: actions.signIn).buttonStyle(.sh(.primary, size: .s))
        case .header(let name, let variable):
            HStack(spacing: SH.Space.m) {
                Image(systemName: "key").foregroundStyle(sh.textSecondary).accessibilityHidden(true)
                Text(variable).font(.shMono(M.detailOptionSize)).foregroundStyle(sh.textPrimary)
            }
            noteText("Sent as the \(name) header, read from your login shell’s environment.")
        case .secrets(let names, let missing):
            VStack(alignment: .leading, spacing: SH.Space.xs) {
                ForEach(names, id: \.self) { name in
                    HStack(spacing: SH.Space.s + SH.Space.xxs) {
                        Image(systemName: "lock").font(.shSans(M.detailNoteSize)).accessibilityHidden(true)
                        Text(name).font(.shMono(M.detailNoteSize))
                        if missing.contains(name) { Text("isn’t set").font(.shSans(M.detailNoteSize)) }
                    }
                    .foregroundStyle(missing.contains(name) ? sh.lanternText : sh.textSecondary)
                }
            }
            noteText(missing.isEmpty ? "Values marked with a lock live in Keychain." : "Set it with Edit…, then Reconnect.")
        case .unverified(let note):
            noteText(note)
        case .none:
            Text("None").font(.shSans(M.detailTextSize)).foregroundStyle(sh.textSecondary)
            noteText("This server needs no sign-in.")
        }
    }

    @ViewBuilder private var tools: some View {
        let sh = Color.sh
        let M = SHMCPMetrics.self
        if model.toolNames.isEmpty {
            noteText(model.toolsNote ?? (model.toolCount == 0 ? "It lists no tools." : "Listed once it connects."))
        } else {
            let shown = Array(model.toolNames.prefix(M.visibleToolChips))
            let more = max(0, (model.toolCount ?? model.toolNames.count) - shown.count)
            MCPChipFlow(shown.map { MCPChip($0) }, more: more > 0 ? "+\(more)" : nil, moreAction: { actions.chooseTools?() })
        }
        VStack(alignment: .leading, spacing: SH.Space.s) {
            Text("Tool exposure").shSettingsLabel(table: true)
            option("Search", cost: model.searchCost, selected: model.direct == false,
                   help: "The agent searches this server’s tools when it needs one. Nothing of them is in a prompt until then.") {
                actions.setDirect?(false)
            }
            option("Direct", cost: model.directCost, selected: model.direct == true,
                   help: "Every tool is declared in every prompt, so the agent sees them without searching.") {
                actions.setDirect?(true)
            }
        }.disabled(actions.setDirect == nil)
        HStack(spacing: SH.Space.m) {
            if let chooseTools = actions.chooseTools {
                Button("Choose which tools…", action: chooseTools)
                    .buttonStyle(.shLink)
                    .font(.shSans(M.detailNoteSize))
                    .disabled(model.toolNames.isEmpty)
            }
            if let chosen = model.chosenNote {
                Text(chosen).font(.shSans(M.detailNoteSize)).foregroundStyle(sh.textTertiary)
            }
        }
    }

    @ViewBuilder private var connection: some View {
        let sh = Color.sh
        let M = SHMCPMetrics.self
        Text(model.transport).font(.shSans(M.detailOptionSize)).foregroundStyle(sh.textSecondary)
        noteText("Connects when a thread starts and stays until it ends.")
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.hosts, id: \.name) { host in
                MCPHostRow(host)
            }
        }
    }

    private func option(_ title: String, cost: String, selected: Bool, help: String, action: @escaping () -> Void) -> some View {
        let sh = Color.sh
        let M = SHMCPMetrics.self
        return Button(action: action) {
            HStack(spacing: SH.Space.m) {
                SHRadioMark(selected: selected)
                Text(title).font(.shSans(M.detailOptionSize)).foregroundStyle(selected ? sh.textPrimary : sh.textSecondary)
                Text(cost).font(.shMono(M.tagTextSize)).foregroundStyle(sh.textTertiary)
            }
            // A pointer's 24pt, not the label's 17: the button is taller than its text, and the
            // negative padding below hands that room back so the column doesn't grow.
            .padding(.vertical, M.optionHitPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, -M.optionHitPadding)
        .help(help)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder private var signedInActions: some View {
        Button("Sign in again", action: actions.signIn).buttonStyle(.sh(.secondary, size: .s))
        Button("Sign out", action: actions.signOut).buttonStyle(.sh(.ghost, size: .s))
    }

    private func noteText(_ text: String) -> some View {
        Text(text)
            .shText(size: SHMCPMetrics.detailNoteSize, lineHeight: 1.5)
            .foregroundStyle(Color.sh.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func block<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: SHMCPMetrics.detailBlockGap) {
            Text(title).shSettingsLabel(table: true)
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
        let sh = Color.sh
        let M = SHMCPMetrics.self
        HStack(spacing: SH.Space.m) {
            Group {
                switch host.mark {
                case .done:
                    Image(systemName: "checkmark").font(.shSans(M.cellSize - 2, .bold)).foregroundStyle(sh.done)
                case .working:
                    Circle().fill(sh.running).frame(width: M.dotSize, height: M.dotSize)
                case .offline:
                    Circle().strokeBorder(sh.textTertiary, lineWidth: M.dotStroke).frame(width: M.dotSize, height: M.dotSize)
                case .failed:
                    Image(systemName: "xmark").font(.shSans(M.cellSize - 2, .bold)).foregroundStyle(sh.failed)
                case .none:
                    Color.clear
                }
            }
            .frame(width: M.cellSize)
            .accessibilityHidden(true)
            Text(host.name)
                .font(.shMono(M.cellSize))
                .foregroundStyle(sh.textPrimary)
                .lineLimit(1)
                .frame(width: M.hostNameWidth * ThemeStore.shared.textScale, alignment: .leading)
            Text(host.detail)
                .font(.shSans(M.cellSize))
                .foregroundStyle(host.mark == .failed ? sh.failed : sh.textTertiary)
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
        let sh = Color.sh
        let M = SHMCPMetrics.self
        Text(text)
            .font(.shMono(M.tagTextSize))
            .foregroundStyle(sh.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, M.chipSides)
            .frame(height: M.chipHeight)
            .shBorder(sh.lineSubtle, radius: M.chipRadius)
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
        SHFlowLayout(spacing: SH.Space.s, lineSpacing: SH.Space.s) {
            ForEach(chips, id: \.self) { $0 }
            if let more {
                Button(more, action: moreAction)
                    .buttonStyle(.shLink)
                    .font(.shSans(SHMCPMetrics.cellSize))
                    .frame(height: SHMCPMetrics.chipHeight)
            }
        }
    }
}
