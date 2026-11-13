import Darwin
import Foundation

/// `shepherd-cli fleet-where`: asks this Mac's Shepherd where it listens and prints one line of JSON (Add a Mac ▸ Connect over SSH
/// runs it on the other Mac). The CLI doesn't answer itself: the app's own executable, beside it in the bundle, reads the host over
/// its socket (only the app is trusted there) and prints. A CLI from before this command refuses the argument, which is how the
/// other end tells a Shepherd that is too old.
enum FleetWhereCLI {
    /// The app's executable in the bundle `cli` (`…/Contents/MacOS/shepherd-cli`) is embedded in: the name its `Info.plist` gives.
    static func appExecutable(cli: URL) -> URL? {
        let macOS = cli.resolvingSymlinksInPath().deletingLastPathComponent()
        let info = macOS.deletingLastPathComponent().appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: info),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let name = plist["CFBundleExecutable"] as? String, !name.isEmpty, !name.contains("/") else { return nil }
        let app = macOS.appendingPathComponent(name)
        return FileManager.default.isExecutableFile(atPath: app.path) ? app : nil
    }

    /// The argument the app's executable takes (`FleetWhereCommand.argument`, which this tool doesn't link).
    static let appArgument = "--fleet-where"

    static func run() -> Never {
        let cli = URL(fileURLWithPath: CommandLine.arguments[0].contains("/") ? CommandLine.arguments[0] : executablePath())
        guard let app = appExecutable(cli: cli) else { fail("this isn't inside a Shepherd app") }
        let argv = [app.path, appArgument]
        var pointers = argv.map { strdup($0) } + [nil]
        execv(app.path, &pointers)
        fail("couldn't start Shepherd: \(String(cString: strerror(errno)))")
    }

    private static func executablePath() -> String {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        return _NSGetExecutablePath(&buffer, &size) == 0 ? String(cString: buffer) : CommandLine.arguments[0]
    }
}
