import AppKit
import SwiftUI
@testable import ShepherdUI
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

@Suite("Thread code blocks", .mainActorExclusive)
@MainActor
struct ThreadCodeBlockTests {
    @Test(arguments: [false, true], [false, true])
    func codeStaysSelectableAndUnwrappedWhenTheColumnNarrows(dark: Bool, long: Bool) throws {
        let code = "let sheep = \"🐑\"\n" + String(repeating: "value = 42; ", count: long ? 80 : 1)
        let window = OffscreenWindow(size: CGSize(width: 480, height: 320), dark: dark,
                                     SHCodeBlock(code, language: "swift", highlighted: AttributedString(code)))
        defer { window.close() }
        ListPerf.settle(window)
        let field = try #require(codeField(in: window.window.contentView!, code: code))
        #expect(field.isSelectable && !field.isEditable)
        #expect(field.attributedStringValue.string == code)
        let height = field.frame.height
        #expect(height > 0)
        #expect(codeFields(in: window.host, code: code).count == 1)
        let scroll = ListPerf.scrollView(in: window)
        #expect((scroll != nil) == long, "only code wider than its column sits in a scroll view")
        if let scroll, let document = scroll.documentView { #expect(document.frame.width > scroll.contentSize.width) }
        window.window.setContentSize(CGSize(width: 240, height: 320))
        ListPerf.settle(window)
        let resized = try #require(codeField(in: window.host, code: code))
        #expect(resized === field && resized.window === window.window)
        #expect(resized.frame.height == height, "narrowing scrolls sideways instead of wrapping")
        #expect(resized.attributedStringValue.string == code)
    }

    @Test func aColumnNarrowerThanTheCodeScrollsSidewaysInsteadOfWrapping() throws {
        let code = "let sheep = \"🐑\"\nlet count = 42"
        let window = OffscreenWindow(size: CGSize(width: 480, height: 320), dark: false, SHCodeBlock(code, language: "swift"))
        defer { window.close() }
        ListPerf.settle(window)
        let height = try #require(codeField(in: window.host, code: code)).frame.height
        #expect(ListPerf.scrollView(in: window) == nil)
        window.window.setContentSize(CGSize(width: 80, height: 320))
        ListPerf.settle(window)
        #expect(codeFields(in: window.host, code: code).count == 1)
        #expect(try #require(codeField(in: window.host, code: code)).frame.height == height, "narrowing never wraps")
        let scroll = try #require(ListPerf.scrollView(in: window))
        #expect(try #require(scroll.documentView).frame.width > scroll.contentSize.width)
        window.window.setContentSize(CGSize(width: 480, height: 320))
        ListPerf.settle(window)
        #expect(ListPerf.scrollView(in: window) == nil)
        #expect(codeFields(in: window.host, code: code).count == 1)
        #expect(try #require(codeField(in: window.host, code: code)).frame.height == height)
    }

    @Test func aSelectionSurvivesTheNextCodeChunk() throws {
        let code = "let sheep = \"🐑\""
        let window = OffscreenWindow(SHCodeBlock(code, language: "swift"))
        defer { window.close() }
        ListPerf.settle(window)
        let field = try #require(codeField(in: window.host, code: code))
        let editor = try #require(window.window.fieldEditor(true, for: field) as? NSTextView)
        let selection = NSRange(location: 4, length: 5)
        field.cell?.select(withFrame: field.bounds, in: field, editor: editor, delegate: field,
                           start: selection.location, length: selection.length)
        #expect(window.window.makeFirstResponder(editor))
        #expect(field.currentEditor() === editor)
        #expect((editor.string as NSString).substring(with: selection) == "sheep")
        let pasteboard = NSPasteboard(name: .init("shepherd-code-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        editor.setSelectedRange(NSRange(location: 13, length: 2))
        let types = editor.writablePasteboardTypes
        let declared = pasteboard.declareTypes(types, owner: nil)
        let selected = editor.selectedRange()
        let exported = editor.writeSelection(to: pasteboard, types: types)
        let copied = pasteboard.string(forType: .string)
        if !exported || copied != "🐑" {
            let control = NSPasteboard(name: .init("shepherd-code-control-\(UUID().uuidString)"))
            defer { control.releaseGlobally() }
            control.clearContents()
            let writable = control.setString("🐑", forType: .string)
            let readable = control.string(forType: .string) == "🐑"
            print("Code selection export: editor=\(type(of: editor)), field editor=\(editor.isFieldEditor), selectable=\(editor.isSelectable), selection=\(selected), UTF16 length=\(editor.string.utf16.count), types=\(types), declared=\(declared), change count=\(pasteboard.changeCount), board types=\(String(describing: pasteboard.types)), exported=\(exported), copied emoji=\(copied == "🐑"), control write/read=\(writable)/\(readable)")
        }
        #expect(exported)
        #expect(copied == "🐑")
        editor.setSelectedRange(selection)
        let initialHeight = field.frame.height
        let grown = code + "\nlet count = 42"
        window.show(SHCodeBlock(grown, language: "swift"))
        ListPerf.settle(window)
        #expect(editor.string == grown)
        #expect(field.frame.height > initialHeight, "adding a line invalidates the cached intrinsic size")
        #expect(editor.selectedRange() == selection)
        #expect(field.currentEditor() === editor)
        window.window.setContentSize(CGSize(width: 200, height: 320))
        ListPerf.settle(window)
        #expect(ListPerf.scrollView(in: window) == nil, "the narrower column still holds the code")
        #expect(codeField(in: window.host, code: grown) === field)
        #expect(editor.selectedRange() == selection && field.currentEditor() === editor)
        var colored = AttributedString(grown)
        colored.foregroundColor = Color.sh.synKeyword
        window.show(SHCodeBlock(grown, language: "swift", highlighted: colored))
        ListPerf.settle(window)
        #expect(editor.string == grown && editor.selectedRange() == selection)
        let shortened = "let sh"
        window.show(SHCodeBlock(shortened, language: "swift"))
        ListPerf.settle(window)
        #expect(editor.string == shortened && editor.selectedRange() == NSRange(location: 4, length: 2))
        #expect(field.frame.height == initialHeight, "removing a line invalidates the cached intrinsic size")
    }

    @Test(arguments: [1, 500])
    func unchangedCodeKeepsItsNativeAttributesThroughResizeAndAppearanceChanges(lines: Int) throws {
        let code = (0..<lines).map { "let sheep\($0) = \"🐑\"" }.joined(separator: "\n")
        let window = OffscreenWindow(size: CGSize(width: 480, height: 320), dark: false,
                                     SHCodeBlock(code, language: "swift").environment(\.colorScheme, .light))
        defer { window.close() }
        ListPerf.settle(window)
        let field = try #require(codeField(in: window.host, code: code))
        let counts = ListPerf.counting {
            for step in 0..<8 {
                window.window.setContentSize(CGSize(width: 480 + step * 8, height: 320))
                window.show(SHCodeBlock(code, language: "swift")
                    .environment(\.colorScheme, step.isMultiple(of: 2) ? .light : .dark))
                ListPerf.settle(window)
                _ = field.intrinsicContentSize // AppKit may ask directly, bypassing the SwiftUI hook.
            }
        }
        #expect(counts["thread.codeAttributes", default: 0] == 0,
                "unchanged code must not rebuild native syntax runs for layout or appearance")
        #expect(counts["layout.codeMeasured", default: 0] == 0,
                "non-wrapping code must not be remeasured for different viewport widths")
        #expect(codeField(in: window.host, code: code) === field)
        #expect(field.appearance?.name == .darkAqua)
        #expect(field.attributedStringValue.string == code && field.isSelectable)
    }

    @Test func recreatedCodeViewsReuseTheirMeasurements() throws {
        let code = (0..<500).map { "// recreated row \($0) 🐑" }.joined(separator: "\n")
        let window = OffscreenWindow(size: CGSize(width: 520, height: 300), dark: true)
        defer { window.close() }
        window.show(SHCodeBlock(code, language: "swift").id(0))
        let original = try #require(codeField(in: window.host, code: code))
        let counts = ListPerf.counting {
            for identity in 1...6 {
                window.show(SHCodeBlock(code, language: "swift").id(identity))
                ListPerf.settle(window)
            }
        }
        let recreated = try #require(codeField(in: window.host, code: code))
        #expect(recreated !== original, "the fixture must recreate native views, like a recycled lazy row")
        #expect(recreated.intrinsicContentSize == original.intrinsicContentSize)
        #expect(counts["thread.codeAttributes", default: 0] == 0)
        #expect(counts["layout.codeMeasured", default: 0] == 0)
    }

    @Test func syntaxOnlyChangesUpdateRetainedCode() throws {
        let code = "let sheep = 1"
        var highlighted = AttributedString(code)
        highlighted.foregroundColor = Color.sh.synKeyword
        let window = OffscreenWindow(SHCodeBlock(code, language: "swift", highlighted: highlighted))
        defer { window.close() }
        ListPerf.settle(window)
        let field = try #require(codeField(in: window.host, code: code))
        let original = field.attributedStringValue
        highlighted.foregroundColor = Color.sh.synString
        window.show(SHCodeBlock(code, language: "swift", highlighted: highlighted))
        ListPerf.settle(window)
        #expect(codeField(in: window.host, code: code) === field)
        #expect(field.attributedStringValue != original, "syntax-only changes must invalidate cached attributes")
        #expect(field.attributedStringValue.string == code)
    }

    @Test func retainedCodeUpdatesWhenTheThemeOrTextScaleChanges() throws {
        let theme = ThemeStore.shared.theme
        let scale = ThemeStore.shared.textScale
        defer { ThemeStore.shared.select(theme); ThemeStore.shared.textScale = scale }
        let code = "let sheep = \"🐑\""
        let window = OffscreenWindow(size: CGSize(width: 480, height: 320), dark: false,
                                     SHCodeBlock(code, language: "swift"))
        defer { window.close() }
        ListPerf.settle(window)
        let field = try #require(codeField(in: window.host, code: code))
        let fontSize = try #require(field.font).pointSize
        let height = field.frame.height
        let oldColor = try #require(field.attributedStringValue.attribute(.foregroundColor, at: 0,
                                                                         effectiveRange: nil) as? NSColor)
        var changed = theme
        changed.light.colors.textPrimary = theme.light.colors.running
        changed.dark.colors.textPrimary = theme.dark.colors.running
        ThemeStore.shared.select(changed)
        ListPerf.settle(window)
        let color = try #require(field.attributedStringValue.attribute(.foregroundColor, at: 0,
                                                                      effectiveRange: nil) as? NSColor)
        #expect(color != oldColor, "theme changes alone must invalidate the cached native foreground")
        ThemeStore.shared.textScale = scale * 1.3
        ListPerf.settle(window)
        #expect(codeField(in: window.host, code: code) === field)
        #expect(try #require(field.font).pointSize > fontSize)
        #expect(field.frame.height > height, "text scale invalidates cached geometry too")
        #expect(field.attributedStringValue.string == code)
    }

    @Test func surroundingUpdatesDoNotCreateTemporaryNativeCodeFields() {
        func content(_ update: Int) -> some View {
            ScrollView {
                VStack {
                    ForEach(0..<8) { index in
                        SHCodeBlock(index.isMultiple(of: 2) ? "let value\(index) = \(index)"
                            : String(repeating: "longIdentifier", count: 40), language: "swift")
                    }
                    Text(String(repeating: "Streaming reply. ", count: update + 1))
                }
            }
        }
        SHRenderProbe.start()
        let window = OffscreenWindow(size: CGSize(width: 480, height: 800), content(0))
        defer { window.close() }
        ListPerf.settle(window)
        let initial = SHRenderProbe.stop()
        #expect(initial["code.nativeCreated", default: 0] >= 8, "the native creation probe must be active")
        #expect(codeFields(in: window.host, code: "let value0 = 0").count == 1)
        let counts = ListPerf.counting {
            for update in 1...5 {
                window.show(content(update))
                ListPerf.settle(window)
            }
        }
        let created = counts["code.nativeCreated", default: 0]
        #expect(created == 0,
                "unchanged code must not construct fitting candidates while nearby prose streams")
    }

    @Test func codeGainsAndLosesHorizontalOverflowWhenResized() throws {
        let code = "let value = \"" + String(repeating: "m", count: 48) + "\""
        let window = OffscreenWindow(size: CGSize(width: 900, height: 320), SHCodeBlock(code, language: "swift"))
        defer { window.close() }
        for width in [900.0, 240.0, 900.0] {
            window.host.frame.size = CGSize(width: width, height: 320)
            ListPerf.settle(window)
            let field = try #require(codeField(in: window.host, code: code))
            #expect(field.isSelectable && !field.isEditable)
            #expect(field.attributedStringValue.string == code)
            let scroller = sequence(first: field.superview, next: { $0?.superview })
                .compactMap { $0 as? NSScrollView }.first
            if width == 240 {
                let scroll = try #require(scroller)
                let document = try #require(scroll.documentView)
                #expect(document.bounds.width > scroll.contentSize.width)
                scroll.contentView.scroll(to: NSPoint(x: document.bounds.width - scroll.contentSize.width, y: 0))
                scroll.reflectScrolledClipView(scroll.contentView)
                #expect(scroll.contentView.bounds.maxX >= document.bounds.maxX - 1)
            } else {
                #expect(scroller == nil, "fitting code must return to direct selectable text")
            }
        }
    }

    @Test func contentAndFontChangesReevaluateHorizontalOverflow() throws {
        let scale = ThemeStore.shared.textScale
        defer { ThemeStore.shared.textScale = scale }
        let short = "let value = 1"
        let long = String(repeating: "longIdentifier", count: 40)
        let window = OffscreenWindow(size: CGSize(width: 480, height: 320), SHCodeBlock(short, language: "swift"))
        defer { window.close() }
        for code in [short, long, short] {
            window.show(SHCodeBlock(code, language: "swift"))
            ListPerf.settle(window)
            let field = try #require(codeField(in: window.host, code: code))
            #expect(field.isSelectable && !field.isEditable)
            let scroll = sequence(first: field.superview, next: { $0?.superview })
                .compactMap { $0 as? NSScrollView }.first
            #expect((scroll != nil) == (code == long))
        }
        let field = try #require(codeField(in: window.host, code: short))
        let originalFont = try #require(field.font).pointSize
        let narrowWidth = field.frame.width + 2 * SH.Space.l + 1
        window.window.setContentSize(CGSize(width: narrowWidth, height: 320))
        ListPerf.settle(window)
        for multiplier in [1.5, 1.0] {
            ThemeStore.shared.textScale = scale * multiplier
            ListPerf.settle(window)
            let current = try #require(codeField(in: window.host, code: short))
            #expect(window.host.frame.width == narrowWidth)
            #expect(try #require(current.font).pointSize == originalFont * multiplier)
            let scroll = sequence(first: current.superview, next: { $0?.superview })
                .compactMap { $0 as? NSScrollView }.first
            #expect((scroll != nil) == (multiplier > 1),
                    "scale=\(multiplier), field=\(current.frame), host=\(window.host.frame), scroll=\(String(describing: scroll?.frame))")
            #expect(current.isSelectable && current.attributedStringValue.string == short)
        }
    }

    // MARK: What a fence keeps once it is out of sight

    /// ASCII code draws through the field's retained TextKit renderer (non-ASCII draws natively, with none).
    private static let asciiCode = (0..<40).map { "let sheep\($0) = \($0) // flock" }.joined(separator: "\n")

    @Test func aHiddenCodeBlockLetsGoOfItsRenderer() throws {
        let code = Self.asciiCode
        SHRenderProbe.start()
        defer { _ = SHRenderProbe.stop() }
        var highlighted = AttributedString(code)
        highlighted.foregroundColor = Color.sh.synKeyword
        let window = OffscreenWindow(size: CGSize(width: 480, height: 800), dark: false,
                                     SHCodeBlock(code, language: "swift", highlighted: highlighted))
        defer { window.close() }
        ListPerf.settle(window)
        let field = try #require(codeField(in: window.host, code: code))
        let created = SHRenderProbe.count("code.rendererCreated")
        #expect(created >= 1, "ASCII code draws through a retained renderer")
        #expect(SHRenderProbe.count("code.rendererReleased") == 0)
        let shown = try drawn(field)

        window.host.isHidden = true
        ListPerf.settle(window)
        #expect(SHRenderProbe.count("code.rendererReleased") == created, "a hidden thread keeps no renderer for its fences")

        window.host.isHidden = false
        ListPerf.settle(window)
        let again = try drawn(field)
        let recreated = SHRenderProbe.count("code.rendererCreated")
        #expect(recreated > created, "a draw takes a renderer again, lazily")
        #expect(recreated - SHRenderProbe.count("code.rendererReleased") == 1, "one renderer is in use again")
        #expect(again == shown, "a fence shown again draws as it did, colors included")
    }

    @Test func aCodeBlockLeavingItsWindowLetsGoOfItsRenderer() throws {
        let code = Self.asciiCode
        SHRenderProbe.start()
        defer { _ = SHRenderProbe.stop() }
        let window = OffscreenWindow(size: CGSize(width: 480, height: 800), dark: true, SHCodeBlock(code, language: "swift"))
        defer { window.close() }
        ListPerf.settle(window)
        let field = try #require(codeField(in: window.host, code: code))
        let created = SHRenderProbe.count("code.rendererCreated")
        #expect(created >= 1)
        let shown = try drawn(field)

        let parent = try #require(field.superview)
        field.removeFromSuperview()
        #expect(field.window == nil)
        #expect(SHRenderProbe.count("code.rendererReleased") == created, "a fence out of its window keeps no renderer")

        parent.addSubview(field)
        ListPerf.settle(window)
        #expect(try drawn(field) == shown)
        #expect(SHRenderProbe.count("code.rendererCreated") - SHRenderProbe.count("code.rendererReleased") == 1)
    }

    @Test func aCodeBlockHiddenAndShownAgainAndAgainReusesOneRenderer() throws {
        let code = Self.asciiCode
        SHRenderProbe.start()
        defer { _ = SHRenderProbe.stop() }
        let window = OffscreenWindow(size: CGSize(width: 480, height: 800), SHCodeBlock(code, language: "swift"))
        defer { window.close() }
        ListPerf.settle(window)
        let field = try #require(codeField(in: window.host, code: code))
        for _ in 0..<10 {
            window.host.isHidden = true
            ListPerf.settle(window)
            window.host.isHidden = false
            ListPerf.settle(window)
            _ = try drawn(field)
        }
        let released = SHRenderProbe.count("code.rendererReleased")
        #expect(released >= 10, "every hiding hands the renderer back")
        #expect(SHRenderProbe.count("code.rendererCreated") - released == 1, "and one is in use now")
        #expect(SHRenderProbe.count("code.rendererAllocated") <= 1,
                "AppKit keeps every NSTextView it makes, so a field that draws again takes the one it gave back")
    }

    @Test func aCodeBlockRemovedFromItsThreadHandsBackItsRenderer() throws {
        let code = Self.asciiCode
        SHRenderProbe.start()
        defer { _ = SHRenderProbe.stop() }
        let window = OffscreenWindow(size: CGSize(width: 480, height: 800), SHCodeBlock(code, language: "swift"))
        defer { window.close() }
        ListPerf.settle(window)
        let created = SHRenderProbe.count("code.rendererCreated")
        #expect(created >= 1)

        window.show(EmptyView())
        ListPerf.settle(window)

        #expect(SHRenderProbe.count("code.rendererReleased") == created)
    }

    @Test func aFenceShownAgainStillSelectsAndCopies() throws {
        let code = Self.asciiCode
        let window = OffscreenWindow(size: CGSize(width: 480, height: 800), dark: false, SHCodeBlock(code, language: "swift"))
        defer { window.close() }
        ListPerf.settle(window)
        let field = try #require(codeField(in: window.host, code: code))
        window.host.isHidden = true
        ListPerf.settle(window)
        window.host.isHidden = false
        ListPerf.settle(window)
        _ = try drawn(field)

        let editor = try #require(window.window.fieldEditor(true, for: field) as? NSTextView)
        let selection = NSRange(location: 4, length: 6)
        field.cell?.select(withFrame: field.bounds, in: field, editor: editor, delegate: field,
                           start: selection.location, length: selection.length)
        #expect(window.window.makeFirstResponder(editor))
        #expect(field.currentEditor() === editor)
        let pasteboard = NSPasteboard(name: .init("shepherd-code-shown-again-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let types = editor.writablePasteboardTypes
        pasteboard.declareTypes(types, owner: nil)
        #expect(editor.writeSelection(to: pasteboard, types: types))
        #expect(pasteboard.string(forType: .string) == (code as NSString).substring(with: selection))
    }

    /// Whether the character at `unit` of the field is drawn in a syntax color, not the text color.
    private func isColored(_ field: NSTextField, at unit: Int) -> Bool {
        guard unit < field.attributedStringValue.length else { return false }
        let color = field.attributedStringValue.attribute(.foregroundColor, at: unit, effectiveRange: nil) as? NSColor
        return color != nil && color != NSColor(Color.sh.textPrimary)
    }

    /// A fence being written is colored line by line and kept by its block, not by the shared cache,
    /// which holds only the fence once it is done.
    @Test func aGrowingFenceStoresNothingInTheCacheUntilItIsDone() async throws {
        func lines(_ count: Int) -> String { (0..<count).map { "var sheep\($0) = \($0)" }.joined(separator: "\n") }
        let first = lines(8), second = lines(16), full = CodeHighlightCache.Key(fence: lines(17), language: "go")
        let window = OffscreenWindow(size: CGSize(width: 480, height: 800),
                                     HighlightedCodeBlock(code: first, language: "go", writing: true))
        defer { window.close() }
        try await eventuallyOnMain("the first lines to be colored") {
            ListPerf.settle(window)
            return codeField(in: window.host, code: first).map { isColored($0, at: 0) } ?? false
        }
        window.show(HighlightedCodeBlock(code: second, language: "go", writing: true))
        let start = (second as NSString).range(of: "var sheep14").location
        try await eventuallyOnMain("the next render to be colored") {
            ListPerf.settle(window)
            return codeField(in: window.host, code: second).map { isColored($0, at: start) } ?? false
        }
        #expect(CodeHighlightCache.cached(CodeHighlightCache.Key(fence: first, language: "go")) == nil)
        #expect(CodeHighlightCache.cached(CodeHighlightCache.Key(fence: second, language: "go")) == nil)

        window.show(HighlightedCodeBlock(code: lines(17), language: "go", writing: false))
        try await eventuallyOnMain("the finished fence to be colored") {
            ListPerf.settle(window)
            return CodeHighlightCache.cached(full) != nil
        }
        #expect(CodeHighlightCache.cached(CodeHighlightCache.Key(fence: second, language: "go")) == nil, "a closed fence leaves only its full render")
    }

    /// A reply writing a long fence in chunks: each chunk is colored, turned into native text and laid out
    /// from where it changed, so what the whole stream costs follows the length of the fence, not its square.
    /// A fence in a language with no grammar is laid out the same way, uncolored. The fence ends as its
    /// whole highlight.
    @Test(arguments: ["go", "text"])
    func aFenceStreamedInChunksIsColoredStyledAndLaidOutInProportionToItsLength(language: String) async throws {
        let lines = (0..<400).map { "var sheep\($0) = \($0) // flock" }
        let code = lines.joined(separator: "\n")
        let window = OffscreenWindow(size: CGSize(width: 520, height: 320),
                                     HighlightedCodeBlock(code: lines[0], language: language, writing: true))
        defer { window.close() }
        ListPerf.settle(window)
        SHRenderProbe.start()
        defer { SHRenderProbe.stop() }
        for end in stride(from: 25, through: lines.count, by: 25) {
            let written = lines[..<end].joined(separator: "\n")
            window.show(HighlightedCodeBlock(code: written, language: language, writing: true))
            ListPerf.settle(window)
            if language == "go" {
                // The lines before the one still being written are colored before the next chunk comes.
                let last = (written as NSString).range(of: "var sheep\(end - 2)").location
                try await eventuallyOnMain("\(end - 1) lines to be colored") {
                    ListPerf.settle(window)
                    return codeField(in: window.host, code: written).map { isColored($0, at: last) } ?? false
                }
            }
        }
        let streaming = SHRenderProbe.stop()

        window.show(HighlightedCodeBlock(code: code, language: language, writing: false))
        let key = CodeHighlightCache.Key(fence: code, language: language)
        if language == "go" {
            try await eventuallyOnMain("the finished fence to be colored") {
                ListPerf.settle(window)
                return CodeHighlightCache.cached(key) != nil
            }
        }
        ListPerf.settle(window)

        let units = code.utf16.count
        for (probe, name) in [("code.styledUnits", "styled"), ("code.laidOutUnits", "laid out"), ("highlight.units", "colored")] {
            let count = streaming[probe, default: 0]
            #expect(count < 3 * units, "\(count) units \(name) while streaming a fence of \(units)")
        }
        #expect(streaming["layout.codeMeasured", default: 0] <= 2, "the cell measures the fence only before its renderer exists")
        if language == "go" { #expect(streaming["highlight.render", default: 0] >= 8, "the colors landed chunk by chunk") }

        let field = try #require(codeField(in: window.host, code: key.code))
        let whole = language == "go" ? try #require(CodeHighlightCache.cached(key)) : nil
        let expected = SHNativeCodeText.attributedCode(key.code, highlighted: whole, font: try #require(field.font), lineSpacing: SHTextStyle.code.lineSpacing + 0.6)
        #expect(field.attributedStringValue.isEqual(to: expected), "the fence ends as its whole highlight")
        #expect(field.frame.height > CGFloat(lines.count) * 12)
    }

    @Test func aSelectionSurvivesTheNextChunkOfAFenceBeingWritten() throws {
        let code = "let sheep = 1\nlet flock = 2"
        var colors = SHCodeColors()
        colors.recolor(from: 0, with: [SHCodeColors.Span(range: 0..<3, color: Color.sh.synKeyword)])
        let window = OffscreenWindow(SHCodeBlock(code, language: "swift", colors: colors))
        defer { window.close() }
        ListPerf.settle(window)
        let field = try #require(codeField(in: window.host, code: code))
        let editor = try #require(window.window.fieldEditor(true, for: field) as? NSTextView)
        let selection = NSRange(location: 4, length: 5)
        field.cell?.select(withFrame: field.bounds, in: field, editor: editor, delegate: field, start: selection.location, length: selection.length)
        #expect(window.window.makeFirstResponder(editor))
        #expect((editor.string as NSString).substring(with: selection) == "sheep")
        let initialHeight = field.frame.height

        let grown = code + "\nlet count = 42"
        colors.recolor(from: 14, with: [SHCodeColors.Span(range: 14..<17, color: Color.sh.synKeyword)])
        window.show(SHCodeBlock(grown, language: "swift", colors: colors))
        ListPerf.settle(window)

        #expect(codeField(in: window.host, code: grown) === field)
        #expect(editor.string == grown && editor.selectedRange() == selection && field.currentEditor() === editor)
        #expect(field.frame.height > initialHeight, "a line more makes the fence taller")
    }

    @Test func aFenceHiddenWhileItIsWrittenDrawsAsIfBuiltWholeWhenShownAgain() throws {
        let lines = (0..<60).map { "let sheep\($0) = \($0) // flock" }
        var colors = SHCodeColors()
        colors.recolor(from: 0, with: [])
        let window = OffscreenWindow(size: CGSize(width: 480, height: 800), dark: false,
                                     SHCodeBlock(lines[..<20].joined(separator: "\n"), language: "swift", colors: colors))
        defer { window.close() }
        ListPerf.settle(window)
        _ = try drawn(try #require(codeField(in: window.host, code: lines[..<20].joined(separator: "\n"))))

        window.host.isHidden = true
        ListPerf.settle(window)
        for end in [30, 45, 60] {
            window.show(SHCodeBlock(lines[..<end].joined(separator: "\n"), language: "swift", colors: colors))
            ListPerf.settle(window)
        }
        window.host.isHidden = false
        ListPerf.settle(window)
        let code = lines.joined(separator: "\n")
        let grown = try drawn(try #require(codeField(in: window.host, code: code)))

        let reference = OffscreenWindow(size: CGSize(width: 480, height: 800), dark: false, SHCodeBlock(code, language: "swift"))
        defer { reference.close() }
        ListPerf.settle(reference)
        #expect(grown == (try drawn(try #require(codeField(in: reference.host, code: code)))))
    }

    @Test func aFenceScrolledBackIntoViewIsColoredOnItsFirstFrame() async throws {
        let code = "var sheep = 1\nfunc flock() int { return 2 }"
        let key = CodeHighlightCache.Key(fence: code, language: "go")
        let window = OffscreenWindow(size: CGSize(width: 480, height: 400), HighlightedCodeBlock(code: code, language: "go"))
        defer { window.close() }
        try await eventuallyOnMain("the fence to be colored") {
            ListPerf.settle(window)
            return CodeHighlightCache.cached(key) != nil
        }
        window.show(EmptyView())
        ListPerf.settle(window)
        #expect(codeField(in: window.host, code: key.code) == nil)

        let counts = ListPerf.counting {
            window.show(HighlightedCodeBlock(code: code, language: "go"))
            ListPerf.settle(window)
        }

        let field = try #require(codeField(in: window.host, code: key.code))
        var colors: Set<NSColor> = []
        field.attributedStringValue.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: field.attributedStringValue.length)) { value, _, _ in
            if let color = value as? NSColor { colors.insert(color) }
        }
        #expect(colors.count > 1, "the colors come from the cache, not from a render that has yet to land")
        #expect(counts["highlight.render", default: 0] == 0)
    }

    private func codeField(in view: NSView, code: String) -> NSTextField? {
        codeFields(in: view, code: code).first
    }

    private func codeFields(in view: NSView, code: String) -> [NSTextField] {
        let own = (view as? NSTextField).flatMap { $0.stringValue == code ? [$0] : nil } ?? []
        return own + view.subviews.flatMap { codeFields(in: $0, code: code) }
    }

    /// The field's pixels, drawn the way AppKit draws it when it is shown or scrolled, with ink.
    private func drawn(_ field: NSTextField) throws -> Data {
        let rect = field.bounds
        let bitmap = try #require(field.bitmapImageRepForCachingDisplay(in: rect))
        bitmap.bitmapData?.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        context.cgContext.scaleBy(x: CGFloat(bitmap.pixelsWide) / rect.width, y: CGFloat(bitmap.pixelsHigh) / rect.height)
        context.cgContext.translateBy(x: -rect.minX, y: rect.maxY)
        context.cgContext.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        field.effectiveAppearance.performAsCurrentDrawingAppearance { field.draw(rect) }
        #expect(bitmap.bitmapData.map { data in (0..<(bitmap.bytesPerRow * bitmap.pixelsHigh)).contains { data[$0] != 0 } } == true,
                "the fence draws ink")
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
}
