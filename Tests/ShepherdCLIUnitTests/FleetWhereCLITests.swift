import Foundation
import Testing
@testable import shepherd_cli

/// `shepherd-cli fleet-where` hands over to the app's own executable beside it in the bundle.
@Suite("shepherd-cli fleet-where")
struct FleetWhereCLITests {
    /// A bundle laid out like an app's, in a scratch folder: Info.plist naming the executable, and both programs in MacOS.
    private func bundle(executable: String?, present: Bool = true) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fleet-where-\(UUID().uuidString)")
        let macOS = root.appendingPathComponent("Shepherd Nightly.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        if let executable {
            let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": executable], format: .xml, options: 0)
            try plist.write(to: macOS.deletingLastPathComponent().appendingPathComponent("Info.plist"))
            if present {
                let file = macOS.appendingPathComponent(executable)
                try Data("#!/bin/sh\n".utf8).write(to: file)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            }
        }
        try Data().write(to: macOS.appendingPathComponent("shepherd-cli"))
        return macOS.appendingPathComponent("shepherd-cli")
    }

    @Test func theAppExecutableIsTheOneItsInfoPlistNames() throws {
        let cli = try bundle(executable: "Shepherd Nightly")
        defer { try? FileManager.default.removeItem(at: cli.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
        let app = try #require(FleetWhereCLI.appExecutable(cli: cli))
        #expect(app.lastPathComponent == "Shepherd Nightly" && app.deletingLastPathComponent().path == cli.deletingLastPathComponent().resolvingSymlinksInPath().path)
    }

    @Test func aCLIOutsideAnAppOrWithNoExecutableHasNothingToHandOverTo() throws {
        for cli in [try bundle(executable: nil), try bundle(executable: "Shepherd Nightly", present: false), try bundle(executable: "../escape")] {
            #expect(FleetWhereCLI.appExecutable(cli: cli) == nil)
            try? FileManager.default.removeItem(at: cli.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
        }
        #expect(FleetWhereCLI.appExecutable(cli: URL(fileURLWithPath: "/usr/bin/true")) == nil)
    }

    @Test func theArgumentIsTheAppsOwn() {
        #expect(FleetWhereCLI.appArgument == "--fleet-where")
    }
}
