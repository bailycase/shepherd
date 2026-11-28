import SwiftUI
import ShepherdUI

extension AppLayout {
    static let spaceMCPSignInWidth: CGFloat = 110
    static let spaceMCPToolsWidth: CGFloat = 56
}

/// One server on a space's MCP page (`gspc-row`): its name over its endpoint, how it signs in, its tools, a switch and a chevron that
/// opens its detail. A server a parent supplies has no switch: its row offers Override here and Disable in the space instead.
struct SpaceMCPRow: View, Equatable {
    struct Inherited {
        var overrideHere: () -> Void
        var overrideEnabled: Bool
        var toggleTitle: String
        var toggle: () -> Void
        var toggleEnabled: Bool
        var toggleHelp: String
    }

    let model: MCPServerRowModel
    var open = false
    /// "Overrides payments-api" and a way back, on a server this space redefines.
    var overrides: (parent: String, reset: () -> Void, enabled: Bool)?
    var inherited: Inherited?
    let actions: MCPServerRow.Actions
    @State private var hovering = false

    nonisolated static func == (a: SpaceMCPRow, b: SpaceMCPRow) -> Bool {
        a.model == b.model && a.open == b.open && a.overrides?.parent == b.overrides?.parent && a.overrides?.enabled == b.overrides?.enabled
            && (a.inherited == nil) == (b.inherited == nil) && a.inherited?.toggleTitle == b.inherited?.toggleTitle
            && a.inherited?.overrideEnabled == b.inherited?.overrideEnabled && a.inherited?.toggleEnabled == b.inherited?.toggleEnabled
    }

    var body: some View {
        let _ = SHRenderProbe.tick("spaceMCP.row")
        HStack(spacing: AppLayout.spaceRowGap) {
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(model.name).font(.sh(.ui, weight: .medium)).foregroundStyle(model.enabled ? Color.sh.textPrimary : Color.sh.textTertiary)
                    .lineLimit(1)
                detail
                if let overrides {
                    HStack(spacing: SH.Space.m) {
                        Text("Overrides \(overrides.parent)").font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                        Button("Reset to inherited", action: overrides.reset).buttonStyle(SpaceLinkStyle(tone: .strong, caption: true))
                            .disabled(!overrides.enabled)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).opacity(model.enabled ? 1 : SHMCPMetrics.offOpacity)
            if let inherited {
                HStack(spacing: AppLayout.spaceControlGap) {
                    Button("Override here", action: inherited.overrideHere).buttonStyle(SpaceLinkStyle(tone: .plain)).disabled(!inherited.overrideEnabled)
                    Button(inherited.toggleTitle, action: inherited.toggle).buttonStyle(SpaceLinkStyle(tone: .plain)).disabled(!inherited.toggleEnabled)
                        .help(inherited.toggleHelp)
                }
            } else {
                HStack(spacing: AppLayout.spaceControlGap) {
                    signIn.frame(width: AppLayout.spaceMCPSignInWidth, alignment: .trailing)
                        .opacity(model.enabled ? 1 : SHMCPMetrics.offOpacity)
                    Text(model.tools.map { "\($0) tools" } ?? "—").font(.sh(.caption)).monospacedDigit()
                        .foregroundStyle(Color.sh.textTertiary).frame(width: AppLayout.spaceMCPToolsWidth, alignment: .trailing)
                        .opacity(model.enabled ? 1 : SHMCPMetrics.offOpacity)
                    Toggle(model.name, isOn: Binding(get: { model.enabled }, set: actions.toggle)).toggleStyle(.shSwitch).labelsHidden()
                    SHTurningChevron(isOpen: open).font(.shSans(SHSettingsControlMetrics.popupChevronSize, .semibold))
                        .foregroundStyle(Color.sh.textTertiary).accessibilityHidden(true)
                }
            }
        }
        .padding(.horizontal, AppLayout.spaceRowSides).padding(.vertical, SH.Space.m).frame(minHeight: AppLayout.spaceRowMinHeight)
        .background(inherited == nil && (open || hovering) ? Color.sh.bgHover : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { if inherited == nil { actions.open() } }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(model.name), \(model.status.label)")
        .accessibilityAction(named: open ? "Close" : "Open") { if inherited == nil { actions.open() } }
    }

    @ViewBuilder private var detail: some View {
        switch model.note {
        case .starting(let text): Text(text).font(.sh(.caption)).foregroundStyle(Color.sh.textSecondary).lineLimit(1)
        case .error(let text): Text(text).font(.sh(.caption)).foregroundStyle(Color.sh.failed).lineLimit(1).help(text)
        case nil:
            Text(model.endpoint).font(.shMono(AppLayout.spaceDetailSize)).foregroundStyle(Color.sh.textTertiary)
                .lineLimit(1).truncationMode(.middle).help(model.endpoint)
        }
    }

    /// The sign-in column: a word, a variable's name in mono, or an action.
    @ViewBuilder private var signIn: some View {
        switch model.signIn {
        case .account(let account): value(account)
        case .signIn: Button("Sign in", action: actions.signIn).buttonStyle(SpaceLinkStyle(tone: .strong))
        case .expired:
            HStack(spacing: SH.Space.m) {
                Text("Expired").font(.sh(.caption)).foregroundStyle(Color.sh.lanternText)
                Button("Sign in", action: actions.signIn).buttonStyle(SpaceLinkStyle(tone: .strong))
            }
        case .moreAccess(let scopes):
            HStack(spacing: SH.Space.m) {
                Text(scopes.map { "+" + $0 }.joined(separator: " ")).font(.shMono(AppLayout.spaceDetailSize)).foregroundStyle(Color.sh.lanternText)
                    .lineLimit(1).truncationMode(.tail)
                Button("Sign in again", action: actions.signIn).buttonStyle(SpaceLinkStyle(tone: .strong))
            }
        case .variable(let name), .secret(let name): value(name, mono: true)
        case .variables(let count): value(count == 1 ? "1 variable" : "\(count) variables")
        case .missingSecret(let name): Text("\(name) isn’t set").font(.sh(.caption)).foregroundStyle(Color.sh.lanternText).lineLimit(1)
        case .unverified: value("Not checked")
        case .none: value("None")
        }
    }

    private func value(_ text: String, mono: Bool = false) -> some View {
        Text(text).font(mono ? .shMono(AppLayout.spaceDetailSize) : .sh(.caption)).foregroundStyle(Color.sh.textTertiary)
            .lineLimit(1).truncationMode(.middle)
    }
}

/// A card of servers: a row each, the open one's detail under it.
struct SpaceMCPList: View {
    let rows: [MCPServerRowModel]
    let details: [String: MCPServerDetailModel]
    let editable: Bool
    let expanded: String?
    let rowActions: (String) -> MCPServerRow.Actions
    let detailActions: (String) -> MCPServerDetail.Actions
    var overrides: (String) -> (parent: String, reset: () -> Void, enabled: Bool)? = { _ in nil }
    var inherited: (MCPServerRowModel) -> SpaceMCPRow.Inherited? = { _ in nil }

    var body: some View {
        ForEach(rows) { row in
            let open = expanded == row.id
            VStack(spacing: 0) {
                SpaceMCPRow(model: row, open: open, overrides: overrides(row.name), inherited: inherited(row), actions: rowActions(row.name))
                    .equatable().disabled(!editable && inherited(row) == nil)
                if open, let detail = details[row.name] {
                    SHHairline()
                    MCPServerDetail(detail, actions: detailActions(row.name)).disabled(!editable).shTransition(.disclosure)
                }
            }
        }
    }
}
