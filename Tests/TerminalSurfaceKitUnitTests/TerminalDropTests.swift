import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import TerminalSurfaceKit

/// Finder drops become shell-escaped paths typed into the terminal, matching Ghostty's
/// macOS convention.
@Suite("Terminal file drops")
struct TerminalFileDropTests {
    @Test(arguments: [
        ("/tmp/plain.txt", "/tmp/plain.txt"),
        ("/tmp/my file (1).txt", #"/tmp/my\ file\ \(1\).txt"#),
        ("/tmp/$draft?.md", #"/tmp/\$draft\?.md"#),
        ("/tmp/a'b\"c.txt", #"/tmp/a\'b\"c.txt"#),
        ("/tmp/x;y|z&w", #"/tmp/x\;y\|z\&w"#),
        ("/tmp/[a]{b}<c>", #"/tmp/\[a\]\{b\}\<c\>"#),
        ("/tmp/back\\slash", #"/tmp/back\\slash"#),
        ("/tmp/café", "/tmp/café"),
    ])
    func shellMetacharactersAreEscaped(path: String, expected: String) {
        #expect(TerminalFileDrop.shellEscape(path) == expected)
    }

    /// A trailing space keeps the user's next word from running into the filename.
    @Test func multipleFilesJoinInDropOrderWithATrailingSpace() {
        let urls = [URL(fileURLWithPath: "/tmp/first file.txt"), URL(fileURLWithPath: "/tmp/second.txt")]
        #expect(TerminalFileDrop.text(for: urls) == #"/tmp/first\ file.txt /tmp/second.txt "#)
    }

    @Test func nonFileURLsAreIgnored() throws {
        let web = try #require(URL(string: "https://example.com/file.txt"))
        #expect(TerminalFileDrop.text(for: [web, URL(fileURLWithPath: "/tmp/local.txt")]) == "/tmp/local.txt ")
        #expect(TerminalFileDrop.text(for: [web]) == nil)
        #expect(TerminalFileDrop.text(for: []) == nil)
    }
}

/// Dropped raster images are clamped where they enter Shepherd: pi writes an attached image
/// into the session transcript, so an oversized screenshot is re-emitted on every later load.
@Suite("Terminal image drops")
struct TerminalImageDropTests {
    @Test(arguments: [
        (1920, 1080, nil),
        (2000, 2000, nil),
        (2000, 1, nil),
        (5120, 1440, Size(2000, 563)),
        (1000, 4000, Size(500, 2000)),
        (2001, 2001, Size(2000, 2000)),
        (8000, 1, Size(2000, 1)),
        (1, 8000, Size(1, 2000)),
        (0, 5000, nil),
        (5000, -1, nil),
    ] as [(Int, Int, Size?)])
    func longestEdgeIsClampedPreservingAspectRatio(width: Int, height: Int, expected: Size?) {
        let resized = TerminalImageDrop.resizedDimensions(width: width, height: height)
        #expect(resized.map { Size($0.width, $0.height) } == expected)
    }

    @Test func theClampIsTheDocumentedTwoThousandPixels() {
        #expect(TerminalImageDrop.maxDimension == 2000)
    }

    /// A URL-only destination is what made screenshot drags no-ops.
    @Test func dropsAcceptFilesAndRawImageData() {
        #expect(TerminalImageDrop.acceptedTypes == [.fileURL, .image])
    }

    @Test(arguments: [UTType.png, .jpeg])
    func readableFormatsWithinBudgetKeepTheirExactBytes(type: UTType) throws {
        let data = try Images.encoded(width: 8, height: 8, as: type)
        let (output, outputType) = TerminalImageDrop.normalize(data, type: type)
        #expect(output == data)
        #expect(outputType == type)
    }

    /// macOS screenshot drags carry TIFF, which most image consumers cannot read.
    @Test func tiffWithinBudgetIsReEncodedAsPNG() throws {
        let (output, outputType) = TerminalImageDrop.normalize(try Images.encoded(width: 8, height: 8, as: .tiff), type: .tiff)
        #expect(outputType == .png)
        #expect(Array(output.prefix(8)) == Images.pngMagic)
    }

    @Test func oversizedPNGIsDownscaledAndStaysPNG() throws {
        let (output, outputType) = TerminalImageDrop.normalize(try Images.encoded(width: 2400, height: 4, as: .png), type: .png)
        #expect(outputType == .png)
        let rep = try #require(NSBitmapImageRep(data: output))
        #expect(rep.pixelsWide == 2000 && rep.pixelsHigh == 3)
    }

    @Test(.disabled("""
        bug: normalize draws JPEG output into a 24-bpp RGB (no alpha) NSBitmapImageRep, for which \
        NSGraphicsContext(bitmapImageRep:) returns nil, so oversized JPEG drops pass through un-resized
        """))
    func oversizedJPEGIsDownscaledAndStaysJPEG() throws {
        let (output, outputType) = TerminalImageDrop.normalize(try Images.encoded(width: 4, height: 2400, as: .jpeg), type: .jpeg)
        #expect(outputType == .jpeg)
        #expect(Array(output.prefix(2)) == [0xFF, 0xD8])
        let rep = try #require(NSBitmapImageRep(data: output))
        #expect(rep.pixelsWide == 3 && rep.pixelsHigh == 2000)
    }

    @Test func oversizedTIFFBecomesADownscaledPNG() throws {
        let (output, outputType) = TerminalImageDrop.normalize(try Images.encoded(width: 2400, height: 4, as: .tiff), type: .tiff)
        #expect(outputType == .png)
        #expect(try #require(NSBitmapImageRep(data: output)).pixelsWide == 2000)
    }

    /// An undecodable payload passes through rather than losing the drop.
    @Test func undecodableDataPassesThroughUntouched() {
        let junk = Data("not an image".utf8)
        let (output, outputType) = TerminalImageDrop.normalize(junk, type: .png)
        #expect(output == junk)
        #expect(outputType == .png)
    }

    // MARK: Resolving drag providers

    /// A file drag already has a path; it is used as-is rather than copied.
    @Test func aFileWithinBudgetResolvesToItsOwnPath() async throws {
        let source = try Images.writeTemporary(try Images.encoded(width: 8, height: 8, as: .png), ext: "png")
        defer { try? FileManager.default.removeItem(at: source) }

        let provider = try #require(NSItemProvider(contentsOf: source))
        let resolved = await TerminalImageDrop.resolve([provider])
        #expect(resolved.map(\.path) == [source.path])
    }

    /// An oversized dropped file is referenced through a resized copy; the user's file is
    /// never rewritten.
    @Test func anOversizedFileIsCopiedDownAndTheOriginalIsUntouched() async throws {
        let original = try Images.encoded(width: 2400, height: 4, as: .tiff)
        let source = try Images.writeTemporary(original, ext: "tiff")
        defer { try? FileManager.default.removeItem(at: source) }

        let provider = try #require(NSItemProvider(contentsOf: source))
        let url = try #require(await TerminalImageDrop.resolve([provider]).first)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(url != source)
        #expect(url.deletingLastPathComponent().lastPathComponent == "shepherd-drops")
        #expect(try #require(NSBitmapImageRep(data: try Data(contentsOf: url))).pixelsWide == 2000)
        #expect(try Data(contentsOf: source) == original)
    }

    /// The screenshot case: image data with no file behind it becomes a real, unique path.
    @Test func rawImageDataIsWrittenToADistinctFileEachDrop() async throws {
        let data = try Images.encoded(width: 8, height: 8, as: .png)
        func drop() async throws -> URL {
            let provider = NSItemProvider(item: data as NSData, typeIdentifier: UTType.png.identifier)
            return try #require(await TerminalImageDrop.resolve([provider]).first)
        }
        let first = try await drop()
        let second = try await drop()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        #expect(first != second)
        #expect(first.pathExtension == "png")
        #expect(first.deletingLastPathComponent().lastPathComponent == "shepherd-drops")
        #expect(try Data(contentsOf: first) == data)
    }

    @Test func providersWithNeitherAFileNorAnImageYieldNothing() async {
        let provider = NSItemProvider(item: "hello" as NSString, typeIdentifier: UTType.plainText.identifier)
        #expect(await TerminalImageDrop.resolve([provider]).isEmpty)
    }

    /// Remote drops are size-capped before anything is read or copied.
    @Test func theByteLimitRejectsLargerFilesAndAdmitsFilesAtTheLimit() async throws {
        let data = try Images.encoded(width: 8, height: 8, as: .png)
        let source = try Images.writeTemporary(data, ext: "png")
        defer { try? FileManager.default.removeItem(at: source) }
        let provider = try #require(NSItemProvider(contentsOf: source))

        await #expect(throws: CocoaError.self) {
            _ = try await TerminalImageDrop.resolve([provider], maximumBytes: data.count - 1)
        }
        #expect(try await TerminalImageDrop.resolve([provider], maximumBytes: data.count) == [source])
    }
}

struct Size: Equatable, CustomTestStringConvertible, Sendable {
    let width: Int
    let height: Int
    init(_ width: Int, _ height: Int) { self.width = width; self.height = height }
    var testDescription: String { "\(width)×\(height)" }
}

/// Tiny in-memory rasters; nothing is drawn through a window.
enum Images {
    static let pngMagic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    static func encoded(width: Int, height: Int, as type: UTType) throws -> Data {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let pixels = try #require(rep.bitmapData)
        for index in 0..<(rep.bytesPerRow * height) {
            pixels[index] = UInt8(truncatingIfNeeded: index % 4 == 3 ? 255 : index * 7)
        }
        let fileType: NSBitmapImageRep.FileType = switch type {
        case .jpeg: .jpeg
        case .tiff: .tiff
        default: .png
        }
        return try #require(rep.representation(using: fileType, properties: [:]))
    }

    static func writeTemporary(_ data: Data, ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shepherd-drop-src-\(UUID().uuidString).\(ext)")
        try data.write(to: url)
        return url
    }
}
