import AppKit
import Foundation
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// An activity line's meta, beside a label that takes the room it needs (`NWActivityWords`): all
/// of a short one at every width its label leaves room for, a long one cut at its tail, and none
/// when what is left could not show a few characters of it (a letter cut in half is noise).
@Suite("Activity line meta", .serialized, .mainActorExclusive)
@MainActor
struct ActivityLineWordsTests {
    /// The pixels the line draws that are not the window's background.
    static func ink(label: String, meta: String, width: CGFloat) throws -> Int {
        let window = OffscreenWindow(size: CGSize(width: width, height: 60), dark: false)
        defer { window.close() }
        window.show(NWActivityLine(kind: .run, label: label, meta: meta) {}
            .frame(width: width, height: 60, alignment: .leading)
            .background(Color.nw.bgWindow))
        ListPerf.settle(window)
        let host = window.host
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let background = try #require(bitmap.colorAt(x: bitmap.pixelsWide - 1, y: bitmap.pixelsHigh - 1)?.usingColorSpace(.sRGB))
        var count = 0
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if abs(color.redComponent - background.redComponent) > 0.05 || abs(color.greenComponent - background.greenComponent) > 0.05
                    || abs(color.blueComponent - background.blueComponent) > 0.05 { count += 1 }
            }
        }
        return count
    }

    @Test func aShortMetaIsDrawnWheneverItsLabelLeavesRoomForIt() throws {
        let without = try Self.ink(label: "Ran 3 commands", meta: "", width: 400)
        let with = try Self.ink(label: "Ran 3 commands", meta: "13s", width: 400)
        #expect(with > without + 40, "13s is drawn beside the label: \(with) against \(without)")
    }

    @Test func aMetaTooLongForTheLineIsCutAndStillDrawn() throws {
        let without = try Self.ink(label: "Ran a command", meta: "", width: 260)
        let with = try Self.ink(label: "Ran a command", meta: "swift test --filter ThreadFitTests --no-parallel --skip-build", width: 260)
        #expect(with > without + 100, "the cut meta is drawn: \(with) against \(without)")
    }

    @Test func aMetaThatWouldShowLessThanAFewCharactersIsNotDrawnAtAll() throws {
        let label = "Updated withdrawals-mobile-approve, withdrawals-desktop-approve and withdrawals-claims-details"
        let without = try Self.ink(label: label, meta: "", width: 300)
        let with = try Self.ink(label: label, meta: "edited", width: 300)
        #expect(with == without, "no sliver of the meta beside a label that fills the line: \(with) against \(without)")
    }
}
