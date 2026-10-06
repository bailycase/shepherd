import Foundation
import Testing
import ShepherdProtocol

@Suite("Project settings protocol")
struct ProjectsProtocolTests {
    @Test(arguments: [RemoteProjectsRequest.mcp(directory: "/host/repo", file: ".pi/mcp.json", action: .credentials),
                      .mcp(directory: "/host/repo", file: ".pi/mcp.json", action: .login(server: "issues")),
                      .mcp(directory: "/host/repo", file: ".mcp.json", action: .logout(server: "issues")),
                      .mcp(directory: "/host/repo", file: ".pi/mcp.json", action: .poll(id: UUID())),
                      .mcp(directory: "/host/repo", file: ".pi/mcp.json", action: .cancel(id: UUID())),
                      .mcp(directory: "/host/repo", file: ".pi/mcp.json", action: .complete(id: UUID(), redirectURL: "http://127.0.0.1:1234/callback?code=test&state=test")),
                      RemoteProjectsRequest.list(), .list(offset: 64), .files(directory: "/host/repo"),
                      .context(directory: "/host/repo"), .open(directory: "/host/repo", file: "AGENTS.md"),
                      .read(directory: "/host/repo", file: ".pi/settings.json"),
                      .save(directory: "/host/repo", file: "AGENTS.md", text: "new", expected: nil),
                      .save(directory: "/host/repo", file: "AGENTS.md", text: "new", expected: "old")])
    func eachRequestRoundTrips(_ request: RemoteProjectsRequest) throws {
        let value = RemoteRequest.projects(id: 7, request: request)
        #expect(try NDJSON.decode(RemoteRequest.self, from: NDJSON.encode(value)) == value)
    }

    @Test(arguments: [RemoteProjectsResult.mcp(.init(id: UUID(), phase: .waiting, authorizationURL: "https://example.test/auth")),
                      .mcp(.init(signedIn: ["issues"])), .mcp(.init(phase: .failed, message: "Cancelled.")),
                      RemoteProjectsResult.opened, .context(ProjectContext(files: [.init(path: "/a/AGENTS.md", displayPath: "~/a/AGENTS.md")], resources: 4, mcpServers: 1)), RemoteProjectsResult.listing(ProjectListing(projects: [], nextOffset: 64)),
                      .listing(ProjectListing(projects: [ProjectSummary(directory: "/a", name: "a", displayPath: "~/a", summary: "AGENTS.md only", minimal: true)])),
                      .files([ProjectFile(path: "AGENTS.md", category: .instructions, exists: false)]),
                      .text(ProjectFileText(file: ProjectFile(path: "AGENTS.md", category: .instructions, exists: false), text: nil)),
                      .text(ProjectFileText(file: ProjectFile(path: "AGENTS.md", category: .instructions, exists: true), text: ""))])
    func eachResultRoundTrips(_ result: RemoteProjectsResult) throws {
        let value = RemoteReply.projects(id: 9, result: result)
        #expect(try NDJSON.decode(RemoteReply.self, from: NDJSON.encode(value)) == value)
    }
}
