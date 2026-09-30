import Foundation
import ShepherdTestKit
import Testing
@testable import ShepherdProtocol

/// The dev servers a folder offers (DESIGN.md › Side pane: Browser › Nothing open). The code lives in
/// ShepherdProtocol because a host's server reads its threads' folders for a remote viewer.
@Suite("Dev server discovery")
struct DevServerDiscoveryTests {
    static func manifest(_ scripts: [String: String], name: String? = "acme-web") -> Data {
        var json: [String: Any] = ["scripts": scripts]
        if let name { json["name"] = name }
        return try! JSONSerialization.data(withJSONObject: json)
    }

    @Test func theServingScriptsComeInOrderWithTheLockfilesManager() {
        let data = Self.manifest(["build": "vite build", "preview": "vite preview", "dev": "vite", "test": "vitest", "start": "node server.js"])
        let servers = DevServerDiscovery.servers(packageJSON: data, directory: URL(fileURLWithPath: "/repo"), manifest: "package.json",
                                                 manager: .pnpm)
        #expect(servers.map(\.command) == ["pnpm dev", "pnpm start", "pnpm preview"])
        #expect(servers.first?.detail == "from package.json · acme-web")
        #expect(servers.map(\.port) == [5173, nil, 4173])
        #expect(servers.first?.url?.absoluteString == "http://localhost:5173")
    }

    @Test(arguments: [
        (PackageManager.pnpm, "dev", "pnpm dev"), (.yarn, "dev", "yarn dev"), (.bun, "serve", "bun run serve"),
        (.npm, "dev", "npm run dev"), (.npm, "start", "npm start"),
    ])
    func eachManagerRunsAScriptItsWay(_ manager: PackageManager, _ script: String, _ command: String) {
        #expect(manager.command(script) == command)
    }

    @Test(arguments: [
        (["pnpm-lock.yaml", "package-lock.json"], PackageManager.pnpm), (["yarn.lock"], .yarn), (["bun.lock"], .bun),
        (["bun.lockb"], .bun), (["package-lock.json"], .npm),
    ] as [([String], PackageManager)])
    func theLockfileNamesTheManager(_ files: [String], _ manager: PackageManager) {
        #expect(PackageManager.from(lockfiles: Set(files)) == manager)
    }

    @Test(arguments: [
        ("dev", "vite --port 4000", 4000), ("dev", "next dev -p 3001", 3001), ("dev", "PORT=8081 node server.js", 8081),
        ("dev", "vite --port=4400 --host", 4400), ("dev", "next dev", 3000), ("start", "react-scripts start", 3000),
        ("dev", "astro dev", 4321), ("start", "ng serve", 4200), ("dev", "storybook dev", 6006), ("dev", "svelte-kit dev", 5173),
        ("preview", "vite preview", 4173), ("dev", "nuxt dev", 3000), ("dev", "webpack serve", 8080),
    ] as [(String, String, Int)])
    func thePortComesFromTheFlagsElseTheTool(_ script: String, _ body: String, _ port: Int) {
        #expect(DevServerDiscovery.port(script: script, body: body) == port)
    }

    @Test(arguments: ["node server.js", "tsx watch src/index.ts", "nevergonnagiveyouup"])
    func anUnknownToolHasNoPort(_ body: String) {
        #expect(DevServerDiscovery.port(script: "dev", body: body) == nil)
    }

    @Test func noScriptsOrNoManifestOffersNothing() {
        #expect(DevServerDiscovery.servers(packageJSON: Data("{}".utf8), directory: URL(fileURLWithPath: "/r"), manifest: "package.json",
                                           manager: .npm).isEmpty)
        #expect(DevServerDiscovery.servers(packageJSON: Data("not json".utf8), directory: URL(fileURLWithPath: "/r"),
                                           manifest: "package.json", manager: .npm).isEmpty)
    }

    /// The repository's package.json and each app's in `apps/`, each with the manager its own
    /// lockfile names, or the repository's.
    @Test func aRepositoryOffersItsOwnScriptsThenItsApps() throws {
        let root = try makeScratchDirectory("browser-repo")
        try Self.manifest(["dev": "turbo dev"], name: "mono").write(to: root.appendingPathComponent("package.json"))
        try Data().write(to: root.appendingPathComponent("yarn.lock"))
        let web = root.appendingPathComponent("apps/web", isDirectory: true)
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        try Self.manifest(["dev": "next dev"], name: "web").write(to: web.appendingPathComponent("package.json"))
        let docs = root.appendingPathComponent("apps/docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try Self.manifest(["serve": "astro dev"], name: "docs").write(to: docs.appendingPathComponent("package.json"))
        try Data().write(to: docs.appendingPathComponent("pnpm-lock.yaml"))

        let servers = DevServerDiscovery.find(in: root)
        #expect(servers.map(\.command) == ["yarn dev", "pnpm serve", "yarn dev"])
        #expect(servers.map(\.detail) == ["from package.json · mono", "from apps/docs/package.json · docs", "from apps/web/package.json · web"])
        #expect(URL(fileURLWithPath: servers[2].directory).standardizedFileURL.path == web.standardizedFileURL.path)
        #expect(DevServerDiscovery.find(in: root.appendingPathComponent("nothing")).isEmpty)
    }
}
