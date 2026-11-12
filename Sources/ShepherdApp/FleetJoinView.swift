import SwiftUI
import ShepherdUI
import ShepherdProtocol

/// Join a fleet (FleetStates): the code another Mac in the fleet enters under Add a Mac, and this
/// Mac's address under it, for telling a Mac that can't be found from one that can't be reached.
/// The code works only while this sheet is open: closing it closes the window on the host.
struct FleetJoinView: View {
    var model: FleetSettingsModel
    let dismiss: () -> Void

    var body: some View {
        SHDialog("Join a fleet", message: "On a Mac already in the fleet, open Settings ▸ Fleet ▸ Add a Mac and enter:",
                 width: AppLayout.fleetJoinWidth) {
            VStack(spacing: SH.Space.l) {
                if let end = model.joinEnd {
                    outcome(end)
                } else if let join = model.join {
                    FleetJoinCode(join: join)
                    address
                } else {
                    Text("Opening a code…").font(.sh(.ui)).foregroundStyle(Color.sh.textTertiary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, SHDialogMetrics.inset)
            .padding(.vertical, SH.Space.l)
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

    /// Where this Mac is, for the person at the other one.
    @ViewBuilder private var address: some View {
        let snapshot = model.snapshot
        if let host = snapshot.addresses.first {
            Text("Not listed on the other Mac? This Mac is at \(host)\(snapshot.port.map { ", port \($0)" } ?? ""). Both Macs need to be on the same local network for it to show up.")
                .font(.sh(.caption))
                .foregroundStyle(Color.sh.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
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

/// The code in two groups of three, and how long it has left.
struct FleetJoinCode: View {
    let join: FleetSettingsModel.Join

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
                Text("Expires in \(Self.remaining(until: join.expiresAt, now: context.date)) · this Mac's settings are replaced by the fleet's")
                    .font(.sh(.caption))
                    .foregroundStyle(sh.textTertiary)
            }
        }
    }
}
