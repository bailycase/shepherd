import Foundation
import Testing
@testable import ShepherdSessions

/// pi's agent directory (config and sessions) resolves like pi's own `PI_CODING_AGENT_DIR`,
/// against an explicit environment.
@Suite("pi agent directory")
struct PiConfigTests {
    private static let home = FileManager.default.homeDirectoryForCurrentUser.path

    @Test(arguments: [
        (nil, "\(home)/.pi/agent"),
        ("", "\(home)/.pi/agent"),
        ("  ", "\(home)/.pi/agent"),
        ("/tmp/pi-agent/../pi-agent2", "/tmp/pi-agent2"),
        ("~/elsewhere", "\(home)/elsewhere"),
    ] as [(String?, String)])
    func theAgentDirectoryFollowsPisOverride(_ override: String?, expected: String) {
        let env = override.map { [PiConfig.agentDirectoryEnvKey: $0] } ?? [:]
        #expect(PiConfig.agentDirectory(environment: env).path == expected)
        #expect(PiConfig.sessionsDirectory(environment: env).path == expected + "/sessions")
    }
}
