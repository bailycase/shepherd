import Testing
@testable import ShepherdUI

@Suite("HexColor")
struct HexColorTests {
    static let parsed: [(String, Double, Double, Double)] = [
        ("#FF8000", 1, 128 / 255, 0), ("ff8000", 1, 128 / 255, 0), ("#000000", 0, 0, 0),
        ("#aBcDeF", 0xAB / 255, 0xCD / 255, 0xEF / 255),
    ]

    @Test(arguments: parsed)
    func parsesSixDigitHexWithOrWithoutHash(_ string: String, red: Double, green: Double, blue: Double) throws {
        let color = try #require(HexColor(string))
        #expect(color.red == red && color.green == green && color.blue == blue)
        #expect(color.alpha == 1 && color.isOpaque)
    }

    @Test func eightDigitsCarryAlphaInTheLastByte() throws {
        let color = try #require(HexColor("#FFFFFF14"))
        #expect(color.red == 1 && color.green == 1 && color.blue == 1)
        #expect(color.alpha == Double(0x14) / 255)
        #expect(!color.isOpaque)
    }

    @Test(arguments: ["", "#", "#FFF", "#12345", "#1234567", "#123456789", "#GGGGGG", "blue", "##123456", "#12 456"])
    func rejectsAnythingButSixOrEightHexDigits(_ string: String) {
        #expect(HexColor(string) == nil)
    }

    /// `UInt64(_:radix:)` accepts a leading sign; a six-character "+FFFFF" must not parse.
    @Test func rejectsASignPrefix() {
        #expect(HexColor("#+FFFFF") == nil)
        #expect(HexColor("-00000") == nil)
    }

    @Test(arguments: ["#0a0b0c", "#ffffff0b", "#f2a93b21"])
    func hexStringRoundTrips(_ string: String) {
        #expect(HexColor(string)?.hexString == string)
    }

    @Test func compositingPaintsTheColorOverTheBackground() {
        let white = HexColor("#FFFFFF")!, black = HexColor("#000000")!
        let half = HexColor(red: 1, green: 1, blue: 1, alpha: 0.5)
        let painted = half.composited(over: black)
        #expect(painted.isOpaque && abs(painted.red - 0.5) < 1e-12)
        #expect(white.composited(over: black) == white)
    }

    @Test func luminanceSpansZeroToOne() {
        #expect(HexColor("#000000")!.luminance == 0)
        #expect(abs(HexColor("#FFFFFF")!.luminance - 1) < 1e-12)
    }

    @Test func blackOnWhiteIsTheMaximumRatio() {
        #expect(abs(HexColor("#000000")!.contrast(with: HexColor("#FFFFFF")!) - 21) < 1e-9)
    }

    @Test func contrastIsSymmetricAndOneForIdenticalColors() {
        let a = HexColor("#3366CC")!, b = HexColor("#F0E0D0")!
        #expect(a.contrast(with: b) == b.contrast(with: a))
        #expect(a.contrast(with: a) == 1)
    }

    /// Reference values from the WCAG 2 formula: #767676 is the lightest grey that passes AA
    /// on white, #777777 the first that fails.
    @Test func matchesKnownWCAGReferenceValues() {
        let white = HexColor("#FFFFFF")!
        #expect(HexColor("#767676")!.contrast(with: white) >= 4.5)
        #expect(HexColor("#777777")!.contrast(with: white) < 4.5)
    }
}
