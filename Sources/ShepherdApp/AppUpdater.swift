import Foundation
import AppKit
import Sparkle
import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdSessions

/// The update channel an app rides; each maps to a feed on gh-pages. Feed names are a contract
/// with the release workflow (`scripts/release.py`).
///
/// Shepherd offers Stable and Beta. The beta feed also carries stable builds, so a beta rider is
/// still offered a newer stable hotfix: the newest build in the chosen feed wins. Shepherd
/// Nightly is a separate app (its own bundle, data and feed) whose only channel is nightly.
/// Release candidates are retired.
enum UpdateChannel: String, CaseIterable, Identifiable {
    case stable, beta, nightly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .stable: "Stable"
        case .beta: "Beta"
        case .nightly: "Nightly"
        }
    }

    /// The channels an app offers, in picker order. Shepherd never rides nightly: nightly
    /// builds are Shepherd Nightly, a different bundle Sparkle must never install over it.
    static func choices(for edition: ShepherdEdition) -> [UpdateChannel] {
        switch edition {
        case .main: [.stable, .beta]
        case .nightly: [.nightly]
        }
    }

    /// The feed file on gh-pages, beside Info.plist's SUFeedURL.
    var feedFileName: String {
        switch self {
        case .stable: "appcast.xml"
        case .beta: "appcast-beta.xml"
        case .nightly: "appcast-shepherd-nightly.xml"
        }
    }

    /// This channel's feed in the directory of `infoFeedURL` (Info.plist's SUFeedURL).
    func feedURL(besides infoFeedURL: String) -> String? {
        guard let base = URL(string: infoFeedURL), base.scheme != nil else { return nil }
        return base.deletingLastPathComponent().appendingPathComponent(feedFileName).absoluteString
    }

    /// generate_appcast tags every beta-feed item with "beta", and Sparkle hides tagged items
    /// unless their channel is allowed. The stable and Shepherd Nightly feeds are untagged.
    var allowedSparkleChannels: Set<String> {
        self == .beta ? ["beta"] : []
    }

    /// A build defaults to the channel it was born on, so a beta install never reads the stable
    /// feed and reports itself newest forever. Marketing versions: 1.2.3, 1.3.0-beta.2, and the
    /// retired 1.3.0-rc.1 and 0.0.0-nightly.202608280344, which Shepherd now rides as Beta.
    static func defaultChannel(forVersion version: String, edition: ShepherdEdition) -> UpdateChannel {
        if edition == .nightly { return .nightly }
        for prerelease in ["-beta.", "-rc.", "-nightly."] where version.contains(prerelease) {
            return .beta
        }
        return .stable
    }
}

/// The persisted channel choice, and its migration off the retired channels.
///
/// Shipped Shepherd builds stored `stable`, `rc`, `beta` or `nightly` (or, before the channel
/// picker, a nightly bool). At launch Shepherd moves `rc` to Beta and `nightly` to Beta, and
/// flags the nightly move so the app can say, once, where nightly builds went. Shepherd Nightly
/// rides nightly and stores nothing. Every read resolves through the same rules, so nothing
/// ever rides a channel its app doesn't offer.
struct UpdateChannelStore {
    /// An `UpdateChannel` rawValue. Written at every launch, so the delegate reads the same.
    static let channelKey = "updateChannel"
    /// Pre-channel-picker key: nightly was a bool opt-in.
    static let legacyNightlyKey = "updateChannelNightly"
    /// Set by the launch that moves an install off the nightly channel; cleared once the
    /// notice is dismissed, so it is armed exactly once.
    static let nightlyMovedNoticeKey = "updateChannelNightlyMovedNotice"

    let defaults: UserDefaults
    let edition: ShepherdEdition

    struct Resolution: Equatable {
        let channel: UpdateChannel
        /// This launch moved the install off the retired nightly channel.
        let movedFromNightly: Bool
    }

    /// Explicit choice > legacy nightly bool > birth channel, with the retired channels mapped
    /// onto what this edition offers. Never yields a channel outside `choices(for:)`.
    static func resolve(edition: ShepherdEdition, stored: String?, legacyNightly: Bool?, version: String) -> Resolution {
        guard edition == .main else { return Resolution(channel: .nightly, movedFromNightly: false) }
        switch stored {
        case "stable": return Resolution(channel: .stable, movedFromNightly: false)
        case "beta", "rc": return Resolution(channel: .beta, movedFromNightly: false)
        case "nightly": return Resolution(channel: .beta, movedFromNightly: true)
        default: break
        }
        if let legacyNightly {
            return Resolution(channel: legacyNightly ? .beta : .stable, movedFromNightly: legacyNightly)
        }
        return Resolution(channel: UpdateChannel.defaultChannel(forVersion: version, edition: edition),
                          movedFromNightly: false)
    }

    /// Resolves the channel for this launch and persists it (an explicit choice is kept as is);
    /// a move off nightly arms the notice.
    @discardableResult
    func resolveAtLaunch(version: String) -> UpdateChannel {
        let resolution = storedResolution(version: version)
        guard edition == .main else { return resolution.channel }
        defaults.set(resolution.channel.rawValue, forKey: Self.channelKey)
        if resolution.movedFromNightly {
            defaults.set(true, forKey: Self.nightlyMovedNoticeKey)
        }
        return resolution.channel
    }

    /// The channel this launch rides, resolved without writing anything: the migration is left
    /// to the installed app that owns these preferences.
    func resolveWithoutMigrating(version: String) -> UpdateChannel {
        storedResolution(version: version).channel
    }

    private func storedResolution(version: String) -> Resolution {
        Self.resolve(
            edition: edition,
            stored: defaults.string(forKey: Self.channelKey),
            legacyNightly: defaults.object(forKey: Self.legacyNightlyKey) != nil
                ? defaults.bool(forKey: Self.legacyNightlyKey) : nil,
            version: version
        )
    }

    /// Stores `channel` if this edition offers it. Returns whether it did.
    @discardableResult
    func select(_ channel: UpdateChannel) -> Bool {
        guard edition == .main, UpdateChannel.choices(for: edition).contains(channel) else { return false }
        defaults.set(channel.rawValue, forKey: Self.channelKey)
        return true
    }

    var nightlyMovedNoticePending: Bool {
        edition == .main && defaults.bool(forKey: Self.nightlyMovedNoticeKey)
    }

    func dismissNightlyMovedNotice() {
        defaults.set(false, forKey: Self.nightlyMovedNoticeKey)
    }
}

/// Sparkle auto-updates. The feed URL and EdDSA public key live in
/// Info.plist (SUFeedURL / SUPublicEDKey), so bare SwiftPM library builds
/// carry no update machinery — only the bundled app updates itself, and only
/// it resolves or migrates a stored channel.
@MainActor
@Observable
final class AppUpdater {
    static let shared = AppUpdater()

    /// Where Shepherd Nightly is downloaded: its releases are prereleases with dated tags, so
    /// the list, not a fixed release, is the stable link.
    static let nightlyDownloadURL = URL(string: "https://github.com/bailycase/shepherd/releases?q=nightly&expanded=true")!

    private let updater: SPUUpdater
    private let remoteDriver: RemoteUpdateDriver
    private weak var server: SessionServer?
    private var handlingRemoteRequest = false
    private var started = false
    private var terminationCheckID: UUID?
    private var terminationDeadline: Timer?
    private let store: UpdateChannelStore

    /// Sparkle refuses to run without a feed + signing key; a dev build
    /// (bare `swift build`, missing plist keys) gets a disabled updater
    /// instead of a crash. Debug builds (the Dev scheme) never update: every release would look
    /// newer than build 1, and none can install over the Dev bundle id.
    let available: Bool
    let edition: ShepherdEdition

    private(set) var channel: UpdateChannel
    /// Shepherd moved this install off the retired nightly channel and hasn't said so yet.
    private(set) var nightlyMovedNoticePending: Bool

    private init() {
        let info = Bundle.main.infoDictionary
        #if DEBUG
        available = false
        #else
        available = [ShepherdEdition.mainBundleIdentifier, ShepherdEdition.nightlyBundleIdentifier].contains(Bundle.main.bundleIdentifier ?? "")
            && (info?["SUFeedURL"] as? String).flatMap(URL.init(string:))?.scheme == "https"
            && !(info?["SUPublicEDKey"] as? String ?? "").isEmpty
        #endif
        edition = .current
        store = UpdateChannelStore(defaults: .standard, edition: edition)
        let version = info?["CFBundleShortVersionString"] as? String ?? ""
        if available {
            channel = store.resolveAtLaunch(version: version)
            nightlyMovedNoticePending = store.nightlyMovedNoticePending
        } else {
            channel = UpdateChannel.choices(for: edition)[0]
            nightlyMovedNoticePending = false
        }
        remoteDriver = RemoteUpdateDriver(status: HostUpdateStatus(
            version: version, build: info?["CFBundleVersion"] as? String ?? "",
            channel: store.resolveWithoutMigrating(version: version).rawValue, phase: available ? .idle : .unsupported))
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main,
                             userDriver: remoteDriver, delegate: ChannelDelegate.shared)
        if available {
            do { try updater.start(); started = true }
            catch { remoteDriver.status.phase = .unsupported; remoteDriver.status.error = error.localizedDescription }
        }
    }

    /// Switches channel; a channel this app doesn't offer is ignored.
    func select(_ channel: UpdateChannel) {
        guard !remoteDriver.remote, channel != self.channel, store.select(channel) else { return }
        self.channel = channel
    }

    func dismissNightlyMovedNotice() {
        store.dismissNightlyMovedNotice()
        nightlyMovedNoticePending = false
    }

    func downloadShepherdNightly() {
        NSWorkspace.shared.open(Self.nightlyDownloadURL)
        dismissNightlyMovedNotice()
    }

    var canCheck: Bool { available && started && !remoteDriver.installationHandedOff && updater.canCheckForUpdates }

    func checkForUpdates() {
        guard canCheck else { return }
        updater.checkForUpdates()
    }

    /// Installed once by the app lifecycle, never by a view or a headless server.
    func connectRemoteUpdates(to server: SessionServer) {
        self.server = server
        guard available, started else { return }
        remoteDriver.onEnd = { [weak server] in server?.releaseHostUpdate() }
        ChannelDelegate.shared.didDownload = { [weak remoteDriver] in remoteDriver?.preflightBeforeExtraction() }
        ChannelDelegate.shared.didFinish = { [weak remoteDriver] in remoteDriver?.updateCycleFinished() }
        remoteDriver.beforeRestart = { [weak server] in
            guard let server else { return false }
            return await server.hostUpdateCanRestart()
        }
        server.onRemoteHostUpdate = { [weak self] request, authorized, completion in
            guard let self else { return }
            Task { completion(await self.remoteUpdate(request, authorized: authorized)) }
        }
    }

    private func remoteUpdate(_ request: RemoteHostUpdateRequest, authorized: @escaping () async -> Bool) async -> HostUpdateStatus {
        guard available, started, await authorized(), let server else { return remoteDriver.status }
        if request == .status {
            var status = remoteDriver.status
            let idle = await server.hostUpdateIsIdle()
            status.canInstall = status.canInstall && idle
            return status
        }
        guard !handlingRemoteRequest else {
            var status = remoteDriver.status
            status.error = "An update request is already in progress."
            return status
        }
        handlingRemoteRequest = true
        defer { handlingRemoteRequest = false }
        switch request {
        case .status: break
        case .check:
            guard canCheck else { return remoteDriver.status }
            remoteDriver.status.channel = channel.rawValue
            remoteDriver.begin()
            updater.checkForUpdates()
        case .install(let offerID, let consent):
            guard consent, remoteDriver.status.phase == .available,
                  remoteDriver.status.offerID == offerID else {
                var status = remoteDriver.status
                status.error = "Confirm the current update before installing and restarting."
                return status
            }
            guard await server.reserveHostUpdate() else {
                var status = remoteDriver.status
                status.canInstall = false
                status.error = "Host is busy. Stop active agents and tasks, pause Projects, and close terminals before updating."
                return status
            }
            guard await authorized() else {
                server.releaseHostUpdate()
                return remoteDriver.status
            }
            if !remoteDriver.install(offerID: offerID) { server.releaseHostUpdate() }
        }
        return remoteDriver.status
    }

    /// Remote updates never open QuitConfirmation. A busy host cancels termination instead.
    var remoteTerminationReply: NSApplication.TerminateReply? {
        guard remoteDriver.remote, remoteDriver.restartAuthorized else { return nil }
        guard let server else { return .terminateCancel }
        guard terminationCheckID == nil else { return .terminateCancel }
        let checkID = UUID()
        terminationCheckID = checkID
        let finish: @MainActor @Sendable (Bool) -> Void = { [weak self] safe in
            guard let self, self.terminationCheckID == checkID else { return }
            self.terminationCheckID = nil
            self.terminationDeadline?.invalidate()
            if !safe {
                self.remoteDriver.fail("Restart was refused or timed out. Installation outcome is unknown.")
            }
            NSApp.reply(toApplicationShouldTerminate: safe)
        }
        // Neither the server reply nor the timeout depends on a main-queue Task running
        // inside AppKit's termination modal loop. Late replies are fenced by checkID.
        let timer = Timer(timeInterval: 5, repeats: false) { _ in
            MainActor.assumeIsolated { finish(false) }
        }
        terminationDeadline = timer
        RunLoop.main.add(timer, forMode: .common)
        server.checkHostUpdateTermination { safe in
            Self.performDuringTermination { finish(safe) }
        }
        return .terminateLater
    }

    nonisolated static func performDuringTermination(_ body: @escaping @MainActor @Sendable () -> Void) {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), RunLoop.Mode.common.rawValue as CFString) {
            MainActor.assumeIsolated(body)
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    /// Stored by Sparkle, so its reads and writes are reported to observers by hand.
    var automaticallyChecks: Bool {
        get {
            access(keyPath: \.automaticallyChecks)
            return updater.automaticallyChecksForUpdates
        }
        set {
            withMutation(keyPath: \.automaticallyChecks) {
                updater.automaticallyChecksForUpdates = newValue
            }
        }
    }
}

/// Feed selection: every channel reads its own appcast beside Info.plist's SUFeedURL, so a
/// Shepherd Nightly build reads Shepherd Nightly's feed even if its SUFeedURL were wrong.
private final class ChannelDelegate: NSObject, SPUUpdaterDelegate {
    static let shared = ChannelDelegate()
    var didDownload: (@MainActor () -> Void)?
    var didFinish: (@MainActor () -> Void)?

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        MainActor.assumeIsolated { didFinish?() }
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        MainActor.assumeIsolated { didDownload?() }
    }

    /// What the app resolved at launch, read again without writing: after the launch migration
    /// that is the stored channel.
    private var channel: UpdateChannel {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        return UpdateChannelStore(defaults: .standard, edition: .current).resolveWithoutMigrating(version: version)
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        guard let feed = Bundle.main.infoDictionary?["SUFeedURL"] as? String else { return nil }
        return channel.feedURL(besides: feed)
    }

    /// Sparkle hides channel-tagged items unless the channel is explicitly
    /// allowed — without this, the beta feed parses but every entry is
    /// filtered out and the app reports itself newest.
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        channel.allowedSparkleChannels
    }
}
