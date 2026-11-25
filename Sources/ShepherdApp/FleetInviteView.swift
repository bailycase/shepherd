import SwiftUI
import ShepherdRemote
import ShepherdUI

/// A Mac alone in its fleet (FleetEmpty): what a fleet is for, the Macs found on this network with an Add each, and the other ways in.
struct FleetInviteView: View {
    let found: [FoundMac]
    let actions: FleetPageActions

    var body: some View {
        let sh = Color.sh
        VStack(spacing: SH.Space.l) {
            Image(systemName: "desktopcomputer")
                .font(.sh(.display, weight: .regular))
                .foregroundStyle(sh.textPrimary)
                .frame(width: AppLayout.fleetInviteTile, height: AppLayout.fleetInviteTile)
                .background(sh.bgSelected, in: RoundedRectangle(cornerRadius: SH.Radius.xl))
                .accessibilityHidden(true)
            Text("Only This Mac so far")
                .font(.shSans(AppLayout.fleetInviteTitle, .semibold))
                .foregroundStyle(sh.textPrimary)
                .padding(.top, SH.Space.m)
                .accessibilityAddTraits(.isHeader)
            Text("Add your other Macs and new threads go to whichever has room. Each keeps its own folders and sign-ins, and work it does comes back to the thread that sent it.")
                .font(.sh(.ui, weight: .regular))
                .foregroundStyle(sh.textSecondary)
                .lineSpacing(AppLayout.fleetProseSpacing)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if !found.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text("On this network")
                        .font(.sh(.caption, weight: .regular))
                        .foregroundStyle(sh.textTertiary)
                        .padding(.horizontal, AppLayout.fleetRowInset)
                        .padding(.top, SH.Space.m)
                        .padding(.bottom, SH.Space.xs)
                    ForEach(found) { mac in
                        FleetFoundMacRow(mac: mac) { actions.addFound(mac) }
                    }
                }
                .padding(SH.Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .shCard(radius: SH.Radius.xl, fill: sh.bgRaised, line: sh.lineStrong, lift: true)
                .padding(.top, SH.Space.l)
            }
            HStack(spacing: SH.Space.xxl) {
                Button("Add over SSH…", action: actions.addOverSSH).buttonStyle(.shTextAction)
                Button("Join with a code…", action: actions.joinWithCode).buttonStyle(.shTextAction)
            }
            .padding(.top, SH.Space.xs)
        }
        .frame(width: AppLayout.fleetInviteWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A Mac found on this network: its glyph, its name over its address, and Add.
private struct FleetFoundMacRow: View {
    let mac: FoundMac
    let add: () -> Void

    var body: some View {
        let sh = Color.sh
        HStack(spacing: SH.Space.l) {
            Image(systemName: "desktopcomputer")
                .font(.sh(.ui, weight: .regular))
                .foregroundStyle(sh.textSecondary)
                .frame(width: AppLayout.fleetRowGlyph)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SH.Space.xxs / 2) {
                Text(mac.name).font(.sh(.ui, weight: .medium)).foregroundStyle(sh.textPrimary).lineLimit(1)
                Text([mac.address, mac.version.map { "Shepherd \($0)" }].compactMap { $0 }.joined(separator: ", "))
                    .font(.sh(.caption, weight: .regular)).foregroundStyle(sh.textTertiary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Add", action: add)
                .buttonStyle(.shTextAction)
                .accessibilityLabel("Add \(mac.name)")
        }
        .padding(.horizontal, AppLayout.fleetRowInset)
        .padding(.vertical, SH.Space.s)
        .frame(minHeight: AppLayout.fleetRowHeight)
        .accessibilityElement(children: .contain)
    }
}
