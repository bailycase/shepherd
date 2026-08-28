import Foundation
import Sparkle
import SwiftUI

/// Sparkle auto-updates. The feed URL and EdDSA public key live in
/// Info.plist (SUFeedURL / SUPublicEDKey), so bare SwiftPM library builds
/// carry no update machinery — only the bundled app updates itself.
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    /// UserDefaults key for the nightly channel opt-in.
    static let nightlyKey = "updateChannelNightly"

    private let controller: SPUStandardUpdaterController

    /// Sparkle refuses to run without a feed + signing key; a dev build
    /// (bare `swift build`, missing plist keys) gets a disabled updater
    /// instead of a crash.
    let available: Bool

    @Published var nightly: Bool {
        didSet { UserDefaults.standard.set(nightly, forKey: Self.nightlyKey) }
    }

    private init() {
        let info = Bundle.main.infoDictionary
        available = info?["SUFeedURL"] != nil && info?["SUPublicEDKey"] != nil
        // A nightly build defaults to the nightly channel — otherwise it
        // reads the stable feed and reports itself newest forever. Persisted
        // so ChannelDelegate (which reads UserDefaults directly) agrees; an
        // explicit user choice is never overwritten.
        if UserDefaults.standard.object(forKey: Self.nightlyKey) == nil,
           (info?["CFBundleShortVersionString"] as? String)?.contains("-nightly.") == true {
            UserDefaults.standard.set(true, forKey: Self.nightlyKey)
        }
        nightly = UserDefaults.standard.bool(forKey: Self.nightlyKey)
        controller = SPUStandardUpdaterController(
            startingUpdater: available,
            updaterDelegate: ChannelDelegate.shared,
            userDriverDelegate: nil
        )
    }

    var canCheck: Bool { available && controller.updater.canCheckForUpdates }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
}

/// Feed selection: stable reads Info.plist's SUFeedURL; the nightly opt-in
/// swaps to the sibling appcast-nightly.xml.
private final class ChannelDelegate: NSObject, SPUUpdaterDelegate {
    static let shared = ChannelDelegate()

    func feedURLString(for updater: SPUUpdater) -> String? {
        guard UserDefaults.standard.bool(forKey: AppUpdater.nightlyKey),
              let feed = Bundle.main.infoDictionary?["SUFeedURL"] as? String else { return nil }
        return feed.replacingOccurrences(of: "appcast.xml", with: "appcast-nightly.xml")
    }

    /// generate_appcast tags nightly items with <sparkle:channel>nightly</>.
    /// Sparkle hides channel-tagged items unless the channel is explicitly
    /// allowed — without this, the nightly feed parses but every entry is
    /// filtered out and the app reports itself newest.
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UserDefaults.standard.bool(forKey: AppUpdater.nightlyKey) ? ["nightly"] : []
    }
}
