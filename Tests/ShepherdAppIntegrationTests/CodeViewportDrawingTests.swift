import AppKit
import SwiftUI
import Testing
import ShepherdTestSupport
@testable import ShepherdUI

@Suite("Code viewport drawing", .mainActorExclusive)
@MainActor
struct CodeViewportDrawingTests {
    @Test(arguments: [false, true], [false, true])
    func rendererTracksTextSyntaxScaleAndSelection(dark: Bool, unicode: Bool) throws {
        let field = NWNativeCodeText.Field(labelWithString: "")
        let window = OffscreenWindow(size: CGSize(width: 520, height: 320), dark: dark)
        defer { window.close() }
        let scroll = mount(field, in: window)
        let suffix = unicode ? "\"🐑 e\u{301}\"" : "\"flock\""
        let code = (0..<500).map { "let sheep\($0) = \(suffix)" }.joined(separator: "\n")
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        field.font = font
        var highlighted = AttributedString(code)
        highlighted.foregroundColor = Color.nw.synKeyword
        field.setCode(NWNativeCodeText.attributedCode(code, highlighted: highlighted, font: font, lineSpacing: 4))
        size(field, in: scroll)
        let before = try render(field, scroll: scroll, fraction: 0.5)
        highlighted.foregroundColor = Color.nw.synString
        field.setCode(NWNativeCodeText.attributedCode(code, highlighted: highlighted, font: font, lineSpacing: 4))
        let syntax = try render(field, scroll: scroll, fraction: 0.5)
        #expect(before != syntax, "changing syntax colors must update already-created native glyph layout")
        let changed = code.replacingOccurrences(of: "sheep", with: "flock")
        field.setCode(NWNativeCodeText.attributedCode(changed, highlighted: nil, font: font, lineSpacing: 4))
        let edited = try render(field, scroll: scroll, fraction: 0.5)
        #expect(syntax != edited)
        let editor = try #require(window.window.fieldEditor(true, for: field) as? NSTextView)
        field.cell?.select(withFrame: field.bounds, in: field, editor: editor, delegate: field, start: 4, length: 5)
        #expect(window.window.makeFirstResponder(editor))
        #expect(field.currentEditor() === editor)
        #expect((editor.string as NSString).substring(with: editor.selectedRange()) == "flock")
        // During selection the shared field editor owns the text pixels, not field.draw(_:) itself.
        scroll.contentView.scroll(to: CGPoint(x: 0, y: field.bounds.height / 2))
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(editor.string == changed)
        #expect(editor.selectedRange() == NSRange(location: 4, length: 5))
        #expect(window.window.makeFirstResponder(nil))
        #expect(try render(field, scroll: scroll, fraction: 0.5) == edited,
                "ending a native selection must return to the same unselected drawing")
        let initialHeight = field.frame.height
        field.setCode(NWNativeCodeText.attributedCode(changed, highlighted: nil,
                      font: .monospacedSystemFont(ofSize: 18, weight: .regular), lineSpacing: 4))
        size(field, in: scroll)
        #expect(field.frame.height > initialHeight)
        #expect(try render(field, scroll: scroll, fraction: 0.5) != edited)
    }

    @Test(arguments: [false, true], [false, true])
    func assigningTheFontBeforeCodeUpdatesRetainedGlyphs(dark: Bool, nativeAssignment: Bool) throws {
        let window = OffscreenWindow(size: CGSize(width: 520, height: 320), dark: dark)
        defer { window.close() }
        let field = NWNativeCodeText.Field(labelWithString: "")
        let scroll = mount(field, in: window)
        let code = (0..<50).map { "let value\($0) = \($0)" }.joined(separator: "\n")
        let originalFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        field.font = originalFont
        field.setCode(NWNativeCodeText.attributedCode(code, highlighted: nil, font: originalFont, lineSpacing: 4))
        size(field, in: scroll)
        _ = try render(field, scroll: scroll, fraction: 0.5) // Instantiate retained glyph layout.

        for points in [18.0, 12.0] {
            let font = NSFont.monospacedSystemFont(ofSize: points, weight: .regular)
            let value = NWNativeCodeText.attributedCode(code, highlighted: nil, font: font, lineSpacing: 4)
            field.font = font // Match updateNSView's order without assuming AppKit mutates attributes.
            if nativeAssignment { field.attributedStringValue = value }
            field.setCode(value)
            size(field, in: scroll)
            let referenceWindow = OffscreenWindow(size: CGSize(width: 520, height: 320), dark: dark)
            defer { referenceWindow.close() }
            let reference = NSTextField(labelWithString: "")
            let referenceScroll = mount(reference, in: referenceWindow)
            reference.font = font
            reference.attributedStringValue = value
            size(reference, in: referenceScroll)
            #expect(try render(field, scroll: scroll, fraction: 0.5)
                    == render(reference, scroll: referenceScroll, fraction: 0.5),
                    "field and retained renderer must use the same font after increasing or decreasing text scale")
        }
    }

    @Test func drawsPreparedContentOutsideTheCurrentViewport() throws {
        let field = NWNativeCodeText.Field(labelWithString: "")
        let window = OffscreenWindow(size: CGSize(width: 520, height: 320), dark: false)
        defer { window.close() }
        let scroll = mount(field, in: window)
        let code = (0..<500).map { "let item\($0) = \($0)" }.joined(separator: "\n")
        field.setCode(NWNativeCodeText.attributedCode(code, highlighted: nil,
                      font: .monospacedSystemFont(ofSize: 12, weight: .regular), lineSpacing: 4))
        size(field, in: scroll)
        _ = try render(field, scroll: scroll, fraction: 0)
        let rect = CGRect(x: 0, y: 1500, width: field.bounds.width, height: 200)
        #expect(!field.visibleRect.intersects(rect))
        let prepared = try capture(field, rect: rect)
        scroll.contentView.scroll(to: rect.origin)
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(field.visibleRect.intersects(rect))
        #expect(try capture(field, rect: rect) == prepared,
                "off-viewport prepared content must be drawn, not discarded as invisible")
    }

    @Test(arguments: [false, true])
    func linkedContentPreservesTheNativeFieldsStyling(dark: Bool) throws {
        let value = NSMutableAttributedString(string: "linked code sample", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.systemOrange,
            .link: try #require(URL(string: "https://example.invalid/code"))
        ])
        var images: [Data] = []
        for optimized in [false, true] {
            let field: NSTextField = optimized ? NWNativeCodeText.Field(labelWithString: "") : NSTextField(labelWithString: "")
            let window = OffscreenWindow(size: CGSize(width: 520, height: 320), dark: dark)
            defer { window.close() }
            let scroll = mount(field, in: window)
            if let field = field as? NWNativeCodeText.Field { field.setCode(value) }
            else { field.attributedStringValue = value }
            size(field, in: scroll)
            images.append(try render(field, scroll: scroll, fraction: 0))
        }
        #expect(images[0] == images[1], "TextKit's default blue link styling must not replace caller attributes")
    }

    @Test(arguments: [false, true], [false, true])
    func visibleCodeMatchesNativePixels(dark: Bool, unicode: Bool) throws {
        let suffix = unicode ? "\"🐑 e\u{301}\" // שלום" : "\"flock\" // a comment"
        let code = (0..<100).map { "let sheep\($0) = \(suffix)" }.joined(separator: "\n")
        NWFonts.register()
        var images: [[Data]] = []
        for optimized in [false, true] {
            let field: NSTextField = optimized ? NWNativeCodeText.Field(labelWithString: "") : NSTextField(labelWithString: "")
            let window = OffscreenWindow(size: CGSize(width: 520, height: 320), dark: dark)
            defer { window.close() }
            let scroll = mount(field, in: window)
            var captures: [Data] = []
            let fonts = try [12.0, 18.0].flatMap { points in
                [NSFont.monospacedSystemFont(ofSize: points, weight: .regular),
                 try #require(NSFont(name: NWFonts.postScriptName(mono: true, weight: .regular), size: points))]
            }
            for font in fonts {
                field.font = font
                var highlighted = AttributedString(code)
                highlighted.foregroundColor = Color.nw.synKeyword
                let value = NWNativeCodeText.attributedCode(code, highlighted: highlighted, font: font, lineSpacing: 4)
                if let field = field as? NWNativeCodeText.Field { field.setCode(value) }
                else { field.attributedStringValue = value }
                size(field, in: scroll)
                for fraction in [0.0, 0.5, 1.0] {
                    captures.append(try render(field, scroll: scroll, fraction: fraction))
                }
            }
            images.append(captures)
        }
        #expect(images[0] == images[1], "optimized drawing must preserve baselines, clipping and fallback-font metrics")
    }

    /// Force actual viewport drawing: layout-only off-screen scroll steps do not always paint.
    /// The native reference receives identical content, geometry, clipping and bitmap work.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SHEPHERD_PERF_REPORT"] == "1"), arguments: [50, 500, 2000])
    func paintsVisibleCodeWithoutRedrawingOffscreenLines(lines: Int) throws {
        let code = (0..<lines).map { "let item\($0) = compute(\($0), from: sheep) // ASCII fast path" }.joined(separator: "\n")
        let value = NWNativeCodeText.attributedCode(code, highlighted: nil,
                                                   font: .monospacedSystemFont(ofSize: 12, weight: .regular), lineSpacing: 4)
        var costs: [Double] = []
        for optimized in [false, true] {
            let field = optimized ? NWNativeCodeText.Field(labelWithString: "") : NSTextField(labelWithString: "")
            let window = OffscreenWindow(size: CGSize(width: 800, height: 500), dark: false)
            defer { window.close() }
            let scroll = mount(field, in: window)
            if let field = field as? NWNativeCodeText.Field { field.setCode(value) }
            else { field.attributedStringValue = value }
            size(field, in: scroll)
            _ = try render(field, scroll: scroll, fraction: 0)
            var samples: [Double] = []
            for step in 0..<30 {
                let fraction = CGFloat(step) / 30
                scroll.contentView.scroll(to: CGPoint(x: 0, y: fraction * max(0, field.frame.height - scroll.contentSize.height)))
                scroll.reflectScrolledClipView(scroll.contentView)
                let rect = field.visibleRect
                let bitmap = try #require(field.bitmapImageRepForCachingDisplay(in: rect))
                let start = ListPerf.threadCPU()
                try draw(field, rect: rect, bitmap: bitmap)
                samples.append(ListPerf.threadCPU() - start)
            }
            let median = samples.sorted()[samples.count / 2]
            costs.append(median)
            print("PERF code viewport \(lines) lines | \(optimized ? "retained TextKit" : "native field") median main CPU | \(median) ms")
        }
        // A relative same-process guard, not a scheduler-sensitive absolute frame budget.
        if lines >= 500 { #expect(costs[1] < costs[0] / 2, "viewport drawing must not scale with the full block: \(costs)") }
    }

    private func mount(_ field: NSTextField, in window: OffscreenWindow) -> NSScrollView {
        field.appearance = window.window.effectiveAppearance
        field.isEditable = false
        field.isSelectable = true
        field.allowsEditingTextAttributes = true
        field.isBezeled = false
        field.drawsBackground = false
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byClipping
        field.cell?.wraps = false
        field.cell?.isScrollable = false
        let scroll = NSScrollView(frame: window.window.contentView!.bounds)
        scroll.drawsBackground = false
        scroll.documentView = field
        window.window.contentView = scroll
        return scroll
    }

    private func size(_ field: NSTextField, in scroll: NSScrollView) {
        (field as? NWNativeCodeText.Field)?.measuredSize = nil
        let size = field.intrinsicContentSize
        field.setFrameSize(size)
        (field as? NWNativeCodeText.Field)?.measuredSize = size
        scroll.layoutSubtreeIfNeeded()
    }

    private func render(_ field: NSTextField, scroll: NSScrollView, fraction: CGFloat) throws -> Data {
        scroll.contentView.scroll(to: CGPoint(x: 0, y: fraction * max(0, field.frame.height - scroll.contentSize.height)))
        scroll.reflectScrolledClipView(scroll.contentView)
        let rect = field.visibleRect
        #expect(rect.height > 0 && rect.width > 0)
        return try capture(field, rect: rect)
    }

    private func capture(_ field: NSTextField, rect: NSRect) throws -> Data {
        let bitmap = try #require(field.bitmapImageRepForCachingDisplay(in: rect))
        try draw(field, rect: rect, bitmap: bitmap)
        #expect(bitmap.bitmapData.map { data in
            (0..<(bitmap.bytesPerRow * bitmap.pixelsHigh)).contains { data[$0] != 0 }
        } == true, "the captured viewport must contain drawn text, not a blank fast path")
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    private func draw(_ field: NSTextField, rect: NSRect, bitmap: NSBitmapImageRep) throws {
        // Draw each field exactly once into a fresh context. cacheDisplay can composite a
        // native field's backing layer too, doubling translucent glyphs in the reference.
        bitmap.bitmapData?.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        context.cgContext.scaleBy(x: CGFloat(bitmap.pixelsWide) / rect.width,
                                  y: CGFloat(bitmap.pixelsHigh) / rect.height)
        context.cgContext.translateBy(x: -rect.minX, y: rect.maxY)
        context.cgContext.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        field.effectiveAppearance.performAsCurrentDrawingAppearance { field.draw(rect) }
    }
}
