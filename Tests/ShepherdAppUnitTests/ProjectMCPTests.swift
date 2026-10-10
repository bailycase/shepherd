import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdApp

@Suite("Project MCP configuration", .mainActorExclusive)
@MainActor
struct ProjectMCPTests {
    @Test func oauthActionsReflectHostCredentialsAndExcludeHeadersAndStdio() {
        let text = #"{"mcpServers":{"issues":{"url":"https://example.test/mcp"},"header":{"url":"https://example.test/mcp","headers":{"authorization":"Bearer ${TOKEN}"}},"local":{"command":"tools"}}}"#
        let unsigned = ProjectMCPConfiguration(text: text, canSignIn: true)
        #expect(unsigned.rows.first(where: { $0.name == "issues" })?.signIn == .signIn)
        #expect(unsigned.rows.first(where: { $0.name == "header" })?.signIn != .signIn)
        #expect(unsigned.rows.first(where: { $0.name == "local" })?.signIn != .signIn)
        let signed = ProjectMCPConfiguration(text: text, signedIn: ["issues"], canSignIn: true)
        #expect(signed.rows.first(where: { $0.name == "issues" })?.signIn == .account("Credentials saved"))
        let oldHost = ProjectMCPConfiguration(text: text, canSignIn: false)
        #expect(oldHost.rows.first(where: { $0.name == "issues" })?.signIn == .unverified)
    }

    @Test(arguments: [".shepherd/mcp.json", ".pi/mcp.json", ".mcp.json"])
    func editsUseTheSelectedHostAndFileWithoutChangingUnknownFields(_ path: String) async throws {
        let original = #"{"owner":"keep","servers":{"other":{"command":"vscode-only"}},"mcpServers":{"issues":{"url":"https://example.test/mcp","enabled":true,"disabled":false,"exposure":"hidden","toolExposure":{"lookup":"direct"},"oauth":{"custom":"keep"},"headers":{"Authorization":"Bearer ${PROJECT_TOKEN}"},"future":{"keep":true}}}}"#
        let file = File(path: path, text: original)
        let model = await file.open()
        #expect(model.mcp.rows.map(\.name) == ["issues"])
        #expect(model.mcp.details["issues"]?.direct == (path != ".mcp.json" ? nil : false))
        await model.setMCPEnabled("issues", false)
        #expect(file.saves.count == 1)
        #expect(file.saves[0].0 == original)
        #expect(model.mcp.rows.first?.status == .off)
        let saved = try #require(model.mcp.entries.first)
        #expect(saved.json[path != ".mcp.json" ? "enabled" : "disabled"] == .bool(path == ".mcp.json"))
        #expect(saved.json["future"] == .object(["keep": .bool(true)]))
        #expect(saved.json["toolExposure"] == .object(["lookup": .string("direct")]))
        #expect(saved.json["oauth"] == .object(["custom": .string("keep")]))
        #expect(saved.headers["Authorization"] == "Bearer ${PROJECT_TOKEN}")
        #expect(saved.json["shepherd"] == nil)
        #expect(model.mcp.document.root["owner"] == .string("keep"))
        #expect(model.mcp.document.root["servers"]?["other"]?["command"] == .string("vscode-only"))
        await model.setMCPDirect("issues", true)
        #expect(file.saves.count == (path != ".mcp.json" ? 2 : 1))
        try await model.removeMCP("issues")
        #expect(model.mcp.entries.isEmpty)
        #expect(model.mcp.document.root["servers"]?["other"] != nil)
    }

    @Test func legacyRemoteInventoryKeepsNativeDisabledStateToggleAndApproval() async throws {
        let file = File(path: ".pi/mcp.json", text: #"{"owner":"keep","mcpServers":{"issues":{"command":"tools","enabled":false,"future":"keep"}}}"#)
        let model = await file.open()
        #expect(model.selectedFile?.path == ".pi/mcp.json")
        #expect(model.mcp.rows.first?.status == .off)
        await model.setMCPEnabled("issues", true)
        #expect(file.saves.count == 1)
        let text = try #require(file.text)
        let document = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let servers = try #require(document["mcpServers"] as? [String: [String: Any]])
        #expect(servers["issues"]?["enabled"] as? Bool == true)
        #expect(servers["issues"]?["disabled"] == nil)
        #expect(servers["issues"]?["future"] as? String == "keep")
        #expect(document["owner"] as? String == "keep")
        let selected = try #require(model.selected)
        #expect(await model.approveMCPProject(selected))
        #expect(file.approvals == [".pi/mcp.json"])
        #expect(model.mcpProjectTrusted == true)
    }

    @Test(arguments: [nil, "", "{}"] as [String?])
    func addingToMissingAndEmptyFilesPreservesTheExpectedContent(_ text: String?) async throws {
        let file = File(path: ".shepherd/mcp.json", text: text)
        let model = await file.open()
        try await model.saveMCP([MCPServerEntry(name: "docs", json: ["command": .string("docs-server")])])
        #expect(file.saves.first?.0 == text)
        #expect(model.mcp.entries.first?.json["exposure"] == .string("deferred"))
        #expect(!model.dirty)
    }

    @Test(arguments: ["{", #"{"mcpServers":[]}"#, #"{"mcpServers":{"a":null}}"#,
                      #"{"mcpServers":{"a":{"env":{"PORT":1}}}}"#,
                      #"{"mcpServers":{"a":{"args":[1]}}}"#,
                      #"{"mcpServers":{"a":{"timeout":1e100}}}"#,
                      #"{"mcpServers":{"a":{"oauth":{"scope":["read"]}}}}"#])
    func malformedConfigurationsAreNeverOverwritten(_ text: String) async throws {
        let file = File(path: ".shepherd/mcp.json", text: text)
        let model = await file.open()
        #expect(model.mcp.problem != nil && !model.mcpEditable)
        await #expect(throws: ProjectFileError.self) {
            try await model.saveMCP([MCPServerEntry(name: "new", json: ["command": .string("server")])])
        }
        #expect(file.saves.isEmpty && model.draft == text)
    }

    @Test func failedSavesKeepTheDraftAndDoNotReplaceConcurrentEdits() async throws {
        let file = File(path: ".shepherd/mcp.json", text: "{}")
        let model = await file.open()
        file.text = #"{"other":"written elsewhere"}"#
        await #expect(throws: ProjectFileError.self) {
            try await model.saveMCP([MCPServerEntry(name: "docs", json: ["url": .string("https://example.test/mcp")])])
        }
        #expect(model.dirty && model.fileError != nil)
        #expect(model.mcp.rows.map(\.name) == ["docs"])
        #expect(file.text == #"{"other":"written elsewhere"}"#)
        await model.navigate(.file(file.reference))
        #expect(model.pending != nil)
        await model.discard()
        #expect(!model.dirty && model.mcp.entries.isEmpty)
        #expect(model.mcp.document.root["other"] == .string("written elsewhere"))
    }

    @Test func normalizedImportCollisionsDoNotPartiallySaveOrOverwriteVSCodeEntries() async throws {
        let file = File(path: ".shepherd/mcp.json", text: #"{"servers":{"docs":{"command":"not-for-pi"}}}"#)
        let model = await file.open()
        await #expect(throws: ProjectFileError.self) {
            try await model.saveMCP([MCPServerEntry(name: "a-b", json: ["command": .string("a")]),
                                    MCPServerEntry(name: "a_b", json: ["command": .string("b")])])
        }
        #expect(file.saves.isEmpty)
        try await model.saveMCP([MCPServerEntry(name: "docs", json: ["command": .string("for-pi")])])
        #expect(model.mcp.document.root["servers"]?["docs"]?["command"] == .string("not-for-pi"))
        #expect(model.mcp.entries.first?.command == "for-pi")
    }

    @MainActor private final class File {
        let path: String
        var text: String?
        var saves: [(String?, String)] = []
        var approvals: [String] = []
        var reference: ProjectFile { ProjectFile(path: path, category: .mcp, exists: text != nil) }
        init(path: String, text: String?) { self.path = path; self.text = text }

        func open() async -> ProjectsModel {
            let summary = ProjectSummary(directory: "/remote/project", name: "project", displayPath: "~/project", summary: "MCP")
            let host = ProjectsHost(id: "remote", name: "build-01", known: [])
            let model = ProjectsModel { host, request in
                #expect(host.id == "remote")
                switch request {
                case .list: return .listing(ProjectListing(projects: [summary]))
                case .files: return .files([self.reference])
                case .context: return .context(ProjectContext())
                case .read(let directory, let path):
                    #expect(directory == summary.directory && path == self.path)
                    return .text(ProjectFileText(file: self.reference, text: self.text))
                case .save(let directory, let path, let text, let expected):
                    #expect(directory == summary.directory && path == self.path)
                    self.saves.append((expected, text))
                    guard expected == self.text else { throw ProjectFileError("conflict", "File changed elsewhere") }
                    self.text = text
                    return .text(ProjectFileText(file: self.reference, text: text))
                case .open: return .opened
                case .mcp(let directory, let path, let action):
                    #expect(directory == summary.directory && path == self.path)
                    if action == .approveProject {
                        self.approvals.append(path)
                        return .mcp(.init(projectTrusted: true))
                    }
                    return .mcp(.init(projectTrusted: false))
                }
            }
            await model.load([host])
            await model.open(ProjectsRow(host: host, project: summary))
            await model.navigate(.category(.mcp))
            return model
        }
    }
}
