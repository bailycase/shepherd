import SwiftUI
import UIKit
import VisionKit
import ShepherdUI

/// The camera, reading the QR that Settings ▸ Fleet ▸ Add a device shows on a Mac. It hands back the
/// first QR it reads and the caller decides whether it is a pairing code.
struct PairScanner: View {
    let found: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    /// This device has a camera that can scan (a simulator does not).
    static var isAvailable: Bool { DataScannerViewController.isSupported && DataScannerViewController.isAvailable }

    var body: some View {
        NavigationStack {
            Scanner { text in
                found(text)
                dismiss()
            }
            .ignoresSafeArea()
            .navigationTitle("Scan the code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private struct Scanner: UIViewControllerRepresentable {
        let found: (String) -> Void

        func makeUIViewController(context: Context) -> DataScannerViewController {
            let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
                                                    recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false,
                                                    isHighlightingEnabled: true)
            scanner.delegate = context.coordinator
            try? scanner.startScanning()
            return scanner
        }

        func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {}

        func makeCoordinator() -> Coordinator { Coordinator(found: found) }

        final class Coordinator: NSObject, DataScannerViewControllerDelegate {
            let found: (String) -> Void
            private var done = false
            init(found: @escaping (String) -> Void) { self.found = found }

            func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
                guard !done else { return }
                for case .barcode(let barcode) in items {
                    if let text = barcode.payloadStringValue {
                        done = true
                        found(text)
                        return
                    }
                }
            }
        }
    }
}
