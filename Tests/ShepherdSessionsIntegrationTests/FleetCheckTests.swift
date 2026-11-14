import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestKit
import ShepherdTestSupport

/// Check between real scratch hosts: each Mac looks at itself (read only, from sources the test answers for it), keeps what it found, pushes it to the
/// Macs that take it, and looks again when asked or when a thread that was fixing something ends. No test sleeps.
@Suite("Fleet check", .integrationTimeLimit)
struct FleetCheckIntegrationTests {
    typealias Mac = FleetPressureIntegrationTests.Mac

    /// A shell that answers as a Mac with this node would, counting how often it was asked.
    final class Looks: @unchecked Sendable {
        private let lock = NSLock()
        private var asked = 0
        private var node: String
        init(node: String) { self.node = node }
        var count: Int { lock.withLock { asked } }
        func setNode(_ version: String) { lock.withLock { node = version } }
        /// One look: counted, and answered with the node this Mac has now.
        func answer() -> LoginShell.Output {
            let node = lock.withLock { asked += 1; return self.node }
            return LoginShell.Output(status: 0, stdout: "@need:node\n=\(node)\n@pm\n=nix\n@sleep\n=0\n@power\nNow drawing from 'AC Power'\n", stderr: "")
        }

        var sources: FleetCheck.Sources {
            FleetCheck.Sources(
                shell: { _ in self.answer() },
                remote: { _ in true }, providers: { [] }, freeBytes: { _ in 500_000_000_000 })
        }
    }

    /// A checkout whose `.nvmrc` pins node 22, so every Mac that has it is asked what node it runs.
    static func project(in dir: URL) throws -> FleetLocalFacts {
        let folder = dir.appendingPathComponent("acme-web", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "22\n".write(to: folder.appendingPathComponent(".nvmrc"), atomically: true, encoding: .utf8)
        return FleetLocalFacts(spaces: [("acme-web", folder.path)])
    }

    /// A Mac with that project and these answers.
    static func mac(_ name: String, busy: UInt64, _ looks: Looks, in dir: URL) async throws -> Mac {
        let facts = try project(in: dir.appendingPathComponent(name, isDirectory: true))
        return try await Mac(name, busy: busy, facts: { facts }, check: looks.sources)
    }

    func needs(_ report: FleetCheckReport?, node id: String = "need:node:22") -> FleetCheckItem? { report?.items.first { $0.id == id } }

    @Test func aMacChecksItselfAndPushesWhatItFoundToTheMacsThatTakeIt() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chk-\(UUID().uuidString.prefix(6))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (one, two) = (Looks(node: "v22.11.0"), Looks(node: "v20.18.1"))
        let a = try await Self.mac("MacBook Pro", busy: 30, one, in: dir), b = try await Self.mac("Mac mini", busy: 60, two, in: dir)
        defer { a.stop(); b.stop() }
        try await FleetPressureIntegrationTests.pair(a, b)
        let (aID, bID) = (try await a.hostID(), try await b.hostID())

        // Each holds its own report, and the other's, with the age by its own clock.
        try await eventually("each Mac to hold both reports") {
            guard let own = try await a.state(of: aID), let theirs = try await a.state(of: bID) else { return false }
            return own.check != nil && theirs.check != nil
        }
        let own = try #require(try await a.state(of: aID)), theirs = try #require(try await b.state(of: aID))
        #expect(own.checkAge != nil && theirs.checkAge == 0, "stamped on arrival by the receiver's clock")
        #expect(own.check?.packageManager == "nix")
        #expect(needs(own.check)?.value == "22.11" && needs(theirs.check)?.value == "22.11", "what A's shell said is what B holds of A")
        let atA = needs(try await a.state(of: bID)?.check)
        #expect(atA?.value == "Has 20.18", "\(String(describing: atA))")
        #expect(one.count > 0 && two.count > 0, "each Mac asked its own shell and no other")
    }

    @Test func checkNowAsksEveryMacToLookAgainAndKeepsTheAnswers() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chk-\(UUID().uuidString.prefix(6))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (one, two) = (Looks(node: "v22.11.0"), Looks(node: "v20.18.1"))
        let a = try await Self.mac("MacBook Pro", busy: 30, one, in: dir), b = try await Self.mac("Mac mini", busy: 60, two, in: dir)
        defer { a.stop(); b.stop() }
        try await FleetPressureIntegrationTests.pair(a, b)
        let bID = try await b.hostID()
        try await eventually("A to hold B's first report") { try await a.state(of: bID)?.check != nil }

        two.setNode("v22.4.0")
        let before = two.count
        _ = try await a.local.fleetAction(.checkNow)
        #expect(two.count > before, "B looked at itself because A asked")
        try await eventually("A to hold what B found the second time") {
            needs(try await a.state(of: bID)?.check)?.value == "22.4"
        }
    }

    @Test func aMacThatMakesNoCheckStillPairsAndSharesPressure() async throws {
        // A host that makes no Check (the previous Nightly's behavior): it pairs, its pressure and readiness flow, and it holds no report of its own.
        let a = try await Mac("MacBook Pro", busy: 30, check: Looks(node: "v22.11.0").sources), b = try await Mac("Mac mini", busy: 60)
        defer { a.stop(); b.stop() }
        try await FleetPressureIntegrationTests.pair(a, b)
        let (aID, bID) = (try await a.hostID(), try await b.hostID())
        try await eventually("A to hold its own report and B's pressure") {
            guard let own = try await a.state(of: aID), let theirs = try await a.state(of: bID) else { return false }
            return own.check != nil && theirs.sample != nil
        }
        #expect(try await a.state(of: bID)?.check == nil, "B makes no Check")
        #expect(try await b.state(of: aID)?.check != nil, "a Mac that takes Check is still told what A found")
    }
}
