import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import TerminalSurfaceKit

/// Dragging a file from Finder carries a file URL. Dragging a *screenshot* —
/// from the macOS thumbnail, a browser, or Preview — carries raw image data
/// with no file behind it, which a URL-only drop destination never sees. Those
/// have to be written to disk before the terminal can reference them.
@Suite("Terminal image drops")
struct TerminalImageDropTests {
    private func pngData(_ color: NSColor = .red) -> Data {
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        color.drawSwatch(in: NSRect(x: 0, y: 0, width: 8, height: 8))
        image.unlockFocus()
        let tiff = image.tiffRepresentation!
        return NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
    }

    private func tiffData() -> Data {
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.blue.drawSwatch(in: NSRect(x: 0, y: 0, width: 8, height: 8))
        image.unlockFocus()
        return image.tiffRepresentation!
    }

    /// Oversized drops are downscaled where they enter Shepherd.
    /// An oversized screenshot otherwise becomes
    /// permanent weight: the harness writes it into the session transcript and
    /// every later load re-emits it.
    @Test func computesResizedDimensions() {
        // Within budget: untouched.
        #expect(TerminalImageDrop.resizedDimensions(width: 1920, height: 1080) == nil)
        #expect(TerminalImageDrop.resizedDimensions(width: 2000, height: 2000) == nil)

        // Longest edge clamped, aspect ratio preserved.
        let wide = TerminalImageDrop.resizedDimensions(width: 5120, height: 1440)
        #expect(wide?.width == 2000)
        #expect(wide?.height == 563)

        let tall = TerminalImageDrop.resizedDimensions(width: 1000, height: 4000)
        #expect(tall?.width == 500)
        #expect(tall?.height == 2000)

        // Never collapses to zero.
        let sliver = TerminalImageDrop.resizedDimensions(width: 8000, height: 1)
        #expect(sliver?.width == 2000)
        #expect(sliver?.height == 1)

        // Degenerate input is ignored rather than trapped.
        #expect(TerminalImageDrop.resizedDimensions(width: 0, height: 100) == nil)
    }

    /// A retina screenshot is the case that caused this: 5120x1440 PNGs went
    /// into the transcript whole.
    @Test func oversizedDropIsDownscaled() async throws {
        let big = NSImage(size: NSSize(width: 5120, height: 1440))
        big.lockFocus()
        NSColor.systemTeal.drawSwatch(in: NSRect(x: 0, y: 0, width: 5120, height: 1440))
        big.unlockFocus()
        let data = NSBitmapImageRep(data: big.tiffRepresentation!)!
            .representation(using: .png, properties: [:])!

        let provider = NSItemProvider(item: data as NSData, typeIdentifier: UTType.png.identifier)
        let url = try #require(await TerminalImageDrop.resolve([provider]).first)
        defer { try? FileManager.default.removeItem(at: url) }

        let written = try #require(NSBitmapImageRep(data: try Data(contentsOf: url)))
        #expect(written.pixelsWide == 2000)
        #expect(written.pixelsHigh == 563)
        #expect(try Data(contentsOf: url).count < data.count)
    }

    /// An image already within budget keeps its exact pixels — resizing must
    /// not degrade ordinary drops.
    @Test func imagesWithinBudgetAreNotResized() async throws {
        let data = pngData()
        let provider = NSItemProvider(item: data as NSData, typeIdentifier: UTType.png.identifier)
        let url = try #require(await TerminalImageDrop.resolve([provider]).first)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(try Data(contentsOf: url) == data)
    }

    /// A dropped *file* that is oversized is copied down, and the user's
    /// original file is never modified.
    @Test func oversizedDroppedFileIsCopiedDownAndOriginalUntouched() async throws {
        let big = NSImage(size: NSSize(width: 4000, height: 3000))
        big.lockFocus()
        NSColor.systemPink.drawSwatch(in: NSRect(x: 0, y: 0, width: 4000, height: 3000))
        big.unlockFocus()
        let data = NSBitmapImageRep(data: big.tiffRepresentation!)!
            .representation(using: .png, properties: [:])!

        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("shepherd-big-\(UUID().uuidString).png")
        try data.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let provider = NSItemProvider(contentsOf: source)!
        let url = try #require(await TerminalImageDrop.resolve([provider]).first)

        #expect(url != source, "an oversized file should be referenced via a resized copy")
        defer { try? FileManager.default.removeItem(at: url) }

        let written = try #require(NSBitmapImageRep(data: try Data(contentsOf: url)))
        #expect(max(written.pixelsWide, written.pixelsHigh) == 2000)
        // The user's file is theirs; we never rewrite it.
        #expect(try Data(contentsOf: source) == data)
    }

    @Test func acceptsBothFilesAndRawImages() {
        // A URL-only destination is what made screenshot drags no-ops.
        #expect(TerminalImageDrop.acceptedTypes.contains(.fileURL))
        #expect(TerminalImageDrop.acceptedTypes.contains(.image))
    }

    /// A file drag already has a path, so it must be used as-is rather than
    /// copied into the drop directory.
    @Test func fileURLProvidersResolveToTheOriginalPath() async throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("shepherd-drop-src-\(UUID().uuidString).png")
        try pngData().write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let provider = NSItemProvider(contentsOf: source)!
        let resolved = await TerminalImageDrop.resolve([provider])

        #expect(resolved.count == 1)
        #expect(resolved.first?.path == source.path)
    }

    /// The screenshot case: data with no file behind it becomes a real path.
    @Test func rawImageDataIsWrittenToAFile() async throws {
        let data = pngData()
        let provider = NSItemProvider(item: data as NSData, typeIdentifier: UTType.png.identifier)

        let resolved = await TerminalImageDrop.resolve([provider])
        #expect(resolved.count == 1)
        let url = try #require(resolved.first)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(url.pathExtension == "png")
        #expect(try Data(contentsOf: url) == data)
        // Written where drops are collected, not somewhere arbitrary.
        #expect(url.deletingLastPathComponent().lastPathComponent == "shepherd-drops")
    }

    /// macOS screenshot drags carry TIFF, which most image consumers cannot
    /// read, so it is re-encoded as PNG.
    @Test func tiffIsReEncodedAsPNG() async throws {
        let provider = NSItemProvider(item: tiffData() as NSData, typeIdentifier: UTType.tiff.identifier)

        let resolved = await TerminalImageDrop.resolve([provider])
        let url = try #require(resolved.first)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(url.pathExtension == "png")
        // PNG magic number, i.e. genuinely converted rather than renamed.
        let head = try Data(contentsOf: url).prefix(8)
        #expect(Array(head) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    /// Dropping the same screenshot twice must not collide: a tool may still
    /// be reading the first one.
    @Test func repeatedDropsGetDistinctPaths() async throws {
        let data = pngData()
        func drop() async -> URL? {
            let provider = NSItemProvider(item: data as NSData, typeIdentifier: UTType.png.identifier)
            return await TerminalImageDrop.resolve([provider]).first
        }

        let first = try #require(await drop())
        let second = try #require(await drop())
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        #expect(first.path != second.path)
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
    }

    /// A drag carrying neither a file nor an image (e.g. plain text) yields
    /// nothing rather than a bogus path.
    @Test func nonImageProvidersAreIgnored() async {
        let provider = NSItemProvider(item: "hello" as NSString, typeIdentifier: UTType.plainText.identifier)
        #expect(await TerminalImageDrop.resolve([provider]).isEmpty)
    }
}
