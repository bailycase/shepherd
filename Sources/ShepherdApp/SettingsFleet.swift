import SwiftUI
import ShepherdUI
import ShepherdProtocol

/// Settings ▸ Fleet (FleetSettings): the Macs paired with this one, and the two ways to add one.
/// Only the parts that exist yet: sync, dispatch and code rows arrive with the slices that build them.
struct FleetSettings: View {
    var model: FleetSettingsModel
    /// Agents keep running (and Fleet keeps its links) with Shepherd quit: the background service
    /// runs the host. False or unknown: the host is the app's own child, and Fleet stops at Quit.
    var serviceKeepsRunning: Bool?

    @State private var adding = false
    @State private var joining = false
    @State private var removing: FleetMacRow?

    static let explanation = "Your Macs work as one. Settings, instructions, skills, extensions, MCP servers and sign-ins are the same on every Mac, and any Mac can take a thread. Changes sync on their own, including each save in a linked extension folder."
    /// FleetSettings' footer, reworded: Shepherd adds no TLS, so the fleet runs over the person's own network.
    static let footnote = "Macs pair once with a code shown on the other Mac. Shepherd doesn't encrypt fleet traffic. Run the fleet over your own network: a LAN, Tailscale or a VPN."
    static let stopsAtQuit = "The background service is off, so Fleet stops when you quit Shepherd. Turn it on in System Settings ▸ General ▸ Login Items."

    var body: some View {
        SettingsPage(title: "Fleet", explanation: Self.explanation) {
            SettingsGroup(title: "Macs", footnote: serviceKeepsRunning == true ? Self.footnote : Self.footnote + " " + Self.stopsAtQuit) {
                ForEach(model.rows) { row in
                    FleetMacRowView(row: row) { removing = row }
                        .shTransition(.list)
                }
                if let problem = model.problem {
                    SettingsActionRow(leading: { SHInlineProblem(problem) }, actions: { EmptyView() })
                        .shTransition(.disclosure)
                } else if model.loaded, model.snapshot.port == nil {
                    SettingsActionRow(leading: { SHInlineProblem("This Mac isn't serving, so no other Mac can reach it. Check Settings ▸ Remote.") },
                                      actions: { EmptyView() })
                        .shTransition(.disclosure)
                }
                SettingsActionRow {
                    Button("Join a fleet…") { joining = true }
                        .buttonStyle(.sh(.secondary))
                        .disabled(!model.loaded || model.snapshot.port == nil)
                    Button("Add a Mac…") { model.openPairing(); adding = true }
                        .buttonStyle(.sh(.secondary))
                        .disabled(!model.loaded || model.snapshot.port == nil)
                }
            }
        }
        .shAnimation(.list, value: model.rows.map(\.id))
        .shAnimation(.disclosure, value: model.problem)
        .task { await model.refresh() }
        .sheet(isPresented: $adding) {
            FleetPairSheet(model: model) { adding = false }
        }
        .sheet(isPresented: $joining) {
            FleetJoinView(model: model) { joining = false }
        }
        .sheet(item: $removing) { row in
            DialogSheet(
                title: "Remove \(row.title) from the fleet?",
                subtitle: "Every Mac in the fleet drops it. It keeps what it already has here. Pair it again with a code to bring it back.",
                actions: [
                    DialogAction("Cancel", kind: .cancel) { removing = nil },
                    DialogAction("Remove", kind: .destructive) {
                        removing = nil
                        if let hostID = row.hostID { Task { await model.remove(hostID) } }
                    },
                ])
        }
    }
}

/// One Mac of the list: its dot, its name over where it is, and Remove for the Macs paired with this one.
struct FleetMacRowView: View {
    let row: FleetMacRow
    let remove: () -> Void

    var body: some View {
        SettingsActionRow {
            HStack(spacing: SH.Space.l) {
                dot
                VStack(alignment: .leading, spacing: SH.Space.xxs) {
                    Text(row.title)
                        .font(.sh(.body, weight: .medium))
                        .foregroundStyle(Color.sh.textPrimary)
                    Text(row.detail)
                        .font(.sh(.ui))
                        .foregroundStyle(Color.sh.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .accessibilityElement(children: .combine)
        } actions: {
            if row.hostID != nil {
                Button("Remove", action: remove)
                    .buttonStyle(.sh(.secondary))
                    .accessibilityLabel("Remove \(row.title)")
            }
        }
    }

    @ViewBuilder private var dot: some View {
        switch row.state {
        case .thisMac: SHStatusDot(.done, size: AppLayout.fleetDotSize, color: Color.sh.lantern)
        case .connected: SHStatusDot(.done, size: AppLayout.fleetDotSize)
        case .connecting: SHStatusDot(.running, size: AppLayout.fleetDotSize)
        case .offline: SHStatusDot(.idle, size: AppLayout.fleetDotSize)
        }
    }
}

/// Settings ▸ Experiments ▸ Fleet's card (no board draws it: the others' pattern).
struct FleetExperimentCard: View {
    @Bindable var settings: AppSettings

    var body: some View {
        let sh = Color.sh
        HStack(alignment: .top, spacing: SH.Space.l + SH.Space.xxs) {
            RoundedRectangle(cornerRadius: SH.Radius.m)
                .fill(sh.lanternTint)
                .frame(width: AppLayout.experimentTileSize, height: AppLayout.experimentTileSize)
                .overlay {
                    SHGlyph.Settings.remoteConnection.image
                        .foregroundStyle(sh.lanternText)
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text("Fleet")
                    .font(.shSans(AppLayout.experimentNameSize, .semibold))
                    .foregroundStyle(sh.textPrimary)
                Text("Pair your Macs with a code and keep their background services linked. Adds Fleet to Settings. "
                     + "Turning this off ends the links and keeps the Macs you paired.")
                    .shText(size: AppLayout.experimentDescriptionSize, lineHeight: AppLayout.experimentDescriptionLineHeight)
                    .foregroundStyle(sh.textSecondary)
                    .frame(maxWidth: AppLayout.experimentDescriptionWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: SH.Space.xxl)
            SettingsSwitch(label: "Fleet", isOn: $settings.fleetEnabled)
        }
        .padding(.vertical, SH.Space.l + SH.Space.xxs)
        .padding(.horizontal, SH.Space.xl)
        .shCard(fill: sh.bgWindow, line: sh.lineStrong)
    }
}
