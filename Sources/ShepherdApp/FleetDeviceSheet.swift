import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import ShepherdUI
import ShepherdProtocol

/// Add a device: the code a phone or iPad enters on its Add a Mac screen, and the QR of the same code
/// for a phone to scan. The code works only while this sheet is open: closing it closes the window on the
/// host. The device pairs as a client: it reads and sends on every Mac of the fleet and holds no sign-ins.
struct FleetDeviceSheet: View {
    var model: FleetSettingsModel
    let dismiss: () -> Void

    var body: some View {
        SHDialog("Add a device", message: "On your iPhone or iPad, open Shepherd and Add a Mac. Enter the code, or scan this on a phone.",
                 width: AppLayout.fleetJoinWidth) {
            VStack(spacing: SH.Space.l) {
                if let end = model.deviceCodeEnd {
                    outcome(end)
                } else if let join = model.deviceCode {
                    FleetQRCode(link: FleetProtocol.pairLink(code: join.code, advertisedID: model.snapshot.hostID.map(FleetProtocol.advertisedIDHash) ?? ""))
                    FleetJoinCode(join: join, note: "the device connects as a client and holds no sign-ins")
                    Text("Both need to be on the same local network as this Mac.")
                        .font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                } else {
                    Text("Opening a code…").font(.sh(.ui)).foregroundStyle(Color.sh.textTertiary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, SHDialogMetrics.inset)
            .padding(.vertical, SH.Space.l)
        } actions: {
            if model.deviceCodeEnd == .closed {
                Button("New code") { Task { await model.startDeviceCode() } }.buttonStyle(.sh(.secondary))
            }
            Button(model.deviceCodeEnd == nil ? "Cancel" : "Done") { dismiss() }
                .buttonStyle(.sh(model.deviceCodeEnd == nil ? .ghost : .primary)).keyboardShortcut(.cancelAction)
        }
        .task { await model.startDeviceCode() }
        .onDisappear { Task { await model.stopDeviceCode() } }
    }

    @ViewBuilder private func outcome(_ end: FleetSettingsModel.DeviceCodeEnd) -> some View {
        switch end {
        case .added(let name):
            Text("Added. \(name) is paired with your fleet.").font(.sh(.body, weight: .medium)).foregroundStyle(Color.sh.done)
        case .closed:
            Text("That code is no longer good. It lasts 5 minutes and five wrong tries close it.")
                .font(.sh(.ui)).foregroundStyle(Color.sh.textSecondary)
                .multilineTextAlignment(.center)
        }
    }
}

/// A QR code of `link`: dark modules on a light quiet zone (a scanner needs that contrast in either
/// appearance, so the image carries its own colors).
struct FleetQRCode: View {
    let link: String

    var body: some View {
        Group {
            if let image = Self.image(of: link) {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: CGFloat(image.width), height: CGFloat(image.height))
                    .clipShape(RoundedRectangle(cornerRadius: SH.Radius.m))
            }
        }
        .accessibilityLabel("QR code of the pairing code")
    }

    /// The QR as pixels, sized to a whole number of points per module with a four module quiet zone.
    static func image(of text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let code = filter.outputImage else { return nil }
        let quiet: CGFloat = 4
        let canvas = code.extent.insetBy(dx: -quiet, dy: -quiet)
        let scale = (AppLayout.fleetQRSize / canvas.width).rounded(.down).clamped(min: 1)
        let page = CIImage(color: .white).cropped(to: canvas)
        let composed = code.composited(over: page).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return CIContext().createCGImage(composed, from: composed.extent)
    }
}

private extension CGFloat {
    func clamped(min lower: CGFloat) -> CGFloat { Swift.max(self, lower) }
}
