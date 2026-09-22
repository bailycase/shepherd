import Testing
@testable import ShepherdDesign

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
    }

    @Test(arguments: ["", "#", "#FFF", "#12345", "#1234567", "#GGGGGG", "blue", "##123456", "#12 456"])
    func rejectsAnythingButSixHexDigits(_ string: String) {
        #expect(HexColor(string) == nil)
    }

    /// `UInt32(_:radix:)` accepts a leading sign; a six-character "+FFFFF" must not parse.
    @Test func rejectsASignPrefix() {
        #expect(HexColor("#+FFFFF") == nil)
        #expect(HexColor("-00000") == nil)
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
