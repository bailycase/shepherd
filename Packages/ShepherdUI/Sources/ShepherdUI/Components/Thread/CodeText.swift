#if os(macOS)
import AppKit
import SwiftUI

/// AppKit lays out selectable code without SwiftUI resolving every syntax run on each chunk.
struct SHNativeCodeText: NSViewRepresentable {
    let code: String
    let highlighted: AttributedString?
    let scale: CGFloat
    let lineSpacing: CGFloat
    let cache: Cache
    @Environment(\.colorScheme) private var colorScheme

    struct Content: Equatable {
        let code: String
        let highlighted: AttributedString?
        let font: NSFont
        let lineSpacing: CGFloat
        let foreground: Color
    }

    /// ViewThatFits can create temporary native fields to measure its alternatives. Keep the
    /// attributes with the code block, so those fields share the same immutable value.
    @MainActor final class Cache {
        private final class Entry {
            let content: Content
            let value: NSAttributedString
            var size: CGSize?

            init(_ content: Content, _ value: NSAttributedString) {
                self.content = content
                self.value = value
            }
        }

        // Lazy rows are also recreated during resize. Reuse recent native work, never views,
        // with count/cost limits and memory-pressure eviction. Cost estimates include text and runs.
        private static let recent: NSCache<NSString, Entry> = {
            let cache = NSCache<NSString, Entry>()
            cache.countLimit = 64
            cache.totalCostLimit = 8 * 1024 * 1024
            return cache
        }()
        private var cached: Entry?
        var intrinsicSize: CGSize? {
            get { cached?.size }
            set { cached?.size = newValue }
        }

        func value(for content: Content) -> NSAttributedString {
            if let cached, cached.content == content { return cached.value }
            let key = content.code as NSString
            if let previous = Self.recent.object(forKey: key), previous.content == content {
                cached = previous
                return previous.value
            }
            let entry = Entry(content, attributedCode(content.code, highlighted: content.highlighted,
                                                      font: content.font, lineSpacing: content.lineSpacing))
            cached = entry
            let cost = content.code.utf8.count + entry.value.length * 2 + (content.highlighted?.runs.count ?? 1) * 128
            if cost <= Self.recent.totalCostLimit { Self.recent.setObject(entry, forKey: key, cost: cost) }
            return entry.value
        }
    }

    final class Field: NSTextField {
        // NSTextField redraws/layouts the entire string, including offscreen lines. Keep its
        // native editor/accessibility, but let TextKit retain glyph layout for viewport drawing.
        private var renderer: NSTextView?
        private var requiresNativeDrawing = false
        var measuredSize: CGSize?

        func setCode(_ value: NSAttributedString) {
            // Setting field.font can update its attributes before this call, but not the renderer.
            guard attributedStringValue != value || renderer?.textStorage?.isEqual(to: value) == false else { return }
            attributedStringValue = value
            // Fallback fonts use different line metrics in TextKit and the field's typesetter.
            // Keep native drawing for non-ASCII text rather than shifting its baselines.
            requiresNativeDrawing = !value.string.utf8.allSatisfy { $0 < 128 }
            value.enumerateAttribute(.link, in: NSRange(location: 0, length: value.length)) { link, _, stop in
                if link != nil {
                    requiresNativeDrawing = true
                    stop.pointee = true
                }
            }
            renderer?.textStorage?.setAttributedString(value)
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            guard currentEditor() == nil, !requiresNativeDrawing else { super.draw(dirtyRect); return }
            let text: NSTextView
            if let renderer { text = renderer }
            else {
                text = NSTextView(frame: bounds)
                text.isEditable = false
                text.isSelectable = false
                text.drawsBackground = false
                text.isHorizontallyResizable = true
                text.isVerticallyResizable = true
                text.textContainerInset = NSSize(width: alignmentRectInsets.left, height: alignmentRectInsets.top)
                text.textContainer?.lineFragmentPadding = 0
                text.textContainer?.widthTracksTextView = false
                text.textContainer?.heightTracksTextView = false
                text.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                text.textStorage?.setAttributedString(attributedStringValue)
                renderer = text
            }
            if text.frame != bounds { text.frame = bounds }
            if text.appearance != appearance { text.appearance = appearance }
            // NSTextView must prepare its retained glyph layout before direct drawing; an
            // unattached renderer does not receive AppKit's normal layout pass.
            if let container = text.textContainer { text.layoutManager?.ensureLayout(for: container) }
            // Match the native cell's horizontal clipping, including the last glyph.
            // Do not clip to visibleRect: prepared scroll content and PDF draws may extend past it.
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current?.cgContext.clip(to: NSRect(
                x: alignmentRectInsets.left, y: bounds.minY,
                width: max(0, bounds.width - alignmentRectInsets.left - alignmentRectInsets.right),
                height: bounds.height))
            text.draw(dirtyRect)
        }
        override var intrinsicContentSize: CGSize {
            if let measuredSize { return measuredSize }
            if !stringValue.isEmpty { SHRenderProbe.tick("layout.codeMeasured") }
            return super.intrinsicContentSize
        }
    }

    func makeNSView(context: Context) -> Field {
        let field = Field(labelWithString: "")
        field.isSelectable = true
        // Preserve syntax/font/paragraph attributes when the shared field editor ends selection.
        field.allowsEditingTextAttributes = true
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byClipping
        field.cell?.wraps = false
        field.cell?.isScrollable = false
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        let points = SHTextStyle.code.size * scale
        let font = NSFont(name: SHFonts.postScriptName(mono: true, weight: .regular), size: points)
            ?? .monospacedSystemFont(ofSize: points, weight: .regular)
        // Resize and hover updates keep the same text. Read the theme before comparing so a
        // palette change still invalidates the native attributes; appearance is dynamic.
        let content = Content(code: code, highlighted: highlighted, font: font, lineSpacing: lineSpacing,
                              foreground: Color.sh.textPrimary)
        let value = cache.value(for: content)
        // AppKit measures outside SwiftUI's sizing hook too. Invalidate for new content/font,
        // but reuse a known non-wrapping size even when AppKit asks for it directly.
        field.measuredSize = cache.intrinsicSize
        let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        if field.appearance != appearance { field.appearance = appearance }
        if field.font != font { field.font = font }
        field.setCode(value)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Field, context: Context) -> CGSize? {
        // Code never wraps, so the proposal cannot change its intrinsic size.
        let size = cache.intrinsicSize ?? nsView.intrinsicContentSize
        cache.intrinsicSize = size
        nsView.measuredSize = size
        return size
    }

    static func attributedCode(_ code: String, highlighted: AttributedString?, font: NSFont,
                               lineSpacing: CGFloat) -> NSAttributedString {
        SHRenderProbe.tick("thread.codeAttributes")
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.lineBreakMode = .byClipping
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(Color.sh.textPrimary),
                                                  .paragraphStyle: paragraph]
        if let highlighted, let text = syntaxCode(highlighted, base: base) { return text }
        let text = highlighted.map { NSMutableAttributedString(attributedString: NSAttributedString($0)) }
            ?? NSMutableAttributedString(string: code)
        let range = NSRange(location: 0, length: text.length)
        text.addAttributes(base, range: range)
        let key = NSAttributedString.Key(AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.name)
        var colors: [Color: NSColor] = [:]
        text.enumerateAttribute(key, in: range) { value, run, _ in
            guard let color = value as? Color else { return }
            let native = colors[color] ?? NSColor(color)
            colors[color] = native
            text.addAttribute(.foregroundColor, value: native, range: run)
        }
        text.removeAttribute(key, range: range)
        return text
    }

    /// The highlighter adds only foreground colors. Bridge those directly instead of building
    /// and then removing thousands of SwiftUI attribute dictionaries. Keep the general bridge
    /// above for callers supplying links or any other attributes.
    private static func syntaxCode(_ source: AttributedString, base: [NSAttributedString.Key: Any]) -> NSAttributedString? {
        let text = NSMutableAttributedString(string: String(source.characters), attributes: base)
        var colors: [Color: (native: NSColor, attributes: AttributeContainer)] = [:]
        let plain = AttributeContainer()
        for run in source.runs {
            guard let color = run.foregroundColor else {
                guard run.attributes == plain else { return nil }
                continue
            }
            let entry: (native: NSColor, attributes: AttributeContainer)
            if let cached = colors[color] { entry = cached }
            else {
                var attributes = AttributeContainer()
                attributes.foregroundColor = color
                entry = (NSColor(color), attributes)
                colors[color] = entry
            }
            guard run.attributes == entry.attributes else { return nil }
            text.addAttribute(.foregroundColor, value: entry.native, range: NSRange(run.range, in: source))
        }
        return text
    }
}
#endif
