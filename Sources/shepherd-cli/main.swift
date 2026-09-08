import Darwin
import Foundation
import ShepherdCore
import ShepherdProtocol

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("shepherd: \(message)\n".utf8))
    exit(1)
}

/// True when a Shepherd app instance is serving the extension socket.
func shepherdIsRunning() -> Bool {
    let path = ShepherdPaths.socketURL().path
    guard FileManager.default.fileExists(atPath: path) else { return false }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let ok = path.withCString { cstr in
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let bytes = path.utf8.count
            guard bytes < raw.count else { return false }
            memcpy(raw.baseAddress!, cstr, bytes + 1)
            return true
        }
    }
    guard ok else { return false }
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    return connected == 0
}

func importHerdr() {
    let herdrURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/herdr/session.json")
    guard let data = try? Data(contentsOf: herdrURL) else {
        fail("no herdr session found at \(herdrURL.path)")
    }
    let herdr: HerdrSession
    do {
        herdr = try JSONDecoder().decode(HerdrSession.self, from: data)
    } catch {
        fail("could not parse \(herdrURL.path): \(error)")
    }

    if shepherdIsRunning() {
        fail("Shepherd is running — quit it first so the import can write state.json safely")
    }

    let stateURL = ShepherdPaths.stateURL()
    var state = ShepherdState()
    if let existing = try? Data(contentsOf: stateURL) {
        do {
            state = try JSONDecoder().decode(ShepherdState.self, from: existing)
        } catch {
            fail("could not parse existing \(stateURL.path): \(error)")
        }
    }

    let summary = HerdrImport.merge(herdr, into: &state) { sessionPath in
        HerdrImport.firstUserMessage(
            inSessionFile: URL(fileURLWithPath: (sessionPath as NSString).expandingTildeInPath)
        )
    }

    do {
        try state.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try encoder.encode(state).write(to: stateURL, options: .atomic)
    } catch {
        fail("could not write \(stateURL.path): \(error)")
    }

    print("Imported from herdr: \(summary.spacesAdded) space(s), \(summary.agentsAdded) agent(s)"
        + (summary.agentsSkipped > 0 ? " (\(summary.agentsSkipped) already present)" : ""))
    print("Launch Shepherd to pick up the imported workspace.")
}

let usage = """
Usage: shepherd --import herdr

Options:
  --import herdr   Import herdr workspaces and pi agent sessions into Shepherd
  --help           Show this help
"""

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "--import" where args.count == 2 && args[1] == "herdr":
    importHerdr()
case "--help", "-h", nil:
    print(usage)
default:
    fail("unknown arguments: \(args.joined(separator: " "))\n\(usage)")
}
