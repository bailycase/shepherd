import Foundation
import ShepherdProtocol
import ShepherdUI
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
        Refusal(name: "big.png", attachment: image("big.png", bytes: NativeImage.maxBytes + 1).attachment,
                message: "big.png is over 2 MiB after resizing."),
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

    /// ThreadImagesComposer: a thread's composer keeps the image that is over 2 MiB after resizing, marked and named, so the
    /// person sees which one to remove; Send waits (`problem`) until it is gone. The New thread page leaves it out instead.
    @Test func aThreadKeepsAnImageOverTheLimitAndNamesItUntilItIsRemoved() throws {
        var attachments = ComposerAttachments(keepsOversized: true)
        attachments.add([ComposerAttachmentsTests.image("after-mini.png", bytes: 1_400_000), ComposerAttachmentsTests.image("after-promax.png", bytes: NativeImage.maxBytes + 1_000_000)])
        #expect(attachments.items.map(\.name) == ["after-mini.png", "after-promax.png"] && attachments.error == nil)
        #expect(attachments.items.map(\.tooLarge) == [false, true])
        #expect(attachments.items[1].sizeText.hasSuffix("over 2 MB"), "\(attachments.items[1].sizeText)")
        #expect(attachments.problem == "after-promax.png is over 2 MB after resizing. Remove it or send a smaller one.")
        attachments.remove(attachments.items[1].id)
        #expect(attachments.problem == nil && attachments.items.map(\.name) == ["after-mini.png"])
    }

    /// The chip's size and its limit are counted in one unit: an image of exactly the limit fits and reads "2 MB", one byte over is
    /// over and reads "over 2 MB", so the chip never shows "2.1 MB" for an image that is allowed.
    @Test func theChipsSizeAndTheLimitAreCountedInTheSameUnit() {
        var attachments = ComposerAttachments(keepsOversized: true)
        attachments.add([ComposerAttachmentsTests.image("fits.png", bytes: NativeImage.maxBytes), ComposerAttachmentsTests.image("over.png", bytes: NativeImage.maxBytes + 1)])
        #expect(attachments.items.map(\.tooLarge) == [false, true])
        #expect(attachments.items[0].sizeText == "2 MB", "\(attachments.items[0].sizeText)")
        #expect(attachments.items[1].sizeText.hasSuffix("over 2 MB"))
        #expect(NWByteText.limit(mebibytes: NativeImage.maxBytes / 1024 / 1024) == "2 MB")
    }

    @Test func imagesThatTogetherCannotTravelInOneSendAreAProblemToo() {
        var attachments = ComposerAttachments(keepsOversized: true)
        attachments.add((1...3).map { ComposerAttachmentsTests.image("\($0).png", bytes: NativeImage.maxBytes - 100) })
        #expect(attachments.items.count == 3 && attachments.items.allSatisfy { !$0.tooLarge })
        #expect(attachments.problem?.hasPrefix("The images come to over 5 MB together.") == true)
        attachments.remove(attachments.items[0].id)
        #expect(attachments.problem == nil)
    }

    @Test func aFileThatIsReadAsAnAttachmentKeepsItsNameForTheThumbnailsAfterTheSend() throws {
        let folder = try Fixture.scratchDirectory("attach-name")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("after-mini.png")
        try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!.write(to: url)
        let attachment = try #require(ImageAttachment(url: url))
        #expect(attachment.image.name == "after-mini.png" && attachment.image.mimeType == "image/png")
    }
}
