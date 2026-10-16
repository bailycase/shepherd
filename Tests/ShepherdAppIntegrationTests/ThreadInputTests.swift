import AppKit
import Darwin
import GhosttyTerminal
import ShepherdRemote
import ShepherdTestSupport
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import ShepherdApp
@testable import TerminalSurfaceKit

@Suite("Thread input", .mainActorExclusive)
@MainActor
struct ThreadInputTests {
    @Test(arguments: ["direct", "menu", "shortcut", "context"])
    func clipboardImageUsesNativePaste(_ route: String) async throws {
        let diagnostics = try makeScratchDirectory("paste-diagnostics").appendingPathComponent("stderr.log")
        try #require(FileManager.default.createFile(atPath: diagnostics.path, contents: nil))
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) { [route = route as String, diagnosticsPath = diagnostics.path as String] in
            let stderr = dup(STDERR_FILENO)
            try #require(stderr >= 0)
            // Restore Testing's stream before its subprocess completion protocol runs.
            defer { dup2(stderr, STDERR_FILENO); close(stderr) }
            try Self.capturePasteDiagnostics(at: diagnosticsPath)
            await completingScenario { try await Self.pastingImage(route) }
        }
        // An unexpected termination returns nil, discarding observed stderr. The parent owns
        // this file, so even an AppKit exception/abort leaves its diagnostics available.
        let stderr = String(decoding: try Data(contentsOf: diagnostics), as: UTF8.self)
        if !stderr.isEmpty { print("Native Paste (\(route)) subprocess stderr:\n\(stderr)") }
        expectScenarioCompleted(result)
    }

    nonisolated private static func capturePasteDiagnostics(at path: String) throws {
        let file = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? file.close() }
        try #require(dup2(file.fileDescriptor, STDERR_FILENO) == STDERR_FILENO)
    }

    static func pastingImage(_ route: String) async throws {
        AccessibilityNode.enable()
        let thread = ComposerThread(focused: true, images: true)
        defer { thread.close() }
        try await thread.waitUntilReady()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let image = NSImage(size: NSSize(width: 2400, height: 1200), flipped: false) { rect in
            NSColor.red.setFill(); rect.fill(); return true
        }
        pasteboard.setData(try #require(image.tiffRepresentation), forType: .tiff)
        // A copied image may also offer text: attach the image, never insert that fallback.
        pasteboard.setString("image fallback text", forType: .string)
        let editor = try #require(thread.focusedEditor as? ComposerTextField.Editor)
        editor.pasteboard = { pasteboard }
        let menu = NSMenu(title: "Edit")
        let paste = menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        paste.keyEquivalentModifierMask = .command
        paste.target = editor
        #expect(editor.validateUserInterfaceItem(paste))
        var contextMenu: NSMenu?
        func pasteUsingRoute() throws {
            switch route {
            case "menu": menu.performActionForItem(at: 0)
            case "context":
                if contextMenu == nil {
                    let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
                        timestamp: 0, windowNumber: thread.window.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                    contextMenu = editor.menu(for: event)
                }
                // Reuse the actual native menu: generating it again with a synthetic click
                // at .zero selects the clicked word instead of preserving our text selection.
                let context = try #require(contextMenu)
                let index = try #require(context.items.firstIndex { $0.action == #selector(NSText.paste(_:)) })
                let item = context.items[index]
                #expect(editor.validateUserInterfaceItem(item))
                // The offscreen window is never key: route its native menu to its actual editor.
                item.target = editor
                context.performActionForItem(at: index)
            case "shortcut":
                let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                    timestamp: 0, windowNumber: thread.window.window.windowNumber, context: nil,
                    characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))
                #expect(menu.performKeyEquivalent(with: event))
            default: editor.paste(nil)
            }
        }
        try pasteUsingRoute()
        try await eventuallyOnMain("the pasted image to attach") { !thread.input.attachments.isEmpty }
        #expect(thread.store.draft.isEmpty)
        let attachment = try #require(thread.input.attachments.items.first)
        #expect(attachment.pixels == CGSize(width: 2000, height: 1000))
        #expect(attachment.image.mimeType == "image/png")
        #expect(attachment.source?.path.hasPrefix(AppImageDrop.directory.path) == true)
        try await eventuallyOnMain("the image chip to draw") { thread.window.element("Remove \(attachment.name)") != nil }
        let remove = try thread.window.press("Remove \(attachment.name)")
        #expect(ControlPress.undersized([remove], minimum: .desktop).isEmpty)
        #expect(thread.input.attachments.isEmpty)

        // AppKit owns the event groups; undo() closes the top-level group if still open.
        // Assert the text the user sees, not when an offscreen run loop closes that group.
        let undo = try #require(editor.undoManager)
        #expect(undo.groupsByEvent)
        func textState() -> String {
            "draft=\(String(reflecting: thread.store.draft)), editor=\(String(reflecting: editor.string)), selection=\(editor.selectedRange()), groupingLevel=\(undo.groupingLevel)"
        }
        var beforeUndo = "not reached"
        var replacement = [String]()
        do {
            // Plain text still goes through AppKit at the selection, with its ordinary undo.
            pasteboard.clearContents()
            pasteboard.setString("hello", forType: .string)
            try pasteUsingRoute()
            try await eventuallyOnMain("text paste to update the draft") { thread.store.draft == "hello" }
            // The replacement is a separate user event, after the first paste has rendered.
            try await thread.settle()
            replacement.append("Before selection: \(textState())")
            editor.setSelectedRange(NSRange(location: 1, length: 3))
            replacement.append("After selection: \(textState())")
            pasteboard.clearContents()
            pasteboard.setString("i", forType: .string)
            replacement.append("Before Paste: \(textState())")
            try #require(editor.selectedRange() == NSRange(location: 1, length: 3))
            try pasteUsingRoute()
            replacement.append("After Paste: \(textState())")
            try await eventuallyOnMain("text paste to replace the selection") { thread.store.draft == "hio" }
            beforeUndo = textState()
            try #require(undo.canUndo)
            undo.undo()
            try await eventuallyOnMain("undo to restore the selected text") { thread.store.draft == "hello" }
        } catch {
            FileHandle.standardError.write(Data("Native Paste (\(route)) before undo: \(beforeUndo)\n\(replacement.joined(separator: "\n"))\nAt failure: \(textState())\n".utf8))
            throw error
        }
        pasteboard.clearContents()
        pasteboard.setData(try #require(image.tiffRepresentation), forType: .tiff)
        editor.paste(nil)
        try await eventuallyOnMain("the image to be ready to send") { thread.input.attachments.items.count == 1 }
        let bytes = thread.input.attachments.images
        try await thread.settle()
        try thread.window.press("Send")
        try await eventuallyOnMain("the pasted bytes to reach the host") {
            thread.requests.contains { if case .send(_, _, _, let text, _, let images, _, _, _) = $0 { text == "hello" && images == bytes } else { false } }
        }
        try await eventuallyOnMain("the acknowledged image to leave the draft") { thread.input.attachments.isEmpty }
    }

    @Test func nativeComposerKeysKeepNewlinesCompletionAndSendingSeparate() async throws {
        let thread = ComposerThread(focused: true)
        defer { thread.close() }
        try await thread.waitUntilReady()
        let editor = try #require(thread.focusedEditor as? ComposerTextField.Editor)
        func key(_ code: UInt16, _ characters: String, modifiers: NSEvent.ModifierFlags = []) throws {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: thread.window.window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            editor.keyDown(with: event)
        }
        thread.type("before")
        try await thread.settle()
        try key(36, "\r", modifiers: .shift)
        try await eventuallyOnMain("Shift Return to add a line") { thread.store.draft == "before\n" }
        try key(36, "\r", modifiers: .option)
        try await eventuallyOnMain("Option Return to add a line") { thread.store.draft == "before\n\n" }
        #expect(!thread.requests.contains { if case .send = $0 { true } else { false } })
        thread.store.draft = "/"
        try await thread.settle()
        try key(125, "\u{f701}")
        try key(48, "\t")
        try await eventuallyOnMain("Tab to complete a slash command") { thread.store.draft != "/" }
        #expect(thread.store.draft.hasPrefix("/") && thread.store.draft.hasSuffix(" "))
        thread.store.draft = ""
        try await thread.settle()
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        try await thread.settle()
        #expect(editor.hasMarkedText(), "a render does not commit an input method's composition")
        try key(36, "\r")
        #expect(thread.store.sentCount == 0, "Return belongs to the input method until its marked text is committed")
        editor.unmarkText()
        thread.store.draft = "Send these words"
        thread.input.focus()
        try await thread.settle()
        try key(36, "\r")
        try await eventuallyOnMain("Return to send") { thread.store.sentCount == 1 }
        #expect(thread.store.draft.isEmpty)
    }

    @Test func aMultilineDraftGrowsToEightLinesWithoutLosingItsText() async throws {
        let thread = ComposerThread(focused: true)
        defer { thread.close() }
        try await thread.waitUntilReady()
        let short = thread.composerInset
        thread.store.draft = Array(repeating: "A line of the draft.", count: 8).joined(separator: "\n")
        try await thread.settle()
        let eight = thread.composerInset
        #expect(eight > short)
        thread.store.draft = Array(repeating: "A line of the draft.", count: 30).joined(separator: "\n")
        try await thread.settle()
        #expect(thread.composerInset == eight, "the editor scrolls rather than growing beyond its eight-line ceiling")
        let editor = try #require(thread.focusedEditor)
        #expect(editor.string == thread.store.draft)
        #expect(editor.selectedRange().location == (thread.store.draft as NSString).length)
        editor.scrollRangeToVisible(editor.selectedRange())
        thread.window.layout()
        let caret = editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: nil)
        let visible = thread.window.window.convertToScreen(editor.convert(editor.visibleRect, to: nil))
        #expect(visible.intersects(caret), "the end of a long draft remains reachable inside the scrolling field")
    }

    @Test(arguments: [false, true])
    func creationComposersUseTheSameNativeImagePaste(design: Bool) async throws {
        try StubPi.installAsEngine()
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await app.start()
        let window = OffscreenWindow(size: CGSize(width: 1000, height: 760))
        defer { window.close() }
        if design {
            vm.openNewDesign()
            window.show(NewDesignPage(vm: vm, chrome: PageHeaderChrome()))
        } else {
            vm.openNewThread()
            window.show(NewThreadPage(vm: vm, chrome: PageHeaderChrome()))
        }
        try await eventuallyOnMain("the creation composer to focus") {
            window.layout()
            return window.window.firstResponder is ComposerTextField.Editor
        }
        let editor = try #require(window.window.firstResponder as? ComposerTextField.Editor)
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        let image = ThreadImagesControlTests.attachment("clipboard.png", bytes: 0)
        clipboard.setData(image.image.data, forType: .png)
        editor.pasteboard = { clipboard }
        editor.paste(nil)
        try await eventuallyOnMain("the new draft to receive the image") {
            design ? !vm.newDesign.attachments.isEmpty : !vm.newThread.attachments.isEmpty
        }
        #expect(design ? vm.newDesign.brief.isEmpty : vm.newThread.prompt.isEmpty)
        #expect(!vm.newDesign.starting && !vm.newThread.starting)
    }

    @Test func filesAttachOnlyWhenTheThreadExplicitlyAcceptsLocalPaths() throws {
        let directory = try makeScratchDirectory("thread-input")
        let file = directory.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to: file)
        let local = NativeThreadStore(), remote = NativeThreadStore()
        let input = ThreadInput()
        input.add(urls: [file], store: local, localFiles: true)
        #expect(local.attachedFiles.map(\.path) == [file.path])
        #expect(input.attachments.error == nil)
        input.add(urls: [file], store: remote, localFiles: false)
        #expect(remote.attachedFiles.isEmpty)
        #expect(input.attachments.error?.contains("remote thread") == true)
    }

    @Test func anUnavailableComposerDoesNotRequestFocusOrAcceptProviders() async throws {
        let directory = try makeScratchDirectory("unavailable-input")
        let file = directory.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to: file)
        let loads = Locked(0)
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
            loads.withValue { $0 += 1 }
            completion(file.dataRepresentation, nil)
            return nil
        }
        let input = ThreadInput()
        let store = NativeThreadStore()
        input.focus()
        input.attach([provider], store: store, localFiles: true)
        await Task { @MainActor in }.value
        #expect(loads.current == 0)
        #expect(input.focusRequest == 0)
        #expect(input.attachments.isEmpty && store.attachedFiles.isEmpty)
        input.available = true
        input.focus()
        #expect(input.focusRequest == 1)
        input.attach([provider], store: store, localFiles: true)
        try await eventuallyOnMain("available input to resolve the real file provider") {
            store.attachedFiles.map(\.path) == [file.path]
        }
        #expect(loads.current == 1)
        input.available = false
        input.focus()
        #expect(input.focusRequest == 1)
    }

    @Test func aBackgroundFocusRequestReclaimsOnlyAnAvailableComposer() async throws {
        let input = ThreadInput()
        let store = NativeThreadStore()
        let window = OffscreenWindow(size: CGSize(width: 800, height: 400))
        defer { window.close() }
        window.show(Composer(store: store, input: input, active: true, isFocused: false,
                             agentName: nil, hasTurns: false, gutter: 20, listModels: { .empty }))
        try await eventuallyOnMain("composer input to become available") { input.available }
        input.focus()
        try await eventuallyOnMain("composer to claim the field") {
            (window.window.firstResponder as? NSTextView)?.isFieldEditor == true
        }
        window.window.makeFirstResponder(nil)
        input.available = false
        let before = input.focusRequest
        input.focus()
        #expect(input.focusRequest == before)
        #expect((window.window.firstResponder as? NSTextView)?.isFieldEditor != true)
    }

    @Test func terminalDropTargetsExcludeThreadSpaceAndHiddenSurfaces() async throws {
        let model = TerminalSurfaceModel()
        let window = OffscreenWindow(size: CGSize(width: 800, height: 400))
        defer { window.close() }
        window.show(HStack(spacing: 0) {
            TerminalSurfaceView(model: model, isFocused: false).frame(width: 400)
            Color.clear.frame(width: 400)
        })
        try await eventuallyOnMain("terminal surface to mount") {
            TerminalFirstResponder.view(ownedBy: model.viewState, in: window.window) != nil
        }
        let content = try #require(window.window.contentView)
        let surface = try #require(TerminalFirstResponder.view(ownedBy: model.viewState, in: window.window))
        let point = surface.convert(NSPoint(x: surface.bounds.midX, y: surface.bounds.midY), to: nil)
        let native = try #require(surface as? GhosttyTerminal.AppTerminalView)
        try await eventuallyOnMain("native drag registration") { native.onHostDrop != nil }
        #expect(native.registeredDraggedTypes.contains(.fileURL))
        #expect(native.acceptsHostDrop?() == true)
        let local = content.convert(point, from: nil)
        #expect(content.hitTest(local) === native, "ordinary hit testing is independent of any drag pasteboard")
        let cover = NSView(frame: content.convert(native.bounds, from: native))
        content.addSubview(cover, positioned: .above, relativeTo: nil)
        #expect(content.hitTest(local) === cover, "foreground controls, not covered terminals, own native hits")
        cover.removeFromSuperview()
        native.isHidden = true
        #expect(native.acceptsHostDrop?() == false)
        native.isHidden = false
        model.setRenderingActive(false)
        #expect(native.acceptsHostDrop?() == false)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(native.onHostDrop?(pasteboard) == false, "empty actual drag has nothing to insert")
    }
}
