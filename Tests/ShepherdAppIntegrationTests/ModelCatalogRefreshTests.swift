import Foundation
import Testing
import ShepherdSessions
import ShepherdTestSupport
@testable import ShepherdApp

@Suite(.mainActorExclusive)
@MainActor struct ModelCatalogRefreshTests {
    @Test func anExistingPickerCatalogSeesChangedProviderFiles() async throws {
        let root = try makeScratchDirectory("model-refresh")
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = root.appendingPathComponent("engine")
        let table = root.appendingPathComponent("table")
        try Data("#!/bin/sh\n/bin/cat '\(table.path)'\n".utf8).write(to: engine)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: engine.path)
        let pi = PiSetup(engine: PiEngine(command: [engine.path], packageDirectory: nil, version: nil, node: .onPath("node")),
                         home: root.appendingPathComponent("pi"), userHome: root.path)
        try Data("provider model context thinking\nfixture old 128K no\n".utf8).write(to: table)
        #expect(await ModelCatalog.loadLocal(from: pi.catalog).models.map(\.id) == ["fixture/old"])
        try Data("provider model context thinking\ncliproxyapi added 200K yes\n".utf8).write(to: table)
        try Data("{}".utf8).write(to: pi.home.appendingPathComponent(CLIProxyAPIStore.fileName))
        #expect(await ModelCatalog.loadLocal(from: pi.catalog).models.map(\.id) == ["cliproxyapi/added"])
    }
}
