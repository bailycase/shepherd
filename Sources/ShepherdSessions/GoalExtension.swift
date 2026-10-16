import Foundation

/// Installed beside the pi home's files, outside extensions/ so it is never discovered twice.
/// Only an agent's own pi loads it with `-e` and `SHEPHERD_EXT_GOAL=1`.
public enum GoalExtension {
    static let fileName = "shepherd-goal.ts"
    public static let environmentKey = "SHEPHERD_EXT_GOAL"

    public static func path(in home: PiHome) -> String {
        home.directory.appendingPathComponent(fileName).path
    }

    @discardableResult
    static func install(in home: PiHome) throws -> URL {
        let path = home.directory.appendingPathComponent(fileName)
        try PiHome.write(Data(extensionSource.utf8), to: path, mode: 0o600)
        return path
    }
    static var extensionSource: String { EmbeddedExtensions.source("shepherd-goal.ts") }
}
