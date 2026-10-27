import AppKit
import Foundation
import ShepherdProtocol
import Testing
@testable import ShepherdApp

/// The images a composer holds (the thread's and the New thread page's): what a send takes, and
/// what the composer says about what it left out.
@Suite("Composer attachments")
struct ComposerAttachmentsTests {
    static func image(_ name: String, bytes: Int = 4) -> (name: String, attachment: ImageAttachment?) {
        (name, ImageAttachment(name: name, image: NativeImage(mimeType: "image/png", data: Data(count: bytes))))
    }

    @Test func imagesJoinInOrderAndGoWithTheSend() {
        var attachments = ComposerAttachments()
        attachments.add([Self.image("a.png"), Self.image("b.png")])
        #expect(attachments.items.map(\.name) == ["a.png", "b.png"])
        #expect(attachments.images.count == 2 && attachments.error == nil && !attachments.isFull)
    }

    @Test @MainActor func imageDraftsSurviveThreadRemountsAndAreReleasedWithTheAgent() {
        let stores = NativeThreadStores<String>()
        let input = stores.input(for: "a")
        input.attachments.add([Self.image("a.png")])
        #expect(stores.input(for: "a") === input)
        #expect(stores.input(for: "a").attachments.images.count == 1)
        stores.prune(live: ["a"])
        #expect(stores.input(for: "a") === input)
        stores.prune(live: [])
        #expect(stores.input(for: "a").attachments.isEmpty)
    }

    @Test func aFifthImageIsLeftOutAndSaysWhy() {
        var attachments = ComposerAttachments()
        attachments.add((1...5).map { Self.image("\($0).png") })
        #expect(attachments.items.map(\.name) == ["1.png", "2.png", "3.png", "4.png"])
        #expect(attachments.isFull)
        #expect(attachments.error == "At most \(NativeImage.maxPerSend) images per message.")
    }

    /// A file the composer leaves out, and what it says.
    struct Refusal: Sendable, CustomTestStringConvertible {
        let name: String
        let attachment: ImageAttachment?
        let message: String
        var testDescription: String { name }
    }

    static let refusals: [Refusal] = [
        Refusal(name: "notes.txt", attachment: nil, message: "notes.txt is not an image Shepherd can attach."),
    ]

    @Test(arguments: refusals)
    func whatCannotGoIsSkippedAndTheRestStays(_ refused: Refusal) {
        var attachments = ComposerAttachments()
        attachments.add([Self.image("a.png"), (refused.name, refused.attachment), Self.image("b.png")])
        #expect(attachments.items.map(\.name) == ["a.png", "b.png"])
        #expect(attachments.error == refused.message)
    }

    @Test func theNextAddClearsTheLastError() {
        var attachments = ComposerAttachments()
        attachments.add([("notes.txt", nil)])
        #expect(attachments.error != nil)
        attachments.add([Self.image("a.png")])
        #expect(attachments.error == nil)
    }

    @Test func removingAndSendingEmptyIt() throws {
        var attachments = ComposerAttachments()
        attachments.add([Self.image("a.png"), Self.image("b.png")])
        attachments.remove(try #require(attachments.items.first).id)
        #expect(attachments.items.map(\.name) == ["b.png"])
        attachments.removeAll()
        #expect(attachments.isEmpty)
    }

    // ThreadImagesComposer: an image over the limit stays as a red chip and holds Send, instead of vanishing.
    @Test func anImageOverTheLimitStaysAndHoldsSendUntilItIsRemoved() throws {
        var attachments = ComposerAttachments()
        attachments.add([Self.image("a.png"), Self.image("big.png", bytes: NativeImage.maxBytes + 1)])
        #expect(attachments.items.map(\.name) == ["a.png", "big.png"])
        #expect(attachments.oversize?.name == "big.png")
        #expect(attachments.error == "big.png is over 2 MB after resizing. Remove it or send a smaller one.")
        attachments.remove(try #require(attachments.oversize).id)
        #expect(attachments.oversize == nil && attachments.error == nil)
    }

    @Test func aRefusalOutranksTheHeldSendLine() {
        var attachments = ComposerAttachments()
        attachments.add([Self.image("big.png", bytes: NativeImage.maxBytes + 1), ("notes.txt", nil)])
        #expect(attachments.error == "notes.txt is not an image Shepherd can attach.")
        attachments.clearError()
        #expect(attachments.error?.hasPrefix("big.png is over") == true)
    }

    @Test func aChipSaysItsSizeAndWhenItIsOver() throws {
        let fine = try #require(Self.image("a.png", bytes: 1_400_000).attachment)
        let big = try #require(Self.image("b.png", bytes: 3_100_000).attachment)
        #expect(fine.sizeLabel == "1.4 MB" && !fine.isOversize)
        #expect(big.sizeLabel == "3.1 MB · over 2 MB" && big.isOversize)
    }
}

/// Whether the New thread page's images can go where the thread would start: This Mac and a
/// current host take them with the opening prompt; an older host would drop them.
@Suite("New thread images")
@MainActor
struct NewThreadImagesTests {
    nonisolated static let image = NativeImage(mimeType: "image/png", data: Data(count: 4))
    nonisolated static let mib = 1024 * 1024

    @Test(arguments: [
        ([NativeImage](), "old", false, nil),
        ([image], nil, true, nil),
        ([image], "build-01", true, nil),
        ([image], "build-01", false, "Update Shepherd on build-01 to start a thread with images."),
        ([NativeImage](), "build-01", false, nil),
        (Array(repeating: NativeImage(mimeType: "image/png", data: Data(count: 2 * mib)), count: 3), nil, true,
         "The images come to over 5 MiB together. Remove one to send."),
    ] as [([NativeImage], String?, Bool, String?)])
    func imagesGoWhereTheOpeningPromptCanTakeThem(images: [NativeImage], host: String?, takesImages: Bool, refusal: String?) {
        #expect(NewThreadPlaces.imagesRefusal(images, host: host.map { ($0, takesImages) }) == refusal)
    }
}

@MainActor
@Suite("Image viewer")
struct ImageViewerStateTests {
    static func images(_ count: Int) -> [ViewerImage] {
        (0..<count).map { ViewerImage(attachment: ImageAttachment(name: "\($0).png", image: NativeImage(mimeType: "image/png", data: Data(count: 1_400_000)),
                                                                 pixels: CGSize(width: 1170, height: 2532))) }
    }

    @Test func itCountsAndStopsAtTheEnds() {
        let state = ImageViewerState(images: Self.images(2), origin: "Sent by you")
        #expect(state.position == "1 of 2" && !state.hasPrevious && state.hasNext)
        state.previous()
        #expect(state.current?.name == "0.png")
        state.next(); state.next()
        #expect(state.current?.name == "1.png" && state.position == "2 of 2" && !state.hasNext)
    }

    @Test func oneImageHasNoPositionOrArrows() {
        let state = ImageViewerState(images: Self.images(1), origin: "Sent by you")
        #expect(state.position == nil && !state.hasPrevious && !state.hasNext)
    }

    @Test func anIndexOutsideTheImagesOpensTheFirst() {
        #expect(ImageViewerState(images: Self.images(2), index: 9, origin: "").current?.name == "0.png")
        #expect(ImageViewerState(images: [], origin: "").current == nil)
    }

    @Test func theBarSaysSizeFormatAndSize() throws {
        let image = try #require(Self.images(1).first)
        #expect(image.facts == "1170 × 2532 · PNG · 1.4 MB")
    }

    // The picture is decoded once, when the viewer's value is made, and only if the header says it is a sane raster.
    @Test func theViewerDecodesOnceAndRefusesWhatIsNotARasterImage() throws {
        let png = try #require(NSBitmapImageRep(data: NSImage(size: NSSize(width: 4, height: 4), flipped: false) { NSColor.red.setFill(); $0.fill(); return true }.tiffRepresentation!)?
            .representation(using: .png, properties: [:]))
        let good = ViewerImage(attachment: ImageAttachment(name: "a.png", image: NativeImage(mimeType: "image/png", data: png)))
        #expect(good.picture != nil)
        #expect(ViewerImage(attachment: ImageAttachment(name: "b.png", image: NativeImage(mimeType: "image/png", data: Data(count: 64)))).picture == nil)
        #expect(ViewerImage.decode(Data("<html></html>".utf8)) == nil)
        #expect(ViewerImage.acceptedSize(Data("<html></html>".utf8)) == nil)
    }

    /// A dropped file is read once, off the main actor: the header gives its pixels, ImageIO a thumbnail no larger than the
    /// thread's, and a file that is not a raster image reads as none.
    @Test func aFileIsReadOnceWithItsPixelsAndAScaledThumbnail() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("image-file-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let png = folder.appendingPathComponent("wide.png")
        try Self.flat(1600).write(to: png)
        let file = try #require(ImageFile(url: png))
        #expect(file.pixels == CGSize(width: 1600, height: 1600))
        #expect(file.mimeType == "image/png")
        #expect(file.thumbnail.map { CGFloat($0.width) } == ThreadImageLoad.thumbnailPixels)
        let attachment = ImageAttachment(file)
        #expect(attachment.pixels == file.pixels && attachment.thumbnail != nil && attachment.source == png)
        let text = folder.appendingPathComponent("notes.png")
        try Data("not a picture".utf8).write(to: text)
        #expect(ImageFile(url: text) == nil)
        #expect(ImageAttachment(url: text) == nil)
    }

    /// A flat image of `side` × `side` pixels, small on disk (a flat colour compresses to almost nothing).
    static func flat(_ side: Int, type: NSBitmapImageRep.FileType = .png) throws -> Data {
        try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)?
            .representation(using: type, properties: [:]))
    }

    /// The viewer holds the one bound the host and client hold, `NativeImage.maxPixels` (4096 × 4096): an image the thread accepted is
    /// drawn, including one between the viewer's old 2400² limit and that bound, and one past it is refused from its header.
    @Test func theViewerDrawsWhatTheThreadAcceptsUpToTheSharedBound() throws {
        let between = try Self.flat(3000)
        #expect(3000 * 3000 > 2400 * 2400 && 3000 * 3000 <= NativeImage.maxPixels)
        #expect(between.count <= NativeImage.maxBytes)
        #expect(ViewerImage.acceptedSize(between) == CGSize(width: 3000, height: 3000))
        #expect(ViewerImage.decode(between) != nil, "an accepted image is displayed, not unavailable")
        let atBound = try Self.flat(4096)
        #expect(ViewerImage.acceptedSize(atBound) == CGSize(width: 4096, height: 4096) && ViewerImage.decode(atBound) != nil)
        let over = try Self.flat(4097)
        #expect(over.count <= NativeImage.maxBytes && ViewerImage.acceptedSize(over) == nil && ViewerImage.decode(over) == nil,
                "4097² is over the bound: refused from its header")
    }

    /// A transcript thumbnail never decodes the whole bitmap: ImageIO scales while it decodes.
    @Test func aThumbnailIsDecodedNoLargerThanItsBox() throws {
        let big = try Self.flat(4000)
        let thumb = try #require(ViewerImage.thumbnail(big, longestSide: 768))
        let rep = try #require(thumb.representations.first)
        #expect(max(rep.pixelsWide, rep.pixelsHigh) <= 768, "decoded at \(rep.pixelsWide) × \(rep.pixelsHigh)")
        #expect(ViewerImage.thumbnail(try Self.flat(4097), longestSide: 768) == nil)
    }

    /// A type the thread does not offer is refused by what the bytes are, not by what they are called.
    @Test func theViewerRefusesATypeItDoesNotOffer() throws {
        let tiff = try Self.flat(8, type: .tiff)
        #expect(ViewerImage.acceptedSize(tiff) == nil && ViewerImage.decode(tiff) == nil)
    }
}
