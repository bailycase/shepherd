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
        SHSettingsSheet("Join a fleet", subtitle: "On a Mac already in the fleet, open Fleet, then Add a Mac, and enter this code.",
                        width: AppLayout.fleetPairWidth) {
            if let end = model.joinEnd {
                outcome(end)
            } else if let join = model.join {
                FleetJoinCode(join: join)
                if let link = model.pairingLink(for: join) {
                    FleetShareSection(link: link, routes: model.snapshot.routes)
                }
            } else {
                SHSheetParagraph("Opening a code…", style: .small, centered: true)
            }
        } status: {
            if model.joinEnd == nil, let join = model.join, model.pairingLink(for: join) != nil {
                SHSheetStatus("The link stops working when the code expires.")
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
            SHSheetParagraph("Joined. \(name) is in your fleet.", style: .big)
        case .closed:
            SHSheetParagraph("That code is no longer good. It lasts 5 minutes and five wrong tries close it.", centered: true)
        }
    }
}

/// "If that Mac can't find this one": Share link and Copy link, and the routes this Mac says it can be reached at.
struct FleetShareSection: View {
    let link: FleetPairingLink
    /// Shown as "Reachable at", each with its kind; none draws no list.
    var routes: [FleetReportedRoute] = []
    var title = "If that Mac can’t find this one"
    var detail = "Send it a pairing link. It carries where to reach this Mac and the code, and works on any network the two Macs share: another VLAN, a VPN or Tailscale."
    @State private var copied = false

    var body: some View {
        let sh = Color.sh
        let url = link.url()
        Group {
            SHSheetRule()
            SHSheetHeading(title)
            SHSheetParagraph(detail).shSheetTight()
            HStack(spacing: SHSettingsSheetMetrics.rowGap) {
                ShareLink(item: url) { Text("Share link") }
                    .buttonStyle(.sh(.secondary))
                Button(copied ? "Copied" : "Copy link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    copied = true
                }
                .buttonStyle(.sh(.secondary))
                .onChange(of: link) { copied = false }
            }
            if !routes.isEmpty {
                VStack(alignment: .leading, spacing: SH.Space.s) {
                    Text("Reachable at").font(.shSans(SHSettingsSheetMetrics.smallSize)).foregroundStyle(sh.textTertiary)
                    ForEach(routes, id: \.self) { route in
                        HStack(spacing: SH.Space.m) {
                            Text(route.host).font(.shMono(SHSettingsSheetMetrics.smallSize)).foregroundStyle(sh.textPrimary).textSelection(.enabled)
                            Spacer(minLength: SH.Space.m)
                            Text(route.kind.label).font(.shSans(SHSettingsSheetMetrics.smallSize)).foregroundStyle(sh.textTertiary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
}

/// The code in two groups of three, and how long it has left.
struct FleetJoinCode: View {
    let join: FleetSettingsModel.Join
    /// What follows how long the code has left.
    var note = "this Mac’s settings are replaced by the fleet’s"

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
        Text(Self.grouped(join.code))
            .font(.shMono(AppLayout.fleetJoinCodeSize, .semibold))
            .tracking(AppLayout.fleetJoinCodeTracking)
            .foregroundStyle(sh.textPrimary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Pairing code \(join.code.map(String.init).joined(separator: " "))")
        TimelineView(.periodic(from: .now, by: 1)) { context in
            SHSheetParagraph("Expires in \(Self.remaining(until: join.expiresAt, now: context.date)) · \(note)", style: .small, centered: true)
        }
        .shSheetTight()
    }
}
