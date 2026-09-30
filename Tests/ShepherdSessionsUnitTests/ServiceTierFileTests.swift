import Foundation
import ShepherdCore
import ShepherdTestKit
import Testing
@testable import ShepherdSessions

/// The file the host keeps for an agent's pi (`ServiceTierFile`): its format is the contract
/// with `Extensions/shepherd-service-tier.ts`, which reads it on every provider request.
@Suite("Service tier file")
struct ServiceTierFileTests {
    static let engine = PiEngine(command: ["/tmp/pi-engine"], packageDirectory: nil, version: nil, node: .onPath("node"))

    private func scratchHome() throws -> (home: PiHome, directory: URL) {
        let directory = try makeTempDirectory()
        return (PiHome(directory: directory.appendingPathComponent("pi"), engine: Self.engine), directory)
    }

    @Test func aTierIsWrittenAsTheJSONTheExtensionReads() throws {
        let (home, directory) = try scratchHome()
        defer { try? FileManager.default.removeItem(at: directory) }
        let agent = AgentID(rawValue: "0f2a9c1e-3b44-4d10-9f3e-7a5d2b8c6e11")
        try ServiceTierFile.write(.fast, for: agent, in: home)
        let file = try #require(ServiceTierFile.url(for: agent, in: home))
        #expect(file.path.hasSuffix("/pi/service-tier/0f2a9c1e-3b44-4d10-9f3e-7a5d2b8c6e11.json"))
        #expect(String(decoding: try Data(contentsOf: file), as: UTF8.self) == #"{"tier":"fast"}"#)
        #expect(try posixPermissions(file) == 0o600)
        #expect(ServiceTierFile.read(for: agent, in: home) == .fast)
    }

    @Test func aChangeReplacesTheFileAndNeverLeavesAnythingElseBehind() throws {
        let (home, directory) = try scratchHome()
        defer { try? FileManager.default.removeItem(at: directory) }
        let agent = AgentID()
        for tier in [ServiceTier.fast, .standard, .fast, .standard] {
            try ServiceTierFile.write(tier, for: agent, in: home)
            #expect(ServiceTierFile.read(for: agent, in: home) == tier)
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: ServiceTierFile.directory(in: home).path)
        #expect(names == ["\(agent.rawValue).json"], "temporary files are renamed away")
    }

    @Test func noFileAnUnreadableOneOrAnUnknownTierIsStandard() throws {
        let (home, directory) = try scratchHome()
        defer { try? FileManager.default.removeItem(at: directory) }
        let agent = AgentID()
        #expect(ServiceTierFile.read(for: agent, in: home) == .standard)
        try FileManager.default.createDirectory(at: ServiceTierFile.directory(in: home), withIntermediateDirectories: true)
        let file = try #require(ServiceTierFile.url(for: agent, in: home))
        for text in ["", "fast", "{}", #"{"tier":"ultrafast"}"#, #"{"tier":7}"#, "[1]"] {
            try Data(text.utf8).write(to: file)
            #expect(ServiceTierFile.read(for: agent, in: home) == .standard, "\(text)")
        }
    }

    @Test func removingAnAgentsFileForgetsItsTier() throws {
        let (home, directory) = try scratchHome()
        defer { try? FileManager.default.removeItem(at: directory) }
        let agent = AgentID()
        try ServiceTierFile.write(.fast, for: agent, in: home)
        ServiceTierFile.remove(for: agent, in: home)
        #expect(ServiceTierFile.read(for: agent, in: home) == .standard)
        ServiceTierFile.remove(for: agent, in: home)
    }

    @Test(arguments: ["", "../x", "a/b", "a b", "x.json", ".."])
    func anIdThatIsNotAnIdNamesNoFile(raw: String) throws {
        let (home, directory) = try scratchHome()
        defer { try? FileManager.default.removeItem(at: directory) }
        let agent = AgentID(rawValue: raw)
        #expect(ServiceTierFile.url(for: agent, in: home) == nil)
        #expect(ServiceTierExtension.environment(for: agent, in: home).isEmpty)
        #expect(throws: (any Error).self) { try ServiceTierFile.write(.fast, for: agent, in: home) }
    }

    @Test func aLinkInTheHomeCannotCarryTheFileOutOfIt() throws {
        let (home, directory) = try scratchHome()
        defer { try? FileManager.default.removeItem(at: directory) }
        let elsewhere = directory.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: ServiceTierFile.directory(in: home), withDestinationURL: elsewhere)
        #expect(throws: (any Error).self) { try ServiceTierFile.write(.fast, for: AgentID(), in: home) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
    }

    @Test func anAgentsPiIsToldWhereItsFileIs() throws {
        let (home, directory) = try scratchHome()
        defer { try? FileManager.default.removeItem(at: directory) }
        let agent = AgentID(rawValue: "agent-1")
        let file = try #require(ServiceTierFile.url(for: agent, in: home))
        #expect(ServiceTierExtension.environment(for: agent, in: home) == ["SHEPHERD_EXT_SERVICE_TIER": file.path])
        #expect(ServiceTierExtension.path(in: home) == home.directory.appendingPathComponent("shepherd-service-tier.ts").path)
    }

    @Test func installingTheHomeWritesTheExtensionBesideItsOtherFiles() throws {
        let (home, directory) = try scratchHome()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: home.directory, withIntermediateDirectories: true)
        try ServiceTierExtension.install(in: home)
        #expect(try String(contentsOfFile: ServiceTierExtension.path(in: home), encoding: .utf8) == ServiceTierExtension.extensionSource)
    }
}
