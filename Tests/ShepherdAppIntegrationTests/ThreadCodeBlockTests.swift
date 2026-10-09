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
        let window = OffscreenWindow(size: CGSize(width: 480, height: 320), dark: false, NWCodeBlock(code, language: "swift"))
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
        let grown = code + "\nlet count = 42"
        window.show(NWCodeBlock(grown, language: "swift"))
        ListPerf.settle(window)
        #expect(editor.string == grown)
        #expect(editor.selectedRange() == selection)
        #expect(field.currentEditor() === editor)
        window.window.setContentSize(CGSize(width: 200, height: 320))
        ListPerf.settle(window)
        #expect(ListPerf.scrollView(in: window) == nil, "the narrower column still holds the code")
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
        codeFields(in: view, code: code).first
    }

    private func codeFields(in view: NSView, code: String) -> [NSTextField] {
        let own = (view as? NSTextField).flatMap { $0.stringValue == code ? [$0] : nil } ?? []
        return own + view.subviews.flatMap { codeFields(in: $0, code: code) }
    }
}
