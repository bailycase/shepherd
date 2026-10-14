import AppKit
import Foundation
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp

/// Every control the ThreadImage boards draw, pressed the way VoiceOver presses (`ControlPress`) on the real thread, composer
/// and store, each scenario in a process of its own (docs/testing.md › Pressing a control).
///
/// - ThreadImagesComposer: the chips' × and Send with an image over 2 MiB.
/// - ThreadImagesSent: a sent thumbnail opens the viewer.
/// - ThreadImageOpen: Previous, Next, Copy, Add to message, Show in Finder and Close.
@Suite("Thread image controls", .integrationTimeLimit)
struct ThreadImageControlTests {
    @Test func anImageOverTheLimitKeepsSendOffUntilItsRemoveButtonIsPressed() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.oversized() }
        }
    }

    @Test func aSentThumbnailOpensTheViewerAndEveryViewerControlWorks() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.viewing() }
        }
    }

    // MARK: Fixtures

    @MainActor
    static func png(_ width: Int, _ height: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    @MainActor
    static func thread() async throws -> ComposerThread {
        let thread = ComposerThread(messages: 2, focused: true)
        try await thread.waitUntilReady()
        await thread.addImageSupport()
        try await eventuallyOnMain("the host to offer images") { thread.store.supportedActions.contains("sendImages") }
        return thread
    }

    /// The first control with `label`, and its hit area: every image control meets the Mac's 24pt minimum.
    @MainActor
    static func assertHitAreas(_ thread: ComposerThread, labels: [String]) {
        let controls = thread.window.controls().filter { control in labels.contains { control.label?.hasPrefix($0) == true } }
        #expect(controls.count >= labels.count, "\(labels) in \(thread.window.controls().compactMap(\.label))")
        #expect(ControlPress.undersized(controls, minimum: .desktop).isEmpty, "\(ControlPress.undersized(controls, minimum: .desktop))")
    }

    // MARK: Scenarios

    @MainActor
    static func oversized() async throws {
        AccessibilityNode.enable()
        let thread = try await Self.thread()
        defer { thread.close() }
        thread.store.draft = "Here it is on the mini and the Pro Max."
        thread.input.attachments.add([
            ("after-mini.png", ImageAttachment(name: "after-mini.png", image: NativeImage(mimeType: "image/png", data: Data(count: 1_400_000), name: "after-mini.png"))),
            ("after-promax.png", ImageAttachment(name: "after-promax.png", image: NativeImage(mimeType: "image/png", data: Data(count: 3_100_000), name: "after-promax.png"))),
        ])
        try await thread.settle()

        // Both chips, the one over the limit named, the line that says how to fix it, and Send held back.
        #expect(thread.window.element("Remove after-mini.png") != nil && thread.window.element("Remove after-promax.png") != nil)
        let line = "after-promax.png is over 2 MB after resizing. Remove it or send a smaller one."
        #expect(thread.window.text(line) != nil, "the line that says how to fix it")
        #expect(throws: ControlPressError.self, "Send is disabled while an image is over the limit") { try thread.window.press("Send") }
        assertHitAreas(thread, labels: ["Remove after-mini.png", "Remove after-promax.png"])

        // The remove button on the big one clears the problem, keeps the other chip, and lets Send go with that image alone.
        try thread.window.press("Remove after-promax.png")
        try await thread.settle()
        #expect(thread.input.attachments.items.map(\.name) == ["after-mini.png"])
        #expect(thread.window.element("Remove after-promax.png") == nil && thread.window.text(line) == nil)
        try thread.window.press("Send")
        try await eventuallyOnMain("the send to carry the image that was left") {
            thread.requests.contains { $0.images.map(\.name) == ["after-mini.png"] && $0.images.first?.data.count == 1_400_000 }
        }
        try await eventuallyOnMain("the sent image to leave the composer") { thread.input.attachments.isEmpty }
    }

    @MainActor
    static func viewing() async throws {
        AccessibilityNode.enable()
        let thread = try await Self.thread()
        defer { thread.close() }
        let images = [NativeImage(mimeType: "image/png", data: png(1170, 2532), name: "checkout-iphone.png"),
                      NativeImage(mimeType: "image/png", data: png(2880, 1800), name: "refunds-dashboard.png")]
        thread.store.draft = "Both screenshots are from an iPhone 15 mini."
        thread.input.attachments.add(images.map { ($0.name ?? "", ImageAttachment(name: $0.name ?? "", image: $0)) })
        try thread.window.press("Send")
        try await eventuallyOnMain("the echo's thumbnails") {
            thread.window.element("Open checkout-iphone.png, 1170 by 2532") != nil
        }
        // The board's accessibility names for the two thumbnails.
        #expect(thread.window.element("Open refunds-dashboard.png, 2880 by 1800") != nil)
        #expect(thread.window.element("2 images you sent") != nil)
        assertHitAreas(thread, labels: ["Open checkout-iphone.png", "Open refunds-dashboard.png"])
        #expect(thread.window.element("Image: checkout-iphone.png") == nil, "the viewer is closed at rest")

        // Press the first thumbnail: the viewer opens over the thread on it, with its metadata.
        var revealed: [URL] = []
        thread.viewer.effects.reveal = { revealed.append($0) }
        thread.viewer.effects.exportDirectory = { FileManager.default.temporaryDirectory.appending(path: "viewer-\(UUID().uuidString)") }
        try thread.window.press("Open checkout-iphone.png, 1170 by 2532")
        try await eventuallyOnMain("the viewer to open and decode") { thread.viewer.current?.name == "checkout-iphone.png" && thread.viewer.pictures[thread.viewer.current?.id ?? ""] != nil }
        try await thread.settle()
        #expect(thread.window.element("Image: checkout-iphone.png") != nil)
        #expect(thread.window.text("1 of 2") != nil && thread.window.text("Sent by you · Esc to close") != nil)
        #expect(thread.window.elements().contains { ($0.label ?? $0.value)?.hasPrefix("1170 × 2532 · PNG · ") == true })
        assertHitAreas(thread, labels: ["Copy image", "Add to message", "Show in Finder", "Close", "Next image"])
        #expect(try #require(thread.window.controls().first { $0.label == "Previous image" }).isEnabled == false, "first image: nothing before it")

        // Next → the second image; Previous returns.
        try thread.window.press("Next image")
        try await eventuallyOnMain("the second image") { thread.viewer.current?.name == "refunds-dashboard.png" }
        #expect(thread.window.text("2 of 2") != nil)
        #expect(thread.window.controls().first { $0.label == "Next image" }?.isEnabled == false)
        try thread.window.press("Previous image")
        try await eventuallyOnMain("the first image again") { thread.viewer.current?.name == "checkout-iphone.png" }

        // Show in Finder: a sent image has no file, so it is written under its own name and that is revealed.
        try thread.window.press("Show in Finder")
        let url = try #require(revealed.first)
        #expect(url.lastPathComponent == "checkout-iphone.png" && FileManager.default.fileExists(atPath: url.path))

        // Copy: confirms in place.
        var copied: [String] = []
        thread.viewer.effects.copy = { copied.append($0.name) }
        try thread.window.press("Copy image")
        #expect(copied == ["checkout-iphone.png"])

        // Add to message: the image joins the composer as a chip, and the viewer closes. The send already took the first two.
        try thread.window.press("Add to message")
        try await eventuallyOnMain("the viewer to close and the chip to appear") {
            !thread.viewer.isOpen && thread.input.attachments.items.map(\.name) == ["checkout-iphone.png"]
        }

        // Close.
        try thread.window.press("Open refunds-dashboard.png, 2880 by 1800")
        try await eventuallyOnMain("the viewer to open") { thread.viewer.current?.name == "refunds-dashboard.png" }
        try thread.window.press("Close")
        try await eventuallyOnMain("the viewer to close") { !thread.viewer.isOpen }
        #expect(thread.window.element("Image: refunds-dashboard.png") == nil)
    }
}

extension OffscreenWindow {
    /// Static text that says `words`, whether the tree gives it as a label or as a value.
    @MainActor func text(_ words: String) -> AccessibilityNode? {
        elements().first { $0.label == words || $0.value == words }
    }
}
