import Foundation
import UniformTypeIdentifiers
import Testing
import ShepherdProtocol
@testable import ShepherdRemote

/// Paste, drop and the Files picker: images are taken, everything else is refused with a message.
@Suite("Composer image input")
struct ComposerImageInputTests {
    private static func item(_ types: [UTType], _ name: String? = nil) -> ComposerImageInput.Item {
        .init(typeIdentifiers: types.map(\.identifier), name: name)
    }

    @Test(arguments: [UTType.png, .jpeg, .heic, .gif, .webP, .tiff])
    func imageTypesAreTaken(type: UTType) {
        let plan = ComposerImageInput.plan([Self.item([type], "shot")], room: 4)
        #expect(plan.accepted == [.init(index: 0, typeIdentifier: type.identifier, name: "shot")])
        #expect(plan.message == nil)
    }

    @Test func aProviderOfferingFileAndImageTypesIsLoadedAsItsImage() {
        let plan = ComposerImageInput.plan([Self.item([.fileURL, .jpeg, .data])], room: 4)
        #expect(plan.accepted.map(\.typeIdentifier) == [UTType.jpeg.identifier])
    }

    @Test(arguments: [UTType.pdf, .plainText, .folder, .zip, .data, .movie])
    func nonImagesAreRefusedByName(type: UTType) {
        let plan = ComposerImageInput.plan([Self.item([type], "report")], room: 4)
        #expect(plan.accepted.isEmpty)
        #expect(plan.message == "report isn't an image. Only images can be attached here.")
    }

    @Test func aMixedDropTakesTheImagesAndSaysWhatItLeftOut() {
        let plan = ComposerImageInput.plan([Self.item([.png], "a.png"), Self.item([.pdf], "b.pdf"), Self.item([.jpeg], "c.jpg"), Self.item([.zip], "d.zip")], room: 4)
        #expect(plan.accepted.map(\.index) == [0, 2])
        #expect(plan.message == "2 items aren't images. Only images can be attached here.")
    }

    @Test func imagesPastTheRoomAreRefusedTogether() {
        let items = (0..<6).map { Self.item([.png], "\($0).png") }
        let plan = ComposerImageInput.plan(items, room: 2)
        #expect(plan.accepted.map(\.index) == [0, 1])
        #expect(plan.message == NativeImagePreparation.Failure.full.description)
        #expect(ComposerImageInput.plan(items, room: 0).accepted.isEmpty)
    }

    @Test func aMessageTakesAtMostWhatTheMacTakes() {
        let items = (0..<(NativeImage.maxPerSend + 2)).map { _ in Self.item([.png]) }
        #expect(ComposerImageInput.plan(items, room: NativeImagePreparation.room(0)).accepted.count == NativeImage.maxPerSend)
    }

    @Test func unnamedImagesGetANameWithTheirExtension() {
        #expect(ComposerImageInput.plan([Self.item([.png])], room: 4).accepted.map(\.name) == ["Image.png"])
        #expect(ComposerImageInput.plan([Self.item([.jpeg]), Self.item([.png])], room: 4).accepted.map(\.name) == ["Image 1.jpeg", "Image 2.png"])
    }

    @Test func anItemWithNoTypeAndNoNameIsRefused() {
        let plan = ComposerImageInput.plan([.init(typeIdentifiers: [])], room: 4)
        #expect(plan.message == "That item isn't an image. Only images can be attached here.")
    }

    @Test func aPickedFileIsTypedByItsExtension() {
        #expect(ComposerImageInput.plan([.init(fileName: "Diagram.PNG")], room: 4).accepted.map(\.name) == ["Diagram.PNG"])
        #expect(ComposerImageInput.plan([.init(fileName: "notes.pdf")], room: 4).message == "notes.pdf isn't an image. Only images can be attached here.")
        #expect(ComposerImageInput.plan([.init(fileName: "Makefile")], room: 4).accepted.isEmpty)
    }

    /// A drop can offer only the file's URL; the file's own type decides.
    @Test func aFileOfferedOnlyByURLIsTypedByTheFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("composer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let photo = directory.appendingPathComponent("IMG_0001.JPG")
        let report = directory.appendingPathComponent("Q3 report.pdf")
        for url in [photo, report] { try Data("x".utf8).write(to: url) }
        let taken = ComposerImageInput.plan([.init(fileURL: photo)], room: 4)
        #expect(taken.accepted == [.init(index: 0, typeIdentifier: UTType.jpeg.identifier, name: "IMG_0001.JPG")])
        #expect(taken.message == nil)
        #expect(ComposerImageInput.plan([.init(fileURL: report)], room: 4).message == "Q3 report.pdf isn't an image. Only images can be attached here.")
    }
}
