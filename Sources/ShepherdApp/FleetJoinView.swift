import SwiftUI
import ShepherdUI
import ShepherdProtocol

/// Join a fleet (FleetStates, FleetPairAnywhere): the code another Mac in the fleet enters under Add a Mac, and for a Mac that can't
/// find this one, a pairing link to send it and every route this Mac can be reached by.
/// The code works only while this sheet is open: closing it closes the window on the host.
struct FleetJoinView: View {
    var model: FleetSettingsModel
    let dismiss: () -> Void

    var body: some View {
        SHDialog("Join a fleet", message: "On a Mac already in your fleet, open Settings ▸ Fleet ▸ Add a Mac and enter this code.",
                 width: AppLayout.fleetPairWidth) {
            VStack(spacing: 0) {
                VStack(spacing: SH.Space.l) {
                    if let end = model.joinEnd {
                        outcome(end)
                    } else if let join = model.join {
                        FleetJoinCode(join: join)
                    } else {
                        Text("Opening a code…").font(.sh(.ui)).foregroundStyle(Color.sh.textTertiary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, SHDialogMetrics.inset)
                .padding(.bottom, SH.Space.l)
                if model.joinEnd == nil, let join = model.join, let link = model.pairingLink(for: join) {
                    SHHairline()
                    FleetShareSection(link: link, routes: model.snapshot.routes)
                }
            }
        } status: {
            if model.joinEnd == nil, let join = model.join, model.pairingLink(for: join) != nil {
                SHDialogStatus("The link stops working when the code expires.")
            }
        } actions: {
            if model.joinEnd == .closed {
                Button("New code") { Task { await model.startJoin() } }.buttonStyle(.sh(.secondary))
            }
            Button(model.joinEnd == nil ? "Cancel" : "Done") { dismiss() }
                .buttonStyle(.sh(model.joinEnd == nil ? .ghost : .primary)).keyboardShortcut(.cancelAction)
        }
        .task { await model.startJoin() }
        .onDisappear { Task { await model.stopJoin() } }
    }

    @ViewBuilder private func outcome(_ end: FleetSettingsModel.JoinEnd) -> some View {
        switch end {
        case .joined(let name):
            Text("Joined. \(name) is in your fleet.").font(.sh(.body, weight: .medium)).foregroundStyle(Color.sh.done)
        case .closed:
            Text("That code is no longer good. It lasts 5 minutes and five wrong tries close it.")
                .font(.sh(.ui)).foregroundStyle(Color.sh.textSecondary)
                .multilineTextAlignment(.center)
        }
    }
}

/// "If that Mac can't find this one": Share link and Copy link, and the routes this Mac says it can be reached at.
struct FleetShareSection: View {
    let link: FleetPairingLink
    /// Shown as "Reachable at", each with its kind; none draws no list.
    var routes: [FleetReportedRoute] = []
    var title = "If that Mac can't find this one"
    var detail = "Send it a pairing link. It carries where to reach this Mac and the code, and works on any network the two Macs share: another VLAN, a VPN or Tailscale."
    @State private var copied = false

    var body: some View {
        let sh = Color.sh
        let url = link.url()
        VStack(alignment: .leading, spacing: SH.Space.m) {
            Text(title).shSectionLabel()
            Text(detail)
                .font(.sh(.ui))
                .foregroundStyle(sh.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: SH.Space.s) {
                ShareLink(item: url) {
                    Label("Share link", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.sh(.secondary))
                Button(copied ? "Copied" : "Copy link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    copied = true
                }
                .buttonStyle(.sh(.secondary))
            }
            if !routes.isEmpty {
                Text("Reachable at").font(.sh(.caption)).foregroundStyle(sh.textTertiary)
                ForEach(routes, id: \.self) { route in
                    HStack(spacing: SH.Space.m) {
                        Text(route.host).font(.sh(.mono)).foregroundStyle(sh.textPrimary).textSelection(.enabled)
                        Spacer(minLength: SH.Space.m)
                        Text(route.kind.label).font(.sh(.caption)).foregroundStyle(sh.textTertiary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: SH.Space.l, leading: SHDialogMetrics.inset, bottom: SH.Space.l, trailing: SHDialogMetrics.inset))
        .onChange(of: link) { copied = false }
    }
}

/// The code in two groups of three, and how long it has left.
struct FleetJoinCode: View {
    let join: FleetSettingsModel.Join
    /// What follows how long the code has left.
    var note = "this Mac's settings are replaced by the fleet's"

    /// "482 913".
    static func grouped(_ code: String) -> String {
        guard code.count == FleetProtocol.codeLength else { return code }
        let half = code.index(code.startIndex, offsetBy: FleetProtocol.codeLength / 2)
        return "\(code[..<half]) \(code[half...])"
    }

    /// "4:12".
    static func remaining(until end: Date, now: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(now).rounded(.up)))
        return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }

    var body: some View {
        let sh = Color.sh
        VStack(spacing: SH.Space.m) {
            Text(Self.grouped(join.code))
                .font(.shMono(AppLayout.fleetJoinCodeSize, .medium))
                .foregroundStyle(sh.textPrimary)
                .textSelection(.enabled)
                .accessibilityLabel("Pairing code \(join.code.map(String.init).joined(separator: " "))")
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("Expires in \(Self.remaining(until: join.expiresAt, now: context.date)) · \(note)")
                    .font(.sh(.caption))
                    .foregroundStyle(sh.textTertiary)
            }
        }
    }
}
