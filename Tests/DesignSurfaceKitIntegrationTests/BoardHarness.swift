import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdTestSupport
import Testing
import WebKit
@testable import DesignSurfaceKit

/// A scratch design folder with a surface over it, and the board views a test loads from it.
@MainActor
final class BoardHarness {
    static let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    static let fixtures = tests.appendingPathComponent("Fixtures/project", isDirectory: true)
    static let designs = tests.deletingLastPathComponent().appendingPathComponent("Designs", isDirectory: true)

    let folder: URL
    let project: URL
    let surface: DesignSurface
    private(set) var events: [DesignBoardEvent] = []

    /// A design holding this suite's fixture boards, plus `files` (paths under `project/`).
    init(files: [String: String] = [:], network: DesignSandbox.Network = .none) throws {
        folder = try makeScratchDirectory("design")
        project = folder.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        for name in try FileManager.default.contentsOfDirectory(atPath: Self.fixtures.path) {
            try FileManager.default.copyItem(at: Self.fixtures.appendingPathComponent(name), to: project.appendingPathComponent(name))
        }
        surface = DesignSurface(designID: DesignID(), folder: folder, network: network)
        for (path, text) in files { try write(path, text) }
    }

    func write(_ path: String, _ text: String) throws {
        let url = project.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func source(_ path: String) throws -> String {
        try String(contentsOf: project.appendingPathComponent(path), encoding: .utf8)
    }

    func view(_ path: String, size: CGSize = CGSize(width: 400, height: 300)) throws -> DesignBoardView {
        let board = try #require(DesignPath(path))
        let view = DesignBoardView(surface: surface, board: board, size: size)
        view.onEvent = { [weak self] event in self?.events.append(event) }
        return view
    }

    var problems: [DesignBoardProblem] {
        events.compactMap { if case .problem(let problem) = $0 { problem } else { nil } }
    }

    /// Runs `body` in the board's own page (as the board's scripts would) and returns its value.
    func page(_ view: DesignBoardView, _ body: String) async throws -> Any? {
        try await view.webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)
    }

    func text(_ view: DesignBoardView, _ body: String) async throws -> String {
        try #require(try await page(view, body) as? String)
    }

    /// Every element carrying a tid, head and body, as `"<tid> <tag>"`.
    func stamped(_ view: DesignBoardView) async throws -> [String] {
        let value = try await page(view, """
            return Array.from(document.querySelectorAll('[data-dc-tid]'))
              .map(e => e.getAttribute('data-dc-tid') + ' ' + e.localName.toLowerCase());
            """)
        return try #require(value as? [String])
    }
}
