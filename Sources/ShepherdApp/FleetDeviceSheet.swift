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
        SHSettingsSheet("Add a device", subtitle: "On your iPhone or iPad, open Shepherd and Add a Mac. Enter the code, or scan this on a phone.",
                        width: AppLayout.fleetJoinWidth) {
            if let end = model.deviceCodeEnd {
                outcome(end)
            } else if let join = model.deviceCode {
                FleetQRCode(link: FleetProtocol.pairLink(code: join.code, advertisedID: model.snapshot.hostID.map(FleetProtocol.advertisedIDHash) ?? ""))
                    .frame(maxWidth: .infinity)
                FleetJoinCode(join: join, note: "the device connects as a client and holds no sign-ins")
                SHSheetParagraph("Both need to be on the same local network as this Mac.", style: .small, centered: true).shSheetTight()
                if let link = model.pairingLink(for: join, purpose: .device) {
                    FleetShareSection(link: link, title: "If the device can’t find this Mac",
                                      detail: "Send it a pairing link. On an iPhone or iPad it opens Add a Mac with this Mac and its code filled in, on any network the two share.")
                }
            } else {
                SHSheetParagraph("Opening a code…", style: .small, centered: true)
            }
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
            SHSheetParagraph("Added. \(name) is paired with your fleet.", style: .big)
            SHSheetParagraph("It reads and sends on every Mac in the fleet, and holds no sign-ins. Revoke it any time in Phones and tablets.")
                .shSheetTight()
        case .closed:
            SHSheetParagraph("That code is no longer good. It lasts 5 minutes and five wrong tries close it.", centered: true)
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
                Image(decorative: image, scale: Self.pixelsPerPoint)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: CGFloat(image.width) / Self.pixelsPerPoint, height: CGFloat(image.height) / Self.pixelsPerPoint)
            }
        }
        .padding(AppLayout.fleetQRPadding)
        .background(Color.white, in: RoundedRectangle(cornerRadius: AppLayout.fleetQRRadius))
        .overlay { RoundedRectangle(cornerRadius: AppLayout.fleetQRRadius).strokeBorder(Color.sh.lineStrong, lineWidth: SHSettingsNavMetrics.borderWidth) }
        .accessibilityLabel("QR code of the pairing code")
    }

    /// Drawn for a Retina screen: a module is a whole number of pixels, so a module may be half a point.
    static let pixelsPerPoint: CGFloat = 2

    /// The QR as pixels, sized to a whole number of pixels per module.
    static func image(of text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let code = filter.outputImage else { return nil }
        let quiet: CGFloat = 0
        let canvas = code.extent.insetBy(dx: -quiet, dy: -quiet)
        let scale = (AppLayout.fleetQRSize * pixelsPerPoint / canvas.width).rounded(.down).clamped(min: 1)
        let page = CIImage(color: .white).cropped(to: canvas)
        let composed = code.composited(over: page).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return CIContext().createCGImage(composed, from: composed.extent)
    }
}

private extension CGFloat {
    func clamped(min lower: CGFloat) -> CGFloat { Swift.max(self, lower) }
}
