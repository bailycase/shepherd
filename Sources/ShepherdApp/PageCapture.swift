import AppKit
import UniformTypeIdentifiers
import WebKit

/// New design's starting points as images for the brief (DZStart): Capture a page draws a web
/// page off screen in a web view of its own (no cookies or storage, gone after) and keeps it as a
/// PNG; From a screenshot turns a PDF's first page into one. The composer's attachments take them
/// from there (resized like any dropped image).
@MainActor
enum PageCapture {
    /// The window the page lays out in: the boards' desktop width.
    static let viewport = CGSize(width: 1440, height: 900)
    /// A long page is captured down to here; the attachment is resized after.
    static let maxHeight: CGFloat = 6000
    static let timeout: Double = 30

    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    /// The address typed into Capture a page: http or https with a host; a bare host takes https.
    nonisolated static func address(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        guard let url = URL(string: trimmed.contains("://") ? trimmed : "https://" + trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(), !host.isEmpty else { return nil }
        return url
    }

    /// The page at `url`, its whole length up to `maxHeight`, as a PNG named after its host.
    static func capture(_ url: URL, into directory: URL = AppImageDrop.directory) async throws -> URL {
        let image = try await snapshot { $0.load(URLRequest(url: url)) }
        return try write(image, name: url.host() ?? "page", into: directory)
    }

    /// A PDF's first page as a PNG beside the drops; any other file as it is.
    nonisolated static func imageFile(_ url: URL, into directory: URL = AppImageDrop.directory) -> URL {
        guard UTType(filenameExtension: url.pathExtension.lowercased())?.conforms(to: .pdf) == true,
              let image = NSImage(contentsOf: url),
              let file = try? write(image, name: url.deletingPathExtension().lastPathComponent, into: directory) else { return url }
        return file
    }

    /// Draws what `load` loads in an off-screen web view once it has finished loading.
    static func snapshot(_ load: @escaping @MainActor (WKWebView) -> Void) async throws -> NSImage {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: CGRect(origin: .zero, size: viewport), configuration: configuration)
        view.appearance = NSAppearance(named: .aqua)
        let loader = Loader()
        view.navigationDelegate = loader
        // A load given up on answers too, so its wait never leaks.
        defer { view.stopLoading(); loader.finish(CancellationError()) }
        let result = await withDeadline(timeout) {
            try await loader.wait { load(view) }
            let height = try? await view.evaluateJavaScript("document.documentElement.scrollHeight") as? Double
            view.frame.size.height = min(max(height.map { CGFloat($0) } ?? viewport.height, viewport.height), maxHeight)
            let snapshot = WKSnapshotConfiguration()
            snapshot.afterScreenUpdates = true
            return try await view.takeSnapshot(configuration: snapshot)
        }
        switch result {
        case .value(let image): return image
        case .thrown(let error): throw error
        case .timedOut: throw Failure(errorDescription: "the page took more than \(Int(timeout)) seconds to load")
        }
    }

    nonisolated private static func write(_ image: NSImage, name: String, into directory: URL) throws -> URL {
        guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            throw Failure(errorDescription: "the image couldn't be made")
        }
        // A folder each, so the chip shows the plain name.
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(name).appendingPathExtension("png")
        try png.write(to: file)
        return file
    }

    /// Answers once the main frame has loaded or failed to.
    @MainActor private final class Loader: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, Error>?

        func wait(_ start: () -> Void) async throws {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                start()
            }
        }

        func finish(_ error: Error?) {
            guard let continuation else { return }
            self.continuation = nil
            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(nil) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(error) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(error) }
    }
}
