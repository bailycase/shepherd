import Foundation
import ShepherdRemote
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
              {"slug":"frontend-design","name":"frontend-design","source":"anthropics/skills","installs":72100}
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
