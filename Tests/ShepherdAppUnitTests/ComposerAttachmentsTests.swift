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
}
