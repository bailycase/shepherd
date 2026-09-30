import AppKit
import SwiftUI
import ShepherdUI
import ShepherdTestSupport
import Testing

@Suite("Thread code blocks", .mainActorExclusive)
@MainActor
struct ThreadCodeBlockTests {
    @Test(arguments: [false, true], [false, true])
    func codeStaysSelectableAndUnwrappedWhenTheColumnNarrows(dark: Bool, long: Bool) throws {
        let code = "let sheep = \"🐑\"\n" + String(repeating: "value = 42; ", count: long ? 80 : 1)
        let window = OffscreenWindow(size: CGSize(width: 480, height: 320), dark: dark,
                                     NWCodeBlock(code, language: "swift", highlighted: AttributedString(code)))
        defer { window.close() }
        ListPerf.settle(window)
        let field = try #require(codeField(in: window.window.contentView!, code: code))
        #expect(field.isSelectable && !field.isEditable)
        #expect(field.attributedStringValue.string == code)
        let height = field.frame.height
        #expect(height > 0)
        let scroll = try #require(ListPerf.scrollView(in: window))
        let document = try #require(scroll.documentView)
        #expect((document.frame.width > scroll.contentSize.width) == long)
        window.window.setContentSize(CGSize(width: 240, height: 320))
        ListPerf.settle(window)
        let resized = try #require(codeField(in: window.host, code: code))
        #expect(resized === field && resized.window === window.window)
        #expect(resized.frame.height == height, "narrowing scrolls sideways instead of wrapping")
        #expect(resized.attributedStringValue.string == code)
    }

    @Test func aSelectionSurvivesTheNextCodeChunk() throws {
        let code = "let sheep = \"🐑\""
        let window = OffscreenWindow(NWCodeBlock(code, language: "swift"))
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
        pasteboard.declareTypes(editor.writablePasteboardTypes, owner: nil)
        #expect(editor.writeSelection(to: pasteboard, types: editor.writablePasteboardTypes))
        #expect(pasteboard.string(forType: .string) == "🐑")
        editor.setSelectedRange(selection)
        let grown = code + "\nlet count = 42"
        window.show(NWCodeBlock(grown, language: "swift"))
        ListPerf.settle(window)
        #expect(editor.string == grown)
        #expect(editor.selectedRange() == selection)
        #expect(field.currentEditor() === editor)
        window.window.setContentSize(CGSize(width: 80, height: 320))
        ListPerf.settle(window)
        #expect(codeField(in: window.host, code: grown) === field)
        #expect(editor.selectedRange() == selection && field.currentEditor() === editor)
        var colored = AttributedString(grown)
        colored.foregroundColor = Color.nw.synKeyword
        window.show(NWCodeBlock(grown, language: "swift", highlighted: colored))
        ListPerf.settle(window)
        #expect(editor.string == grown && editor.selectedRange() == selection)
        let shortened = "let sh"
        window.show(NWCodeBlock(shortened, language: "swift"))
        ListPerf.settle(window)
        #expect(editor.string == shortened && editor.selectedRange() == NSRange(location: 4, length: 2))
    }

    private func codeField(in view: NSView, code: String) -> NSTextField? {
        if let field = view as? NSTextField, field.stringValue == code { return field }
        for child in view.subviews {
            if let field = codeField(in: child, code: code) { return field }
        }
        return nil
    }
}
