#if os(macOS)
import AppKit
import SwiftUI

/// AppKit lays out selectable code without SwiftUI resolving every syntax run on each chunk.
struct SHNativeCodeText: NSViewRepresentable {
    let code: String
    let highlighted: AttributedString?
    /// The colors of a fence a reply is writing: its text then changes at its end, and the field takes
    /// only what changed, in the text, its layout and its size. The Cache is not used.
    let colors: SHCodeColors?
    let scale: CGFloat
    let lineSpacing: CGFloat
    let cache: Cache
    @Environment(\.colorScheme) private var colorScheme

    /// How a fence is drawn, apart from its text and colors.
    struct Styling: Equatable {
        let font: NSFont
        let lineSpacing: CGFloat
        let foreground: Color
    }

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

        /// Lets go of the text it holds, for a block that now draws a fence as it is written.
        func forgetContent() { cached = nil }

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

    /// The TextKit views fields draw ASCII code through.
    ///
    /// AppKit never frees an `NSTextView`, and the view keeps its text container, layout manager and
    /// text storage alive with it: one a field drops after drawing a fence holds that fence's whole
    /// layout for good. A field that lets go of its renderer hands it back here emptied, and the next
    /// field to draw takes one, so the views AppKit keeps are as many as are shown at once.
    @MainActor final class RendererPool {
        static let shared = RendererPool(limit: 64)

        private let limit: Int
        private var idle: [NSTextView] = []
        var idleCount: Int { idle.count }

        init(limit: Int) { self.limit = limit }

        /// A renderer holding no text, sized to `frame`.
        func take(frame: NSRect, inset: NSSize) -> NSTextView {
            let text: NSTextView
            if let reused = idle.popLast() {
                text = reused
                text.frame = frame
            } else {
                SHRenderProbe.tick("code.rendererAllocated")
                text = NSTextView(frame: frame)
                text.isEditable = false
                text.isSelectable = false
                text.drawsBackground = false
                text.isHorizontallyResizable = true
                text.isVerticallyResizable = true
                text.textContainer?.lineFragmentPadding = 0
                text.textContainer?.widthTracksTextView = false
                text.textContainer?.heightTracksTextView = false
                text.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            }
            text.textContainerInset = inset
            return text
        }

        /// Keeps `text` for the next field without its text; past the limit, lets the text system go,
        /// which the container's hold on its view would otherwise keep.
        func give(_ text: NSTextView) {
            text.textStorage?.setAttributedString(NSAttributedString())
            if idle.count < limit { idle.append(text) } else { text.textContainer?.textView = nil }
        }
    }

    final class Field: NSTextField {
        // NSTextField redraws/layouts the entire string, including offscreen lines. Keep its
        // native editor/accessibility, but let TextKit retain glyph layout for viewport drawing.
        // The retained layout covers the whole fence, so the field keeps it only while it is shown.
        private var renderer: NSTextView?
        private var requiresNativeDrawing = false
        var measuredSize: CGSize?
        private var growth: Growth?

        func setCode(_ value: NSAttributedString) {
            growth = nil
            // Setting field.font can update its attributes before this call, but not the renderer.
            guard attributedStringValue != value || renderer?.textStorage?.isEqual(to: value) == false else { return }
            attributedStringValue = value
            requiresNativeDrawing = Self.needsNativeDrawing(value)
            if let storage = renderer?.textStorage {
                SHRenderProbe.add("code.laidOutUnits", value.length)
                storage.setAttributedString(value)
            }
            needsDisplay = true
        }

        /// Fallback fonts use different line metrics in TextKit and the field's typesetter. Keep native
        /// drawing for non-ASCII text rather than shifting its baselines.
        private static func needsNativeDrawing(_ value: NSAttributedString) -> Bool {
            if !value.string.utf8.allSatisfy({ $0 < 128 }) { return true }
            var linked = false
            value.enumerateAttribute(.link, in: NSRange(location: 0, length: value.length)) { link, _, stop in
                if link != nil {
                    linked = true
                    stop.pointee = true
                }
            }
            return linked
        }

        // MARK: A fence being written

        /// What the field shows of a fence a reply is writing, and the colors' revision it applied, so
        /// the next call changes only what differs.
        private struct Growth {
            var code: String
            var lineage: UUID
            var revision: Int
            var styling: Styling
            /// The field's text, edited in place; the cell keeps a copy of its own.
            var text: NSMutableAttributedString
        }

        /// Shows `code` colored by `colors`. Code that only grew at its end since the last call replaces the
        /// text from the first unit that differs, in the field and in its TextKit renderer, which lays out
        /// only that part again and gives the new size; anything else starts the text over.
        func showGrowing(_ code: String, colors: SHCodeColors, styling: Styling) {
            guard var current = growth, current.styling == styling, current.lineage == colors.lineage,
                  colors.revision == current.revision || colors.revision == current.revision + 1 else {
                let whole = SHNativeCodeText.styled(code, from: 0, spans: colors.spans(from: 0), styling: styling)
                setCode(whole)
                growth = Growth(code: code, lineage: colors.lineage, revision: colors.revision, styling: styling,
                                text: NSMutableAttributedString(attributedString: whole))
                measuredSize = nil
                return
            }
            if colors.revision == current.revision, code == current.code { return }
            var from = Self.sharedPrefixLength(current.code, code)
            if colors.revision != current.revision { from = min(from, colors.changedFrom) }
            let tail = SHNativeCodeText.styled(code, from: from, spans: colors.spans(from: from), styling: styling)
            replaceCode(from: from, with: tail, in: current.text)
            current.code = code
            current.revision = colors.revision
            growth = current
        }

        private func replaceCode(from location: Int, with tail: NSAttributedString, in text: NSMutableAttributedString) {
            let range = NSRange(location: location, length: text.length - location)
            text.replaceCharacters(in: range, with: tail)
            attributedStringValue = text
            if !requiresNativeDrawing, Self.needsNativeDrawing(tail) {
                requiresNativeDrawing = true
                releaseRenderer()
            }
            if let storage = renderer?.textStorage {
                SHRenderProbe.add("code.laidOutUnits", tail.length)
                storage.replaceCharacters(in: range, with: tail)
            }
            // Without a renderer the cell measures the text when it is asked.
            measuredSize = renderer.flatMap(Self.layoutSize)
            needsDisplay = true
        }

        /// The size of the text `text` lays out, which brings its layout up to date from where it changed.
        static func layoutSize(of text: NSTextView) -> CGSize? {
            guard let container = text.textContainer, let layout = text.layoutManager,
                  (text.textStorage?.length ?? 0) > 0 else { return nil }
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container)
            return CGSize(width: ceil(used.width), height: ceil(used.height))
        }

        /// The length in UTF-16 units of the text `a` and `b` begin with.
        static func sharedPrefixLength(_ a: String, _ b: String) -> Int {
            var a = a, b = b
            let ascii = a.utf8.count == a.utf16.count
            return a.withUTF8 { x -> Int in
                b.withUTF8 { y -> Int in
                    var count = min(x.count, y.count)
                    guard count > 0 else { return 0 }
                    if memcmp(x.baseAddress, y.baseAddress, count) != 0 {
                        count = 0
                        while x[count] == y[count] { count += 1 }
                    }
                    if ascii { return count }
                    // Back to where the scalar both texts share ends.
                    func continues(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool { count < bytes.count && bytes[count] & 0xC0 == 0x80 }
                    while count > 0, continues(x) || continues(y) { count -= 1 }
                    return String(decoding: UnsafeBufferPointer(rebasing: x[0..<count]), as: UTF8.self).utf16.count
                }
            }
        }

        override func viewDidHide() {
            super.viewDidHide()
            releaseRenderer()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { releaseRenderer() }
        }

        /// The next draw takes one again and lays the field's text out in it.
        private func releaseRenderer() {
            guard let text = renderer else { return }
            renderer = nil
            RendererPool.shared.give(text)
            SHRenderProbe.tick("code.rendererReleased")
        }

        override func draw(_ dirtyRect: NSRect) {
            guard currentEditor() == nil, !requiresNativeDrawing else { super.draw(dirtyRect); return }
            let text: NSTextView
            if let renderer { text = renderer }
            else {
                text = RendererPool.shared.take(frame: bounds, inset: NSSize(width: alignmentRectInsets.left, height: alignmentRectInsets.top))
                SHRenderProbe.add("code.laidOutUnits", attributedStringValue.length)
                text.textStorage?.setAttributedString(attributedStringValue)
                SHRenderProbe.tick("code.rendererCreated")
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
            let size = super.intrinsicContentSize
            return size.width < 0 || size.height < 0 ? unboundedContentSize : size
        }

        /// NSTextField gives no intrinsic size (`noIntrinsicMetric`, -1) to a side past 40,000 pt, so a fence
        /// of about 2,050 lines, or a line of about 5,400 characters, would be a 1 pt field drawing nothing.
        /// The cell measures that text without the limit; its size less the field's alignment insets,
        /// rounded up, is the intrinsic size the field gives text under it.
        var unboundedContentSize: CGSize {
            guard let cell else { return .zero }
            let size = cell.cellSize(forBounds: NSRect(origin: .zero, size: CGSize(width: CGFloat.greatestFiniteMagnitude,
                                                                                   height: CGFloat.greatestFiniteMagnitude)))
            let insets = alignmentRectInsets
            func side(_ length: CGFloat) -> CGFloat { length.isFinite ? max(0, ceil(length)) : 0 }
            return CGSize(width: side(size.width - insets.left - insets.right), height: side(size.height - insets.top - insets.bottom))
        }
    }

    func makeNSView(context: Context) -> Field {
        SHRenderProbe.tick("code.nativeCreated")
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

    /// Counts the fields SwiftUI lets go of, so a test can tell how many are alive: created minus dismantled.
    static func dismantleNSView(_ field: Field, coordinator: ()) {
        SHRenderProbe.tick("code.nativeDismantled")
    }

    func updateNSView(_ field: Field, context: Context) {
        SHRenderProbe.tick("code.nativeUpdated")
        let points = SHTextStyle.code.size * scale
        let font = NSFont(name: SHFonts.postScriptName(mono: true, weight: .regular), size: points)
            ?? .monospacedSystemFont(ofSize: points, weight: .regular)
        if let colors {
            cache.forgetContent()
            let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
            if field.appearance != appearance { field.appearance = appearance }
            if field.font != font { field.font = font }
            field.showGrowing(code, colors: colors, styling: Styling(font: font, lineSpacing: lineSpacing, foreground: Color.sh.textPrimary))
            return
        }
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
        SHRenderProbe.add("code.styledUnits", code.utf16.count)
        let base = baseAttributes(font: font, lineSpacing: lineSpacing, foreground: Color.sh.textPrimary)
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

    private static func baseAttributes(font: NSFont, lineSpacing: CGFloat, foreground: Color) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.lineBreakMode = .byClipping
        return [.font: font, .foregroundColor: NSColor(foreground), .paragraphStyle: paragraph]
    }

    /// `code` from the UTF-16 unit `from` on, colored by `spans`, the attributes `attributedCode` gives.
    static func styled(_ code: String, from: Int, spans: ArraySlice<SHCodeColors.Span>, styling: Styling) -> NSAttributedString {
        SHRenderProbe.tick("thread.codeAttributes")
        let tail = String(code[String.Index(utf16Offset: from, in: code)...])
        let text = NSMutableAttributedString(string: tail, attributes: baseAttributes(font: styling.font, lineSpacing: styling.lineSpacing,
                                                                                      foreground: styling.foreground))
        SHRenderProbe.add("code.styledUnits", text.length)
        var natives: [Color: NSColor] = [:]
        for span in spans {
            let low = max(span.range.lowerBound, from) - from, high = min(span.range.upperBound - from, text.length)
            guard low < high else { continue }
            let native = natives[span.color] ?? NSColor(span.color)
            natives[span.color] = native
            text.addAttribute(.foregroundColor, value: native, range: NSRange(location: low, length: high - low))
        }
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
