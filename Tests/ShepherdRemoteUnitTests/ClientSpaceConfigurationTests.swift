import Foundation
import ShepherdProtocol
import ShepherdRemote
import Testing

@MainActor
struct ClientSpaceConfigurationTests {
    private let root = "/demo/acme/acme-web"
    private let instructions = ProjectFile(path: "AGENTS.md", category: .instructions, exists: true)

    @Test(arguments: [nil, ""] as [String?])
    func saveUsesTheExactReadBaseline(original: String?) async {
        let file = ProjectFile(path: instructions.path, category: .instructions, exists: original != nil)
        var writes: [RemoteProjectsRequest] = []
        let model = ClientSpaceConfiguration(directory: root, capabilities: [RemoteProtocol.projectsV2Capability]) { request in
            switch request {
            case .files(directory: root): return .files([file])
            case .read(directory: root, file: file.path): return .text(.init(file: file, text: original))
            case .save:
                writes.append(request)
                return .text(.init(file: instructions, text: "# acme-web"))
            default: throw ProjectFileError("test", "Unexpected request: \(request)")
            }
        }
        await model.load()
        model.setText("# acme-web", file: file.path)
        await model.save(file.path)
        #expect(writes == [.save(directory: root, file: file.path, text: "# acme-web", expected: original)])
        #expect(model.drafts[file.path]?.isEdited == false)
        #expect(model.files?[.instructions]?.first?.exists == true)
    }

    @Test func staleExpectedKeepsTheDraftAndCannotOverwriteUntilReloaded() async {
        let path = instructions.path
        var hostText = "# original"
        var attempts = 0
        let model = ClientSpaceConfiguration(directory: root, capabilities: [RemoteProtocol.projectsV2Capability]) { request in
            switch request {
            case .files: return .files([instructions])
            case .read: return .text(.init(file: instructions, text: hostText))
            case .save(_, _, let text, let expected):
                attempts += 1
                guard expected == hostText else { throw RemoteHostClientError.rejected(code: "conflict", message: "Changed elsewhere.") }
                hostText = text
                return .text(.init(file: instructions, text: text))
            default: throw ProjectFileError("test", "Unexpected request: \(request)")
            }
        }
        await model.load()
        model.setText("# mobile edits", file: path)
        hostText = "# newer host version"
        await model.save(path)
        #expect(hostText == "# newer host version")
        #expect(model.drafts[path]?.saved.text == "# original")
        #expect(model.drafts[path]?.text == "# mobile edits")
        #expect(model.drafts[path]?.conflict == true)
        await model.save(path)
        #expect(attempts == 1)
        await model.open(path, discard: true)
        #expect(model.drafts[path]?.text == "# newer host version")
        model.setText("# reapplied edits", file: path)
        await model.save(path)
        #expect(hostText == "# reapplied edits")
    }

    @Test func optionalOperationsDoNotSendToAHostWithOnlyProjectsV2() async throws {
        let file = ProjectFile(path: ".shepherd/mcp.json", category: .mcp, exists: true)
        var sent: [RemoteProjectsRequest] = []
        let model = ClientSpaceConfiguration(directory: root, capabilities: [RemoteProtocol.projectsV2Capability]) { request in
            sent.append(request)
            switch request {
            case .files: return .files([file])
            case .read: return .text(.init(file: file, text: #"{"mcpServers":{"docs":{"url":"https://docs.example.com"}}}"#))
            default: throw ProjectFileError("test", "Unexpected request: \(request)")
            }
        }
        await model.load()
        await model.loadMCP()
        let server = try #require(model.servers.first)
        await model.authenticate(server, signIn: true) { _ in Issue.record("OAuth must not start"); return "" }
        await model.loadResources()
        _ = await model.installSkills(repo: "acme/skills", paths: ["review"], commit: nil)
        _ = await model.delete(.init(kind: .skill, name: "review", path: ".pi/skills/review/SKILL.md"))
        await model.setInherited(.mcp, "docs", on: false)
        await model.open(".env")
        #expect(sent == [.files(directory: root), .read(directory: root, file: file.path)])
        #expect(server.usesOAuth)
        #expect(!model.canUseMCP && !model.canManageResources)
    }

    @Test func inheritanceReplacesOnlyTheSelectedExclusionOnTheChild() async {
        let parent = "/demo/acme"
        let initial = SpaceInheritanceExclusions(mcp: ["docs"], skills: ["review"], prompts: ["release"], extensions: ["audit.js"])
        let next = SpaceInheritanceExclusions(skills: ["review"], prompts: ["release"], extensions: ["audit.js"])
        var sent: [RemoteProjectsRequest] = []
        let model = ClientSpaceConfiguration(directory: root, capabilities: [RemoteProtocol.projectsV2Capability, RemoteProtocol.projectDetailsCapability,
            RemoteProtocol.projectResourcesCapability, RemoteProtocol.projectInheritanceCapability, RemoteProtocol.projectInheritedResourcesCapability]) { request in
            switch request {
            case .files: return .files([])
            case .context: return .context(.init(inheritsFrom: parent, excluded: initial))
            case .inheritance:
                sent.append(request)
                return .context(.init(inheritsFrom: parent, excluded: next))
            default: throw ProjectFileError("test", "Unexpected request: \(request)")
            }
        }
        await model.load()
        #expect(!model.inherits(.mcp, "docs"))
        await model.setInherited(.mcp, "docs", on: true)
        #expect(sent == [.inheritance(directory: root, excluded: next)])
        #expect(model.inherits(.mcp, "docs"))
        #expect(!model.inherits(.skill, "review"))
    }

    @Test func resourcesUseTheReviewedVersionForDeletionAndRefreshAfterInstall() async {
        let path = ".pi/skills/review/SKILL.md"
        let resource = ProjectResource(kind: .skill, name: "review", path: path)
        let file = ProjectFile(path: path, category: .skills, exists: true)
        var installed = false
        var writes: [RemoteProjectsRequest] = []
        let model = ClientSpaceConfiguration(directory: root, capabilities: [RemoteProtocol.projectsV2Capability, RemoteProtocol.projectResourcesCapability]) { request in
            switch request {
            case .files: return .files([])
            case .resources: return .resources(installed ? [resource] : [])
            case .read: return .text(.init(file: file, text: "# Review"))
            case .installSkills:
                writes.append(request)
                installed = true
                return .files([file])
            case .delete:
                writes.append(request)
                installed = false
                return .text(.init(file: .init(path: path, category: .skills, exists: false), text: nil))
            default: throw ProjectFileError("test", "Unexpected request: \(request)")
            }
        }
        await model.load()
        #expect(await model.installSkills(repo: "acme/skills", paths: ["skills/review"], commit: "demo-rev"))
        #expect(model.resources[.skill] == [resource])
        #expect(await model.delete(resource) == false)
        await model.open(path)
        #expect(await model.delete(resource))
        #expect(writes == [.installSkills(directory: root, repo: "acme/skills", paths: ["skills/review"], commit: "demo-rev"),
                           .delete(directory: root, file: path, expected: "# Review")])
        #expect(model.resources[.skill]?.isEmpty != false)
        #expect(model.drafts[path] == nil)
    }

    @Test func oauthCompletesOnlyTheMatchingLoopbackCallback() async throws {
        let file = ProjectFile(path: ".shepherd/mcp.json", category: .mcp, exists: true)
        let id = UUID()
        let expected = "http://127.0.0.1:4718/callback?state=fixture&code=demo-code"
        let authorization = "https://auth.example.com/login?redirect_uri=http%3A%2F%2F127.0.0.1%3A4718%2Fcallback&state=fixture"
        var actions: [ProjectMCPAction] = []
        let model = ClientSpaceConfiguration(directory: root, capabilities: [RemoteProtocol.projectsV2Capability, RemoteProtocol.projectMCPCapability]) { request in
            switch request {
            case .files: return .files([file])
            case .read: return .text(.init(file: file, text: #"{"mcpServers":{"docs":{"url":"https://docs.example.com"}}}"#))
            case .mcp(directory: root, file: file.path, action: let action):
                actions.append(action)
                switch action {
                case .login(server: "docs"): return .mcp(.init(id: id, phase: .waiting, authorizationURL: authorization))
                case .complete(id: id, redirectURL: expected), .cancel(id: id): return .mcp(.init())
                case .credentials: return .mcp(.init(signedIn: actions.contains(.complete(id: id, redirectURL: expected)) ? ["docs"] : []))
                default: throw ProjectFileError("test", "Unexpected MCP action: \(action)")
                }
            default: throw ProjectFileError("test", "Unexpected request: \(request)")
            }
        }
        await model.load()
        await model.loadMCP()
        let server = try #require(model.servers.first)
        await model.authenticate(server, signIn: true) { _ in "http://127.0.0.1:4718/callback?state=wrong&code=demo-code" }
        #expect(actions == [.credentials, .login(server: "docs"), .cancel(id: id)])
        #expect(model.signedIn[file.path] == [])
        await model.authenticate(server, signIn: true) { url in
            #expect(url.absoluteString == authorization)
            return expected
        }
        #expect(actions.suffix(4) == [.login(server: "docs"), .complete(id: id, redirectURL: expected), .cancel(id: id), .credentials])
        #expect(model.signedIn[file.path] == ["docs"])
    }
}
