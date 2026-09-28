import AppKit
import ShepherdRemote
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp
@testable import TerminalSurfaceKit

@Suite("Thread input", .mainActorExclusive)
@MainActor
struct ThreadInputTests {
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

    @Test func anUnavailableComposerDoesNotRequestFocusOrAcceptProviders() {
        let input = ThreadInput()
        let store = NativeThreadStore()
        input.focus()
        input.attach([], store: store, localFiles: true)
        #expect(input.focusRequest == 0)
        #expect(input.attachments.isEmpty && store.attachedFiles.isEmpty)
        input.available = true
        input.focus()
        #expect(input.focusRequest == 1)
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
        let overlay = TerminalDropOverlayView(frame: content.bounds)
        content.addSubview(overlay)
        let surface = try #require(TerminalFirstResponder.view(ownedBy: model.viewState, in: window.window))
        let point = surface.convert(NSPoint(x: surface.bounds.midX, y: surface.bounds.midY), to: nil)
        #expect(overlay.targetModel(at: point) === model)
        let blank = content.convert(NSPoint(x: content.bounds.maxX - 20, y: content.bounds.midY), to: nil)
        #expect(overlay.targetModel(at: blank) == nil)
        model.setRenderingActive(false)
        #expect(overlay.targetModel(at: point) == nil)
    }
}
