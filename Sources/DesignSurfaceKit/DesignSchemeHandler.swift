import Foundation
import Darwin
import ShepherdProtocol
import WebKit

/// Serves one design over `shepherd-design://<design>/`: the runtime at any `project/…/support.js`,
/// the design's `project/` files, and its uploads at `/_blob/<id>`. Everything else is a 404.
/// There is no `file://` access; a file is served only if it resolves, links followed, inside
/// the folder it was asked from. A surface over files in memory serves those alone; one over a
/// file source (a remote host's design, fetched by hash) serves what the source answers, by the
/// same grammar.
@MainActor
final class DesignSchemeHandler: NSObject, WKURLSchemeHandler {
    /// Where a surface's files come from.
    enum Files: Sendable {
        /// A design's folder: `project/` and `assets/`.
        case folder(URL)
        /// Files by project path, with no uploads.
        case memory([String: Data])
        /// Project files and uploads from a source: a remote host's design, cached on this device.
        case source(any DesignFileSource)
    }

    let host: String
    let files: Files
    let network: DesignSandbox.Network

    /// Files larger than this are refused, as the canvas caps a text file.
    nonisolated static let maxFileBytes = 16 * 1024 * 1024

    private var live: Set<ObjectIdentifier> = []
    private var assets = AssetIndex()

    init(host: String, files: Files, network: DesignSandbox.Network) {
        self.host = host
        self.files = files
        self.network = network
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        live.insert(id)
        let request = task.request
        let route = request.httpMethod.map { $0 == "GET" || $0 == "HEAD" } ?? true
            ? DesignRoute(url: request.url, host: host) : .refused
        let files = files
        // A navigation starts a new lookup generation. Concurrent subresources share it;
        // directory identity/timestamps also invalidate it during a live board's edits.
        if request.mainDocumentURL == request.url { assets = AssetIndex() }
        let assets = assets
        nonisolated(unsafe) let task = task
        Task {
            let body = await Task.detached(priority: .userInitiated) { await Self.body(route, files: files, assets: assets) }.value
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

    /// What a request is answered with, from wherever the surface's files come from.
    nonisolated static func body(_ route: DesignRoute, files: Files, assets: AssetIndex? = nil) async -> Body? {
        guard case .source(let source) = files else { return read(route, files: files, assets: assets) }
        switch route {
        case .runtime:
            return runtime
        case .project(let segments):
            let path = segments.joined(separator: "/")
            guard let data = await source.projectFile(path), data.count <= maxFileBytes else { return nil }
            return Body(data: data, type: DesignSandbox.contentType(forExtension: (path as NSString).pathExtension))
        case .blob(let id):
            guard let blob = await source.blob(id), blob.data.count <= maxFileBytes,
                  blob.name == id || blob.name.hasPrefix(id + ".") else { return nil }
            return Body(data: blob.data, type: DesignSandbox.contentType(forExtension: (blob.name as NSString).pathExtension))
        case .refused:
            return nil
        }
    }

    nonisolated static func read(_ route: DesignRoute, files: Files, assets: AssetIndex? = nil) -> Body? {
        switch files {
        case .folder(let folder):
            return read(route, folder: folder, assets: assets)
        case .source:
            return nil
        case .memory(let files):
            switch route {
            case .runtime:
                return runtime
            case .project(let segments):
                let path = segments.joined(separator: "/")
                guard let data = files[path], data.count <= maxFileBytes else { return nil }
                return Body(data: data, type: DesignSandbox.contentType(forExtension: (path as NSString).pathExtension))
            case .blob, .refused:
                return nil
            }
        }
    }

    /// Shepherd's runtime, served at any `support.js`.
    nonisolated static var runtime: Body? {
        DesignRuntime.supportScript.map { Body(data: $0, type: DesignSandbox.contentType(forExtension: "js")) }
    }

    nonisolated static func read(_ route: DesignRoute, folder: URL, assets index: AssetIndex? = nil) -> Body? {
        switch route {
        case .runtime:
            return runtime
        case .project(let segments):
            let base = folder.appendingPathComponent("project", isDirectory: true)
            var file = base
            for segment in segments { file.appendPathComponent(segment) }
            return serve(file, inside: base)
        case .blob(let id):
            let assets = folder.appendingPathComponent("assets", isDirectory: true)
            guard assets.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(folder.resolvingSymlinksInPath().standardizedFileURL.path + "/") else { return nil }
            // Bare IDs still win. Only filenames are indexed, never mutable file contents.
            guard DesignRoute.isBlobID(id) else { return nil }
            if let body = serve(assets.appendingPathComponent(id), inside: assets) { return body }
            guard let name = (index ?? AssetIndex()).name(for: id, in: assets) else { return nil }
            return serve(assets.appendingPathComponent(name), inside: assets)
        case .refused:
            return nil
        }
    }

    /// One directory enumeration per unchanged load. A lock coalesces parallel subresources.
    nonisolated final class AssetIndex: @unchecked Sendable {
        private let lock = NSLock()
        private var signature: String?
        private var names: [String: String] = [:]
        private(set) var enumerations = 0

        func name(for id: String, in directory: URL) -> String? {
            lock.lock()
            defer { lock.unlock() }
            let root = directory.resolvingSymlinksInPath().standardizedFileURL.path
            var info = stat()
            guard stat(root, &info) == 0 else { signature = nil; names = [:]; return nil }
            let current = "\(root)/\(info.st_dev)/\(info.st_ino)/\(info.st_mtimespec.tv_sec)/\(info.st_mtimespec.tv_nsec)/\(info.st_ctimespec.tv_sec)/\(info.st_ctimespec.tv_nsec)"
            if signature != current {
                names = [:]
                guard let files = try? FileManager.default.contentsOfDirectory(atPath: root) else { signature = nil; return nil }
                enumerations += 1
                for name in files {
                    // Blob IDs have no dots; only the first suffix boundary is relevant.
                    guard let dot = name.firstIndex(of: ".") else { continue }
                    let prefix = String(name[..<dot])
                    guard DesignRoute.isBlobID(prefix) else { continue }
                    if names[prefix].map({ name < $0 }) ?? true { names[prefix] = name }
                }
                signature = current
            }
            return names[id]
        }
    }

    /// The file's contents when it is a regular file that resolves inside `base`.
    nonisolated static func serve(_ file: URL, inside base: URL) -> Body? {
        let root = base.resolvingSymlinksInPath().standardizedFileURL.path
        let resolved = file.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(root + "/"),
              let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (values.fileSize ?? 0) <= maxFileBytes,
              let data = try? Data(contentsOf: resolved), data.count <= maxFileBytes else { return nil }
        return Body(data: data, type: DesignSandbox.contentType(forExtension: resolved.pathExtension))
    }
}
