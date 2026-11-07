import AppKit
import Foundation
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// New design's image starting points (DZStartPlanned) in a real off-screen web view and on
/// real files: a page is captured at the desktop width down its whole length, and a PDF goes
/// as its first page, a PNG the composer reads.
@MainActor
@Suite("Page capture", .mainActorExclusive, .integrationTimeLimit)
struct PageCaptureTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("page-capture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func capturesThePageDownItsLength() async throws {
        let html = "<!doctype html><body style='margin:0'><div style='height:2000px;background:#4f46e5'></div></body>"
        let image = try await PageCapture.snapshot { $0.loadHTMLString(html, baseURL: nil) }
        #expect(image.size.width == PageCapture.viewport.width)
        #expect(image.size.height == 2000)
    }

    @Test func aPageThatFailsToLoadThrows() async throws {
        // Port 9 (discard) on loopback refuses at once.
        await #expect(throws: (any Error).self) {
            _ = try await PageCapture.snapshot { $0.load(URLRequest(url: URL(string: "http://127.0.0.1:9/")!)) }
        }
    }

    @Test func aPDFGoesAsItsFirstPage() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pdf = dir.appendingPathComponent("checkout-export.pdf")
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 300, height: 200)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 0.3, green: 0.3, blue: 0.9, alpha: 1))
        context.fill(box)
        context.endPDFPage()
        context.closePDF()
        try (data as Data).write(to: pdf)

        let png = PageCapture.imageFile(pdf, into: dir)
        #expect(png.lastPathComponent == "checkout-export.png")
        let file = try #require(ImageFile(url: png))
        #expect(file.mimeType == "image/png")
        #expect((file.pixels?.width ?? 0) >= 300)
    }
}
