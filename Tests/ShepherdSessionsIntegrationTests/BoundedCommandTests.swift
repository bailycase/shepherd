import Darwin
import Foundation
import Testing
import ShepherdTestSupport
@testable import ShepherdSessions

@Suite("Bounded catalog and skills commands", .integrationTimeLimit)
struct BoundedCommandTests {
    /// The fixture arms a watchdog before publishing either PID. Even a broken timeout runner
    /// cannot leave its group around indefinitely; defer is the second cleanup boundary.
    private func script(in dir: URL, mode: String) throws -> URL {
        let file = dir.appendingPathComponent("fixture.sh")
        let body = """
        #!/bin/bash
        trap '' TERM
        pgid=$(/bin/ps -o pgid= -p $$ | /usr/bin/tr -d ' ')
        /bin/bash -c 'trap - TERM; sleep 12; kill -KILL -- -'"$pgid" >/dev/null 2>&1 &
        echo "$pgid" > '\(dir.path)/group'
        echo $$ > '\(dir.path)/leader'
        if [ '\(mode)' = burst ]; then
          /usr/bin/head -c 200000 /dev/zero >&2
          printf 'provider model context thinking\\nfixture model 64K no\\n'
          exit 0
        fi
        if [ '\(mode)' = closedPipes ]; then exec >/dev/null 2>&1; fi
        /bin/bash -c 'trap "" TERM; echo $$ > "$1"; while :; do sleep 1; done' fixture '\(dir.path)/helper' &
        if [ '\(mode)' = leaderExit ]; then
          while [ ! -f '\(dir.path)/helper' ]; do sleep 0.01; done
          exit 0
        fi
        while :; do sleep 1; done
        """
        try body.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }

    private func pids(_ dir: URL) -> [pid_t] {
        ["leader", "helper"].compactMap { name in
            (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8))
                .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
    }

    private func cleanup(_ dir: URL) {
        if let text = try? String(contentsOf: dir.appendingPathComponent("group"), encoding: .utf8),
           let group = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) { kill(-group, SIGKILL) }
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func catalogDrainsStderrAndReturnsTheRealListing() throws {
        let dir = try makeScratchDirectory()
        defer { cleanup(dir) }
        let executable = try script(in: dir, mode: "burst")
        let home = PiHome(directory: dir.appendingPathComponent("pi"), engine: PiEngine(
            command: [executable.path], packageDirectory: nil, version: nil, node: .executable("/usr/bin/false")))
        try FileManager.default.createDirectory(at: home.launcher.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: executable, to: home.launcher)
        let catalog = PiModelCatalog(home: home, timeout: 5, ready: { true })
        #expect(catalog.modelIDs() == ["fixture/model"])
    }

    @Test(arguments: ["hang", "closedPipes", "leaderExit"])
    func catalogFailureIsBoundedAndLeavesNoOwnedHelpers(mode: String) async throws {
        let dir = try makeScratchDirectory()
        defer { cleanup(dir) }
        let executable = try script(in: dir, mode: mode)
        let home = PiHome(directory: dir.appendingPathComponent("pi"), engine: PiEngine(
            command: [executable.path], packageDirectory: nil, version: nil, node: .executable("/usr/bin/false")))
        try FileManager.default.createDirectory(at: home.launcher.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: executable, to: home.launcher)
        try Data(#"{"providers":{"fallback":{"models":[{"id":"configured"}]}}}"#.utf8)
            .write(to: home.directory.appendingPathComponent("models.json"))
        let catalog = PiModelCatalog(home: home, timeout: 1, ready: { true })
        let clock = ContinuousClock(), start = ContinuousClock.now
        #expect(catalog.entriesOrConfigured().map(\.id) == ["fallback/configured"])
        #expect(clock.now - start < .seconds(6))
        let owned = pids(dir)
        #expect(owned.count == 2)
        try await eventually("catalog leader and helper to exit") { owned.allSatisfy { kill($0, 0) != 0 } }
    }

    @Test(arguments: ["hang", "closedPipes", "leaderExit"])
    func skillsGitBoundsExitAndInheritedPipesAndAllowsTheNextCommand(mode: String) async throws {
        let dir = try makeScratchDirectory()
        defer { cleanup(dir) }
        let executable = try script(in: dir, mode: mode)
        // A git shell alias stays entirely local and execs the controlled fixture.
        let clock = ContinuousClock(), start = ContinuousClock.now
        if mode == "leaderExit" {
            #expect(try SkillsGit.run(["-c", "alias.fixture=!exec '\(executable.path)'", "fixture"], in: dir, timeout: 1).isEmpty)
        } else {
            #expect(throws: SkillsGit.Failure.self) {
                try SkillsGit.run(["-c", "alias.fixture=!exec '\(executable.path)'", "fixture"], in: dir, timeout: 1)
            }
        }
        #expect(clock.now - start < .seconds(6))
        let owned = pids(dir)
        #expect(owned.count == 2)
        try await eventually("git helper processes to exit") { owned.allSatisfy { kill($0, 0) != 0 } }
        #expect(String(decoding: try SkillsGit.run(["--version"], in: dir, timeout: 1), as: UTF8.self).hasPrefix("git version"))
    }

    @Test func commandsStreamLargeInputAndPreserveExitErrors() throws {
        let input = Data(repeating: 65, count: 1 << 20)
        let echoed = try BoundedCommand.run(["/bin/cat"], input: input, timeout: 2)
        #expect(echoed.status == 0 && echoed.output == input)
        let failed = try BoundedCommand.run(["/bin/sh", "-c", "printf 'failure detail\\n' >&2; exit 7"], timeout: 1)
        #expect(failed.status == 7 && String(decoding: failed.errors, as: UTF8.self) == "failure detail\n")
    }

    @Test func blockedInputAndOutputOverflowAlsoStopTheirOwnedProcess() async throws {
        let dir = try makeScratchDirectory()
        defer { cleanup(dir) }
        let executable = try script(in: dir, mode: "hang")
        #expect(throws: BoundedCommand.Failure.timedOut) {
            try BoundedCommand.run([executable.path], input: Data(repeating: 65, count: 1 << 20), timeout: 1)
        }
        let owned = pids(dir)
        try await eventually("blocked-input processes to exit") { owned.allSatisfy { kill($0, 0) != 0 } }
        #expect(throws: BoundedCommand.Failure.outputTooLarge) {
            try BoundedCommand.run(["/usr/bin/yes"], timeout: 1, outputLimit: 1024)
        }
    }
}
