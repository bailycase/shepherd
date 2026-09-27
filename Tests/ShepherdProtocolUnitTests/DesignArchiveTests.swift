import Foundation
import Testing
import ShepherdCore
import ShepherdTestKit
@testable import ShepherdProtocol

/// A Claude Design project as a ZIP, read from its table of contents before anything is
/// unpacked (`DesignArchive`), and the import's reasons in ImportFailed's words.
@Suite("Design archive")
struct DesignArchiveTests {
    typealias Z = TestZip.Entry

    private func entries(_ zip: Data) throws -> [DesignArchive.Entry] {
        let found = try DesignArchive.directory(tail: zip, fileSize: Int64(zip.count))
        let directory = zip.subdata(in: Int(found.offset)..<Int(found.offset + found.size))
        return try DesignArchive.entries(directory, count: found.count)
    }

    @Test func aZipsTableOfContentsIsReadWithoutUnpacking() throws {
        let zip = TestZip.make([.folder("checkout/"), .file("checkout/project/canvas.json", "{}"),
                                .file("checkout/project/A.dc.html", "<x-dc></x-dc>"), .link("checkout/project/logo.svg", to: "../x")])
        let read = try entries(zip)
        #expect(read.map(\.path) == ["checkout/", "checkout/project/canvas.json", "checkout/project/A.dc.html", "checkout/project/logo.svg"])
        #expect(read.map(\.kind) == [.directory, .file, .file, .symlink])
        #expect(read[2].size == 13)
    }

    /// Only the last bytes are read first: a tail that holds the end record finds the table.
    @Test func theTableIsFoundFromTheFilesLastBytes() throws {
        let zip = TestZip.make([.file("canvas.json", "{}")])
        let tail = zip.suffix(40)
        let found = try DesignArchive.directory(tail: Data(tail), fileSize: Int64(zip.count))
        #expect(found.count == 1 && found.offset > 0)
    }

    @Test(arguments: [Data(), Data("not a zip at all, just words".utf8), Data(repeating: 0, count: 100)])
    func somethingElseIsNotAZip(_ data: Data) {
        #expect(throws: DesignArchive.ReadError.notAZip) { try DesignArchive.directory(tail: data, fileSize: Int64(data.count)) }
    }

    /// Zip slip: a name that is absolute, climbs out, or uses a backslash or a drive never lands.
    @Test(arguments: ["../evil.dc.html", "project/../../evil", "/etc/passwd", "project\\..\\evil", "C:/evil", "a/../../b"])
    func aNameOutsideTheProjectIsRefused(_ name: String) throws {
        let read = try entries(TestZip.make([.file("canvas.json", "{}"), .file(name, "x")]))
        #expect(throws: DesignImportFailure.linksOutside([DesignImportLink(board: name, target: "outside the project")])) {
            try DesignArchive.check(read)
        }
    }

    @Test func aLinkInsideTheZipIsRefused() throws {
        let read = try entries(TestZip.make([.file("canvas.json", "{}"), .link("logo.svg", to: "/Users/sam/logo.svg")]))
        #expect(throws: DesignImportFailure.linksOutside([DesignImportLink(board: "logo.svg", target: "a link")])) {
            try DesignArchive.check(read)
        }
    }

    /// Checked before anything is unpacked: a project over 1 GB, or one file over the cap.
    @Test func sizesAreCheckedFromTheTableOfContents() throws {
        let big = try entries(TestZip.make([.file("canvas.json", "{}"), Z("video.mp4", claimedSize: 1_200_000_000)]))
        #expect(throws: (any Error).self) { try DesignArchive.check(big) }
        let file = try entries(TestZip.make([Z("A.dc.html", claimedSize: UInt32(DesignImport.maxFileBytes + 1))]))
        #expect(throws: DesignImportFailure.fileTooLarge(path: "A.dc.html", bytes: Int64(DesignImport.maxFileBytes + 1),
                                                         limit: Int64(DesignImport.maxFileBytes))) { try DesignArchive.check(file) }
        let many = try entries(TestZip.make((0..<60).map { Z("B\($0).png", claimedSize: 16_000_000) }))
        #expect(throws: Never.self) { try DesignArchive.check(many) }
        let over = many + (0..<3).map { DesignArchive.Entry("C\($0).png", size: 16_000_000) }
        #expect(throws: DesignImportFailure.tooLarge(bytes: 1_008_000_000, limit: DesignImport.maxProjectBytes)) {
            try DesignArchive.check(over)
        }
        #expect(throws: Never.self) { try DesignArchive.check(try entries(TestZip.make([.file("canvas.json", "{}")]))) }
    }

    // MARK: Links in boards

    @Test(arguments: [
        (#"<img src="../shared/logo.svg">"#, "A.dc.html", ["../shared/logo.svg"]),
        (#"<link href='../../fonts/Inter.woff2'>"#, "boards/pricing.dc.html", ["../../fonts/Inter.woff2"]),
        (#"<div style="background: url(/Users/sam/Desktop/bg.png)"></div>"#, "A.dc.html", ["/Users/sam/Desktop/bg.png"]),
        (#"<img src="file:///tmp/x.png">"#, "A.dc.html", ["file:///tmp/x.png"]),
        (#"<img src="../logo.svg">"#, "boards/A.dc.html", []),
        (##"<img src="https://example.com/a.png"><a href="#top"></a><img src="data:image/png;base64,AAAA">"##, "A.dc.html", []),
        (#"<a href="/B.dc.html"></a><img src="./ds/acme/logo.svg" srcset="a.png 1x, b.png 2x">"#, "A.dc.html", []),
        (#"<img srcset="ok.png 1x, ../../out.png 2x">"#, "A.dc.html", ["../../out.png"]),
    ])
    func aBoardPointingOutsideTheProjectIsFound(_ source: String, _ board: String, _ outside: [String]) {
        #expect(DesignImport.outsideReferences(in: source, board: board) == outside)
    }

    // MARK: Words

    @Test func eachFailureSaysWhatWentWrongAsTheBoardsDo() {
        #expect(DesignImportFailure.title(file: "checkout-funnel.zip") == "Couldn’t import “checkout-funnel.zip”")
        #expect(DesignImportFailure.notAProject.message.hasPrefix("There’s no canvas.json inside"))
        #expect(DesignImportFailure.notAProject.offersAnother)
        #expect(DesignImportFailure.tooLarge(bytes: 2_300_000_000, limit: DesignImport.maxProjectBytes).message
            .hasPrefix("It’s 2.3 GB. Shepherd imports projects up to 1 GB."))
        let links = DesignImportFailure.linksOutside([
            DesignImportLink(board: "boards/hero.html", target: "../shared/logo.svg"),
            DesignImportLink(board: "boards/pricing.html", target: "../../fonts/Inter.woff2"),
            DesignImportLink(board: "boards/footer.html", target: "/Users/sam/Desktop/bg.png"),
            DesignImportLink(board: "boards/more.html", target: "../x"),
        ])
        #expect(links.message.hasPrefix("4 boards point to files outside the project folder."))
        #expect(links.listedLinks.count == 3 && !links.offersAnother)
        #expect(links.footer == "Nothing was imported.")
        let unreadable = DesignImportFailure.unreadableBoards([DesignImportUnreadable(path: "boards/pricing-v3.html", title: "Pricing — v3",
                                                                                       reason: "is empty")], readable: 11)
        #expect(unreadable.message == "The board Pricing — v3 couldn’t be read: boards/pricing-v3.html is empty. The other 11 boards are fine.")
        #expect(unreadable.footer == "Nothing’s imported until you choose.")
    }

    @Test(arguments: [(Int64(2_300_000_000), "2.3 GB"), (1_000_000_000, "1 GB"), (14_200_000, "14.2 MB"), (Int64(DesignImport.maxFileBytes), "16 MB"), (900_000, "900 KB"), (12, "12 bytes")])
    func sizesReadAsTheBoardsWriteThem(_ bytes: Int64, _ text: String) {
        #expect(DesignImportFailure.size(bytes) == text)
    }
}
