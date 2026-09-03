import Foundation
import Sparkle
import SwiftUI

/// The update channel a user rides. One channel at a time; each maps to a
/// feed on gh-pages. Feeds are supersets down the stability ladder (the rc
/// feed carries stable + rc items, beta carries stable + rc + beta), so a
/// pre-release rider is still offered a newer stable hotfix — the newest
/// build in the chosen feed wins. Nightly stays its own isolated timeline.
enum UpdateChannel: String, CaseIterable, Identifiable {
    case stable, rc, beta, nightly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .stable: return "Stable"
        case .rc: return "Release Candidate"
        case .beta: return "Beta"
        case .nightly: return "Nightly"
        }
    }

    var explanation: String {
        switch self {
        case .stable: return "tagged releases only"
        case .rc: return "release candidates, plus stable"
        case .beta: return "beta builds, plus rc and stable"
        case .nightly: return "every push, least tested"
        }
    }

    /// The feed file on gh-pages; nil = Info.plist's SUFeedURL (stable).
    var feedFileName: String? {
        self == .stable ? nil : "appcast-\(rawValue).xml"
    }

    /// generate_appcast tags every non-stable feed's items with the channel
    /// name; Sparkle hides tagged items unless explicitly allowed.
    var allowedSparkleChannels: Set<String> {
        self == .stable ? [] : [rawValue]
    }

    /// A build defaults to the channel it was born on — otherwise an rc/beta/
    /// nightly install reads the stable feed and reports itself newest
    /// forever. (Marketing versions: 1.2.3, 1.3.0-rc.1, 1.3.0-beta.2,
    /// 0.0.0-nightly.202608280344.)
    static func defaultChannel(forVersion version: String) -> UpdateChannel {
        if version.contains("-nightly.") { return .nightly }
        if version.contains("-rc.") { return .rc }
        if version.contains("-beta.") { return .beta }
        return .stable
    }
}

/// Sparkle auto-updates. The feed URL and EdDSA public key live in
/// Info.plist (SUFeedURL / SUPublicEDKey), so bare SwiftPM library builds
/// carry no update machinery — only the bundled app updates itself.
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    /// UserDefaults key for the selected channel (an UpdateChannel rawValue).
    static let channelKey = "updateChannel"
    /// Pre-channel-picker key: nightly was a bool opt-in. Migrated once.
    static let legacyNightlyKey = "updateChannelNightly"

    private let controller: SPUStandardUpdaterController

    /// Sparkle refuses to run without a feed + signing key; a dev build
    /// (bare `swift build`, missing plist keys) gets a disabled updater
    /// instead of a crash.
    let available: Bool

    @Published var channel: UpdateChannel {
        didSet { UserDefaults.standard.set(channel.rawValue, forKey: Self.channelKey) }
    }

    private init() {
        let info = Bundle.main.infoDictionary
        available = info?["SUFeedURL"] != nil && info?["SUPublicEDKey"] != nil
        let defaults = UserDefaults.standard
        // Resolution order: explicit choice > legacy nightly bool > the
        // channel this build was born on. Persisted immediately so
        // ChannelDelegate (which reads UserDefaults directly) always agrees;
        // an explicit user choice is never overwritten.
        let resolved: UpdateChannel
        if let raw = defaults.string(forKey: Self.channelKey),
           let stored = UpdateChannel(rawValue: raw) {
            resolved = stored
        } else if defaults.object(forKey: Self.legacyNightlyKey) != nil {
            resolved = defaults.bool(forKey: Self.legacyNightlyKey) ? .nightly : .stable
        } else {
            resolved = UpdateChannel.defaultChannel(
                forVersion: info?["CFBundleShortVersionString"] as? String ?? ""
            )
        }
        defaults.set(resolved.rawValue, forKey: Self.channelKey)
        channel = resolved
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
        set {
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }
}

/// Feed selection: stable reads Info.plist's SUFeedURL; every other channel
/// swaps to its sibling appcast-<channel>.xml beside it.
private final class ChannelDelegate: NSObject, SPUUpdaterDelegate {
    static let shared = ChannelDelegate()

    private var channel: UpdateChannel {
        UserDefaults.standard.string(forKey: AppUpdater.channelKey)
            .flatMap(UpdateChannel.init(rawValue:)) ?? .stable
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        guard let file = channel.feedFileName,
              let feed = Bundle.main.infoDictionary?["SUFeedURL"] as? String else { return nil }
        return feed.replacingOccurrences(of: "appcast.xml", with: file)
    }

    /// Sparkle hides channel-tagged items unless the channel is explicitly
    /// allowed — without this, a pre-release feed parses but every entry is
    /// filtered out and the app reports itself newest.
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        channel.allowedSparkleChannels
    }
}
