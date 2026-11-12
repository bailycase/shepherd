import AppKit
import Foundation
import Testing
@testable import ShepherdUI

/// `NSTextField` reports no intrinsic size (-1) for a side past 40,000 pt, which left a fence of
/// about 2,050 lines (or a line of about 5,400 characters) with a 1 pt field and nothing drawn.
@Suite("Code fence measurement")
@MainActor
struct CodeFenceMeasureTests {
    private static let font = NSFont.monospacedSystemFont(ofSize: SHTextStyle.code.size, weight: .regular)
    private static let lineSpacing = SHTextStyle.code.lineSpacing + 0.6

    /// A field set up as `SHNativeCodeText.makeNSView` does, holding `code`.
    private static func field(_ code: String, font: NSFont = font) -> SHNativeCodeText.Field {
        let field = SHNativeCodeText.Field(labelWithString: "")
        field.isSelectable = true
        field.allowsEditingTextAttributes = true
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byClipping
        field.cell?.wraps = false
        field.cell?.isScrollable = false
        field.font = font
        field.setCode(SHNativeCodeText.attributedCode(code, highlighted: nil, font: font, lineSpacing: lineSpacing))
        return field
    }

    nonisolated private static func fence(_ lines: Int) -> String {
        (0..<lines).map { "let item\($0) = compute(\($0), from: sheep)" }.joined(separator: "\n")
    }

    @Test func aFenceTallerThanTheTextFieldsLimitStillGrowsWithItsLines() {
        let small = Self.field(Self.fence(100)).intrinsicContentSize
        let large = Self.field(Self.fence(1_000)).intrinsicContentSize
        let perLine = (large.height - small.height) / 900
        var previous = large.height
        for lines in [1_500, 2_000, 2_100, 3_000] {
            let size = Self.field(Self.fence(lines)).intrinsicContentSize
            #expect(size.width > 0 && size.width.isFinite, "\(lines) lines")
            #expect(size.height.isFinite && size.height > previous, "\(lines) lines must be taller than fewer lines, was \(size.height)")
            let expected = small.height + perLine * CGFloat(lines - 100)
            #expect(abs(size.height - expected) <= 2, "\(lines) lines are \(size.height) pt, a line is \(perLine) pt, expected \(expected)")
            previous = size.height
        }
    }

    /// A block the field measures itself keeps that size, so only a block it cannot measure gets the other.
    @Test(arguments: [
        "", "x", "let sheep = 1", "a\nb", "a\n\nb\n", "\tindent\n\t\tmore", "let sheep = \"🐑 e\u{301}\" // שלום\nx",
        String(repeating: "x", count: 3_000), CodeFenceMeasureTests.fence(1_500),
    ], [12.0])
    func theUnboundedMeasureAgreesWithTheFieldsOwnBelowItsLimit(code: String, points: CGFloat) {
        let field = Self.field(code, font: .monospacedSystemFont(ofSize: points, weight: .regular))
        #expect(field.unboundedContentSize == field.intrinsicContentSize, "\(code.count) characters at \(points) pt")
    }

    @Test func aLineWiderThanTheTextFieldsLimitStillHasAWidth() {
        let narrow = Self.field(String(repeating: "x", count: 1_000)).intrinsicContentSize
        let wide = Self.field(String(repeating: "x", count: 6_000)).intrinsicContentSize
        #expect(narrow.width > 0)
        #expect(wide.width > 5 * narrow.width && wide.width.isFinite, "6,000 characters are \(wide.width) pt wide")
        #expect(wide.height == narrow.height)
    }
}
