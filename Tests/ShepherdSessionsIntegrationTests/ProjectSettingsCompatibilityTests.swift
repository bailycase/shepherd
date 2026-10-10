import Darwin
import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport

@Suite("Legacy remote project compatibility", .integrationTimeLimit)
struct ProjectSettingsCompatibilityTests {
    @Test func currentClientsReadEditAndApproveTheNativePathInventoriedByAV1Host() async throws {
        let project = ProjectSummary(directory: "/legacy/project", name: "legacy", displayPath: "/legacy/project", summary: "MCP")
        let file = ProjectFile(path: ".pi/mcp.json", category: .mcp, exists: true)
        let original = #"{"mcpServers":{"tools":{"command":"tools","enabled":false,"future":"keep"}}}"#
        let saved = Locked(original)
        let requests = Locked<[RemoteProjectsRequest]>([])
        let server = try LoopbackServer { fd in
            defer { close(fd) }
            var line = Data()
            while let byte = LoopbackServer.readExactly(fd, 1) {
                guard byte.first == 10 else {
                    line.append(byte)
                    if line.count > NDJSON.maxPayloadBytes { Issue.record("Oversized fixture request"); return }
                    continue
                }
                do {
                    let request = try NDJSON.decode(RemoteRequest.self, from: line)
                    line.removeAll(keepingCapacity: true)
                    let reply: RemoteReply
                    switch request {
                    case .hello(let id, _, _, let version, let capabilities):
                        #expect(version == 1 && capabilities?.contains("projects.v2") == true)
                        reply = .helloOk(id: id, protocolVersion: 1, capabilities: ["projects.v1", "projects.mcp.v1", "projects.trust.v1"])
                    case .stateFetch(let id): reply = .state(id: id, state: ShepherdState())
                    case .projects(let id, let projectRequest):
                        requests.withValue { $0.append(projectRequest) }
                        switch projectRequest {
                        case .list: reply = .projects(id: id, result: .listing(.init(projects: [project])))
                        case .files(let directory):
                            #expect(directory == project.directory)
                            reply = .projects(id: id, result: .files([file]))
                        case .read(let directory, let path):
                            #expect(directory == project.directory && path == ".pi/mcp.json")
                            reply = .projects(id: id, result: .text(.init(file: file, text: saved.current)))
                        case .save(let directory, let path, let text, let expected):
                            #expect(directory == project.directory && path == ".pi/mcp.json" && expected == saved.current)
                            saved.withValue { $0 = text }
                            reply = .projects(id: id, result: .text(.init(file: file, text: text)))
                        case .mcp(let directory, let path, let action):
                            #expect(directory == project.directory && path == ".pi/mcp.json" && action == .approveProject)
                            reply = .projects(id: id, result: .mcp(.init(projectTrusted: true)))
                        default: Issue.record("Unexpected project request: \(projectRequest)"); return
                        }
                    default: Issue.record("Unexpected legacy host request: \(request)"); return
                    }
                    guard LoopbackServer.writeAll(fd, try NDJSON.encode(reply)) else { return }
                } catch { Issue.record("Legacy fixture failed: \(error)"); return }
            }
        }
        defer { server.stop() }
        let client = RemoteHostClient()
        defer { client.disconnect() }
        _ = try await client.connect(host: "127.0.0.1", port: server.port, token: "fixture", clientName: "current")
        #expect(client.capabilities.contains("projects.v1") && !client.capabilities.contains("projects.v2"))
        guard case .listing(let listing) = try await client.projects(.list()),
              case .files(let files) = try await client.projects(.files(directory: project.directory)),
              case .text(let text) = try await client.projects(.read(directory: project.directory, file: file.path)) else {
            Issue.record("Current client could not read the legacy inventory"); return
        }
        #expect(listing.projects == [project] && files == [file] && text.text == original)
        let enabled = #"{"mcpServers":{"tools":{"command":"tools","enabled":true,"future":"keep"}}}"#
        _ = try await client.projects(.save(directory: project.directory, file: file.path, text: enabled, expected: original))
        #expect(saved.current == enabled)
        guard case .mcp(let approval) = try await client.projects(.mcp(directory: project.directory, file: file.path, action: .approveProject)) else {
            Issue.record("Legacy approval failed"); return
        }
        #expect(approval.projectTrusted == true)
        #expect(requests.current.last == .mcp(directory: "/legacy/project", file: ".pi/mcp.json", action: .approveProject))
    }
}
