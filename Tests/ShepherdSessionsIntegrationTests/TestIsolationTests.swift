import Foundation
import ShepherdTestSupport
import Testing

/// The isolation every test process gets when it loads (`Tests/ShepherdTestIsolation`), as the
/// login shells the app spawns see it: `pi` and `gh` are the process's stand-ins, never the
/// user's tools, whatever the system startup files do to PATH.
@Suite("Test process isolation", .integrationTimeLimit)
struct TestIsolationTests {
    enum Launch: String, CaseIterable, CustomTestStringConvertible {
        /// The environment `swift test` was started with, from a terminal.
        case inherited
        /// What Xcode or launchd hands a process: nix-darwin's /etc/zshenv then rebuilds PATH
        /// from scratch, and macOS's path_helper moves the system directories first.
        case minimal

        var testDescription: String { rawValue }

        var environment: [String: String] {
            let inherited = ProcessInfo.processInfo.environment
            switch self {
            case .inherited:
                return inherited
            case .minimal:
                var env = ["PATH": "\(TestProcess.binDirectory.path):/usr/bin:/bin:/usr/sbin:/sbin"]
                for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "ZDOTDIR"] { env[key] = inherited[key] }
                return env
            }
        }
    }

    @Test(arguments: Launch.allCases)
    func aLoginShellResolvesPiAndGhToTheStandIns(launch: Launch) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", "command -v pi; command -v gh"]
        process.environment = launch.environment
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let bin = TestProcess.binDirectory
        let resolved = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        #expect(resolved == [bin.appendingPathComponent("pi").path, bin.appendingPathComponent("gh").path])
    }
}
