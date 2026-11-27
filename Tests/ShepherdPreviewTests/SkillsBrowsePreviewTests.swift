import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import SwiftUI
import Testing
@testable import ShepherdApp

/// Browse skills.sh at its minimum and ideal sizes, answered from fixtures (no network): long
/// names, a long description and several files.
@Suite("Skills browse previews", .serialized, .mainActorExclusive,
       .enabled(if: Preview.enabled && !Preview.liveModel, "set SHEPHERD_PREVIEW_DIR (without SHEPHERD_LIVE_MODEL) to render previews"))
@MainActor
struct SkillsBrowsePreviewTests {
    @Test(arguments: [("min", CGSize(width: AppLayout.skillsSheetMinWidth, height: AppLayout.skillsSheetMinHeight)),
                      ("ideal", CGSize(width: AppLayout.skillsSheetWidth, height: AppLayout.skillsSheetHeight))])
    func browse(_ name: String, _ size: CGSize) async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureDirectory.self]
        let directory = SkillsDirectory(base: URL(string: "https://fixtures.test")!, session: URLSession(configuration: config))
        try await Preview.render("skills-browse-\(name)", size: size, untilGone: "Loading skills.sh", showing: "Files") {
            SkillsDirectorySheet(vm: workspace.vm, model: workspace.vm.skills, directory: directory, openRepo: { _ in }, close: {})
                .frame(width: size.width, height: size.height)
        }
    }

    /// Browse skills.sh with the directory out of reach (SettingsSkillsBrowseOffline).
    @Test func offline() async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OfflineDirectory.self]
        let directory = SkillsDirectory(base: URL(string: "https://fixtures.test")!, session: URLSession(configuration: config))
        let size = CGSize(width: AppLayout.skillsSheetWidth, height: AppLayout.skillsSheetHeight)
        try await Preview.render("skills-browse-offline", size: size, untilGone: "Loading skills.sh", showing: "Try again") {
            SkillsDirectorySheet(vm: workspace.vm, model: workspace.vm.skills, directory: directory, openRepo: { _ in }, close: {})
                .frame(width: size.width, height: size.height)
        }
    }

    /// Add skills from a repo (SettingsSkillsAddRepo): a folder of skills on this Mac, three of them already installed.
    @Test func addRepo() async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        let names: [(String, String)] = [
            ("frontend-design", "Distinctive, production-grade frontend interfaces"), ("skill-creator", "Guide for creating effective skills"),
            ("pdf", "Read, merge, split and fill PDF files"), ("docx", "Create, edit and analyze Word documents"),
            ("xlsx", "Spreadsheets with formulas, formatting and charts"), ("pptx", "Build and edit slide decks"),
            ("algorithmic-art", "Generative art with p5.js"), ("brand-guidelines", "Apply brand colors and type"),
            ("canvas-design", "Visual art in .png and .pdf"), ("internal-comms", "Status reports, newsletters and FAQs"),
            ("mcp-builder", "Build MCP servers that work well with agents"), ("slack-gif-creator", "Animated GIFs sized for Slack"),
            ("theme-factory", "Style an artifact with a ready-made theme"), ("web-artifacts-builder", "Multi-part HTML artifacts"),
            ("webapp-testing", "Test local web apps with Playwright")]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("acme-skills-\(UUID().uuidString.prefix(6))")
        for (name, summary) in names {
            let folder = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("scripts"), withIntermediateDirectories: true)
            let body = "---\nname: \(name)\ndescription: \(summary)\n---\n\n# \(name)\n\n## Requirements\n\n- Zero errors in every file you hand over.\n"
            try body.write(to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
            try "print()".write(to: folder.appendingPathComponent("scripts/run.py"), atomically: true, encoding: .utf8)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let store = workspace.server.skills
        for name in ["frontend-design", "skill-creator", "pdf"] {
            let text = "---\nname: \(name)\ndescription: x\n---\n"
            try store.installFiles(name: name, files: [SkillFile(path: "SKILL.md", contents: Data(text.utf8))], invocation: .automatic)
        }
        try await workspace.seed(ShepherdState())
        let vm = workspace.vm
        let size = CGSize(width: AppLayout.skillsSheetWidth, height: AppLayout.skillsSheetHeight)
        try await Preview.render("skills-add-repo", size: size, ready: { vm.skills.row("pdf", in: vm.skillsHosts) != nil }, untilGone: "Look up a repository", showing: "Files") {
            AddSkillsSheet(vm: vm, model: vm.skills, initialRepo: root.path, close: {})
                .frame(width: size.width, height: size.height)
        }
    }
}

private final class OfflineDirectory: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}

private final class FixtureDirectory: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let skill = """
        ---
        name: wizard-of-multi-step-onboarding-flows
        description: Designs and builds multi-step onboarding wizards with progress, validation, saved drafts, accessible focus order and a summary step that lets people go back and change any earlier answer before they submit.
        ---

        # Onboarding wizard

        Break the flow into steps of one decision each, and validate every step before moving on.
        Keep a draft so a reload never loses answers; show progress as "Step 2 of 5", not a bare bar.
        """
        let body: String
        if url.path.hasPrefix("/api/v1/skills") {
            body = #"""
            {"data":[
              {"slug":"wizard-of-multi-step-onboarding-flows","name":"wizard-of-multi-step-onboarding-flows","source":"acme-design-systems/agent-skills-collection","installs":48500},
              {"slug":"setup-wizard","name":"setup-wizard","source":"acme-design-systems/agent-skills-collection","installs":12100},
              {"slug":"pdf","name":"pdf","source":"anthropics/skills","installs":63900},
              {"slug":"frontend-design","name":"frontend-design","source":"anthropics/skills","installs":72100},
              {"slug":"find-skills","name":"find-skills","source":"acme-labs/skills","installs":48200},
              {"slug":"web-design-guidelines","name":"web-design-guidelines","source":"acme-labs/agent-skills","installs":39100},
              {"slug":"skill-creator","name":"skill-creator","source":"anthropics/skills","installs":27300},
              {"slug":"remotion-best-practices","name":"remotion-best-practices","source":"remotion-dev/skills","installs":19400},
              {"slug":"brainstorming","name":"brainstorming","source":"obra/superpowers","installs":9400},
              {"slug":"docx","name":"docx","source":"anthropics/skills","installs":8100}
            ]}
            """#
        } else {
            let files: [[String: String]] = [
                ["path": "SKILL.md", "contents": skill], ["path": "reference.md", "contents": "# Reference\n"],
                ["path": "examples/signup.md", "contents": "x"], ["path": "examples/checkout.md", "contents": "x"],
                ["path": "scripts/validate.py", "contents": "print()"],
            ]
            body = String(data: try! JSONSerialization.data(withJSONObject: ["files": files]), encoding: .utf8)!
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
