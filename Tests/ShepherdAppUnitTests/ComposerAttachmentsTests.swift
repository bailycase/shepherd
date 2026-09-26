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

    @Test(arguments: [
        (ComposerAttachmentsTests.image("big.png", bytes: NativeImage.maxBytes + 1), "big.png is over 2 MiB after resizing."),
        (("notes.txt", nil as ImageAttachment?), "notes.txt is not an image Shepherd can attach."),
    ])
    func whatCannotGoIsSkippedAndTheRestStays(_ refused: (name: String, attachment: ImageAttachment?), message: String) {
        var attachments = ComposerAttachments()
        attachments.add([Self.image("a.png"), refused, Self.image("b.png")])
        #expect(attachments.items.map(\.name) == ["a.png", "b.png"])
        #expect(attachments.error == message)
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
