import CoreGraphics
import Foundation
import ImageIO
import ShepherdProtocol
import UniformTypeIdentifiers
import WebKit

/// A board leaving the canvas (Export): as a standalone page, as an image, or as PDF pages. Each
/// reads the board as it is drawn now, so load it (at zoom 1) first.
extension DesignBoardView {
    /// The board as one standalone HTML page with no runtime: what it draws now, the hoisted
    /// helmet in its head, no scripts and none of Shepherd's stamps (the bridge's `staticPage`).
    /// Uploads keep their `/_blob/<id>` urls, for the caller to inline or ship.
    public func staticPage() async throws -> String {
        guard contentSize != nil else { throw DesignBoardError.notBooted }
        let value = try await webView.callAsyncJavaScript(
            "return window.__shepherdBridge && window.__shepherdBridge.staticPage ? window.__shepherdBridge.staticPage() : null",
            arguments: [:], in: nil, contentWorld: Self.bridgeWorld)
        guard let page = value as? String else { throw DesignBoardError.notBooted }
        // A stylesheet the design served comes back with its urls resolved on the design's scheme.
        return Self.unscheme(page, host: surface.designID.rawValue)
    }

    /// `shepherd-design://<design>/_blob/<id>` back to `/_blob/<id>`, and a project file's url to
    /// its path from the canvas root.
    static func unscheme(_ page: String, host: String) -> String {
        let base = "\(DesignSurface.scheme)://\(host)"
        return page.replacingOccurrences(of: base + "/_blob/", with: "/_blob/")
            .replacingOccurrences(of: base + "/project/", with: "/")
    }

    /// The board as an image `scale` times its size in pixels (2 for @2x), whatever the screen.
    public func image(scale: CGFloat) async throws -> CGImage {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        let backing = window?.backingScaleFactor ?? 1
        #else
        let backing = window?.screen.scale ?? 1
        #endif
        let image = try await snapshot(width: boardSize.width * scale / max(backing, 1))
        let width = Int((boardSize.width * scale).rounded())
        let height = Int((boardSize.height * scale).rounded())
        guard image.width != width || image.height != height else { return image }
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw DesignBoardError.snapshotFailed }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { throw DesignBoardError.snapshotFailed }
        return scaled
    }

    /// The board as PDF pages at 96 CSS px to the inch (print.md): a fixed board is one page at
    /// its frame's size; a flow board runs onto `paper`, cut between lines of text and never
    /// through an image that fits a page, 5% of a page left blank at each cut, the gaps filled
    /// with the paper's color.
    public func pdf(_ mode: DesignPrint) async throws -> Data {
        guard contentSize != nil else { throw DesignBoardError.notBooted }
        // Swift 6.3.3's optimizer (SimplifyCFG) crashes on the flow case, which broke every Release
        // and Nightly build, so that case is its own function and left unoptimized; it runs once
        // per export.
        switch mode {
        case .fixed: return try await fixedPDF()
        case .flow(let paper): return try await flowPDF(on: paper)
        }
    }

    private func fixedPDF() async throws -> Data {
        let page = try await webView.pdf(configuration: Self.pdfConfiguration(CGRect(origin: .zero, size: boardSize)))
        return try DesignPDF.compose([DesignPDF.Page(source: page, size: boardSize, top: 0, background: nil)])
    }

    /// The whole document, laid out at its width, then cut into pages.
    @_optimize(none)
    private func flowPDF(on paper: DesignPrint.Paper) async throws -> Data {
        guard let first = try await printLayout() else { throw DesignBoardError.notBooted }
        let height = min(max(first.height, 1), Double(paper.size.height) * Double(DesignPrint.maxPages))
        if abs(boardSize.height - height) >= 1 {
            boardSize = CGSize(width: boardSize.width, height: height)
            try await settle(height: height)
        }
        let layout = try await printLayout() ?? first
        let slices = DesignPrint.pages(contentHeight: layout.height, pageHeight: paper.size.height,
                                       lines: layout.lines, blocks: layout.blocks)
        var pages: [DesignPDF.Page] = []
        for slice in slices {
            let rect = CGRect(x: 0, y: slice.start, width: boardSize.width, height: max(slice.height, 1))
            let data = try await webView.pdf(configuration: Self.pdfConfiguration(rect))
            pages.append(DesignPDF.Page(source: data, size: paper.size, top: slice.top, background: layout.background))
        }
        return try DesignPDF.compose(pages)
    }

    /// Waits (a second at most) for the page to take the view's new height.
    private func settle(height: Double) async throws {
        for _ in 0..<60 {
            let inner = try? await webView.evaluateJavaScript("window.innerHeight", in: nil, contentWorld: Self.bridgeWorld)
            if let inner = inner as? NSNumber, abs(inner.doubleValue - height) < 1 { return }
            try await Task.sleep(for: .milliseconds(16))
        }
    }

    private static func pdfConfiguration(_ rect: CGRect) -> WKPDFConfiguration {
        let configuration = WKPDFConfiguration()
        configuration.rect = rect
        return configuration
    }

    struct PrintLayout {
        var height: Double
        var lines: [ClosedRange<Double>]
        var blocks: [ClosedRange<Double>]
        var background: CGColor?
    }

    func printLayout() async throws -> PrintLayout? {
        let value = try await webView.callAsyncJavaScript(
            "return window.__shepherdBridge && window.__shepherdBridge.printLayout ? window.__shepherdBridge.printLayout() : null",
            arguments: [:], in: nil, contentWorld: Self.bridgeWorld)
        guard let layout = value as? [String: Any], let height = (layout["height"] as? NSNumber)?.doubleValue,
              height.isFinite, height >= 0 else { return nil }
        func ranges(_ key: String) -> [ClosedRange<Double>] {
            ((layout[key] as? [[NSNumber]]) ?? []).compactMap { pair in
                guard pair.count == 2 else { return nil }
                let top = pair[0].doubleValue, bottom = pair[1].doubleValue
                return top.isFinite && bottom.isFinite && bottom >= top ? top...bottom : nil
            }
        }
        return PrintLayout(height: height, lines: ranges("lines"), blocks: ranges("blocks"),
                           background: DesignPDF.color(css: layout["background"] as? String))
    }
}

/// PDF pages put together with CoreGraphics: a page each from WebKit's PDFs, at 96 CSS px to the
/// inch (72 points), so a Letter board (816 × 1056) is a Letter page.
public enum DesignPDF {
    /// Points per CSS px.
    public static let scale: CGFloat = 72.0 / 96.0

    struct Page {
        /// WebKit's one-page PDF of what the page shows.
        var source: Data
        /// The page, in CSS px.
        var size: CGSize
        /// How far down the page the content starts, in CSS px.
        var top: CGFloat
        /// The page's color behind the content; nil draws none.
        var background: CGColor?
    }

    static func compose(_ pages: [Page]) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw DesignBoardError.snapshotFailed
        }
        for page in pages {
            guard let provider = CGDataProvider(data: page.source as CFData), let document = CGPDFDocument(provider),
                  let content = document.page(at: 1) else { throw DesignBoardError.snapshotFailed }
            var box = CGRect(x: 0, y: 0, width: page.size.width * scale, height: page.size.height * scale)
            context.beginPage(mediaBox: &box)
            context.saveGState()
            context.scaleBy(x: scale, y: scale)
            if let background = page.background {
                context.setFillColor(background)
                context.fill(CGRect(origin: .zero, size: page.size))
            }
            let bounds = content.getBoxRect(.mediaBox)
            // PDF space runs up from the bottom: the content's top sits `top` below the page's.
            context.translateBy(x: -bounds.minX, y: page.size.height - page.top - bounds.height - bounds.minY)
            context.clip(to: CGRect(x: bounds.minX, y: bounds.minY, width: min(bounds.width, page.size.width), height: bounds.height))
            context.drawPDFPage(content)
            context.restoreGState()
            context.endPage()
        }
        context.closePDF()
        return data as Data
    }

    /// Several PDFs as one, page after page, each page as it was.
    public static func merge(_ documents: [Data]) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw DesignBoardError.snapshotFailed
        }
        for source in documents {
            guard let provider = CGDataProvider(data: source as CFData), let document = CGPDFDocument(provider) else {
                throw DesignBoardError.snapshotFailed
            }
            for number in stride(from: 1, through: document.numberOfPages, by: 1) {
                guard let page = document.page(at: number) else { continue }
                var box = page.getBoxRect(.mediaBox)
                context.beginPage(mediaBox: &box)
                context.drawPDFPage(page)
                context.endPage()
            }
        }
        context.closePDF()
        return data as Data
    }

    /// A PDF's pages and each one's size in points; nil when it isn't a PDF.
    public static func pages(_ data: Data) -> [CGSize]? {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider) else { return nil }
        return stride(from: 1, through: document.numberOfPages, by: 1).compactMap { document.page(at: $0)?.getBoxRect(.mediaBox).size }
    }

    /// A computed CSS color (`rgb(…)` or `rgba(…)`) as sRGB.
    static func color(css: String?) -> CGColor? {
        guard let css, let open = css.firstIndex(of: "("), let close = css.lastIndex(of: ")") else { return nil }
        let parts = css[css.index(after: open)..<close].split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
            .compactMap { Double($0) }
        guard parts.count >= 3 else { return nil }
        let alpha = parts.count >= 4 ? parts[3] : 1
        return CGColor(srgbRed: parts[0] / 255, green: parts[1] / 255, blue: parts[2] / 255, alpha: alpha)
    }
}

/// Images as files.
public enum DesignImageFile {
    /// `image` encoded as PNG.
    public static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw DesignBoardError.snapshotFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw DesignBoardError.snapshotFailed }
        return data as Data
    }
}
