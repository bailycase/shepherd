import Foundation
import WebKit

/// Serves one design over `shepherd-design://<design>/`: the runtime at any `project/…/support.js`,
/// the design's `project/` files, and its uploads at `/_blob/<id>`. Everything else is a 404.
/// There is no `file://` access; a file is served only if it resolves, links followed, inside
/// the folder it was asked from.
@MainActor
final class DesignSchemeHandler: NSObject, WKURLSchemeHandler {
    let host: String
    let folder: URL
    let network: DesignSandbox.Network

    /// Files larger than this are refused, as the canvas caps a text file.
    nonisolated static let maxFileBytes = 16 * 1024 * 1024

    private var live: Set<ObjectIdentifier> = []

    init(host: String, folder: URL, network: DesignSandbox.Network) {
        self.host = host
        self.folder = folder
        self.network = network
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        live.insert(id)
        let request = task.request
        let route = request.httpMethod.map { $0 == "GET" || $0 == "HEAD" } ?? true
            ? DesignRoute(url: request.url, host: host) : .refused
        let folder = folder
        nonisolated(unsafe) let task = task
        Task {
            let body = await Task.detached(priority: .userInitiated) { Self.read(route, folder: folder) }.value
            guard self.live.remove(id) != nil, let url = request.url else { return }
            // A page that isn't there fails its navigation (WebKit hands a custom scheme's
            // navigation response over without its status); a missing subresource is a 404.
            if body == nil, request.mainDocumentURL == url {
                task.didFailWithError(URLError(.fileDoesNotExist, userInfo: [NSURLErrorFailingURLErrorKey: url]))
                return
            }
            let status = body == nil ? 404 : 200
            let data = body?.data ?? Data()
            var headers = [
                "Content-Type": body?.type ?? "text/plain; charset=utf-8",
                "Content-Length": String(data.count),
                "Content-Security-Policy": DesignSandbox.contentSecurityPolicy(network: self.network),
                "X-Content-Type-Options": "nosniff",
                "Referrer-Policy": "no-referrer",
                "Cache-Control": "no-store",
            ]
            if status == 404 { headers["Content-Length"] = "0" }
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            task.didReceive(response)
            if !data.isEmpty { task.didReceive(data) }
            task.didFinish()
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        live.remove(ObjectIdentifier(task))
    }

    // MARK: Files

    struct Body: Sendable {
        var data: Data
        var type: String
    }

    nonisolated static func read(_ route: DesignRoute, folder: URL) -> Body? {
        switch route {
        case .runtime:
            guard let data = DesignRuntime.supportScript else { return nil }
            return Body(data: data, type: DesignSandbox.contentType(forExtension: "js"))
        case .project(let segments):
            let base = folder.appendingPathComponent("project", isDirectory: true)
            var file = base
            for segment in segments { file.appendPathComponent(segment) }
            return serve(file, inside: base)
        case .blob(let id):
            let assets = folder.appendingPathComponent("assets", isDirectory: true)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: assets.path)) ?? []
            guard let name = names.sorted().first(where: { $0 == id || $0.hasPrefix(id + ".") }) else { return nil }
            return serve(assets.appendingPathComponent(name), inside: assets)
        case .refused:
            return nil
        }
    }

    /// The file's contents when it is a regular file that resolves inside `base`.
    nonisolated static func serve(_ file: URL, inside base: URL) -> Body? {
        let root = base.resolvingSymlinksInPath().standardizedFileURL.path
        let resolved = file.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(root + "/"),
              let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (values.fileSize ?? 0) <= maxFileBytes,
              let data = try? Data(contentsOf: resolved) else { return nil }
        return Body(data: data, type: DesignSandbox.contentType(forExtension: resolved.pathExtension))
    }
}
