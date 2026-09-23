import Foundation

/// A throwaway `UserDefaults` for one test, never `.standard` (the user's running app owns
/// that). Pass it wherever a store is expected; when the last reference goes, it removes its
/// persistent domain and deletes its plist.
///
/// The suite name is an absolute path inside the process's isolation root, which CFPreferences
/// treats as the plist's location, so nothing lands in ~/Library/Preferences. A named suite
/// there cannot be cleaned up reliably: cfprefsd writes a removed domain back as an empty plist
/// after the file is deleted, and leaked one per test run.
public final class ScratchDefaults: UserDefaults, @unchecked Sendable {
    public let name: String

    public init() {
        name = TestProcess.root.appendingPathComponent("defaults-\(UUID().uuidString)").path
        // `init(suiteName:)` returns nil only for the global domain or the main bundle's identifier.
        super.init(suiteName: name)!
    }

    deinit {
        // A second instance of the suite, not `self`: removing posts a change notification that
        // must not retain an object mid-deallocation.
        UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        try? FileManager.default.removeItem(atPath: name + ".plist")
    }
}
