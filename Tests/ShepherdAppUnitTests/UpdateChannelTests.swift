import Foundation
import ShepherdProtocol
import Testing
@testable import ShepherdApp

/// Feed names are a contract between the release workflow (`scripts/release.py`) and the apps.
/// Shepherd rides Stable or Beta; Shepherd Nightly is its own app on its own feed.
@Suite("Update channels")
struct UpdateChannelTests {
    static let pages = "https://bailycase.github.io/shepherd/"

    @Test(arguments: [
        (UpdateChannel.stable, "appcast.xml", Set<String>()),
        (.beta, "appcast-beta.xml", ["beta"]),
        (.nightly, "appcast-shepherd-nightly.xml", []),
    ] as [(UpdateChannel, String, Set<String>)])
    func eachChannelReadsItsOwnFeedAndTag(channel: UpdateChannel, feed: String, tags: Set<String>) {
        #expect(channel.feedFileName == feed)
        #expect(channel.allowedSparkleChannels == tags)
    }

    /// The URL Sparkle asks for sits beside the app's own SUFeedURL, whichever one the build carries.
    @Test(arguments: [
        (UpdateChannel.stable, "appcast.xml", "appcast.xml"),
        (.beta, "appcast.xml", "appcast-beta.xml"),
        (.nightly, "appcast-shepherd-nightly.xml", "appcast-shepherd-nightly.xml"),
        // A nightly build whose plist named the main feed still reads its own.
        (.nightly, "appcast.xml", "appcast-shepherd-nightly.xml"),
    ])
    func eachChannelsFeedURLSitsBesideTheInfoPlistFeed(channel: UpdateChannel, infoFeed: String, expected: String) {
        #expect(channel.feedURL(besides: Self.pages + infoFeed) == Self.pages + expected)
    }

    @Test func aFeedURLWithoutASchemeHasNoSibling() {
        #expect(UpdateChannel.beta.feedURL(besides: "appcast.xml") == nil)
    }

    @Test func shepherdOffersStableAndBetaAndShepherdNightlyOnlyNightly() {
        #expect(UpdateChannel.choices(for: .main) == [.stable, .beta])
        #expect(UpdateChannel.choices(for: .nightly) == [.nightly])
    }

    @Test func releaseCandidatesAreNoLongerAChannel() {
        #expect(UpdateChannel(rawValue: "rc") == nil)
        #expect(UpdateChannel.allCases == [.stable, .beta, .nightly])
    }

    /// A build defaults to the channel it was born on, so a beta install never reads the stable
    /// feed and reports itself newest forever. Shepherd reads the retired rc and nightly
    /// versions as Beta; Shepherd Nightly is always nightly.
    @Test(arguments: [
        ("1.2.3", ShepherdEdition.main, UpdateChannel.stable),
        ("1.3.0-beta.2", .main, .beta),
        ("1.3.0-rc.1", .main, .beta),
        ("0.0.0-nightly.202608280344", .main, .beta),
        ("", .main, .stable),
        ("0.0.0-nightly.202609232100", .nightly, .nightly),
        ("1.2.3", .nightly, .nightly),
    ])
    func buildsDefaultToTheirBirthChannel(version: String, edition: ShepherdEdition, channel: UpdateChannel) {
        #expect(UpdateChannel.defaultChannel(forVersion: version, edition: edition) == channel)
    }
}

/// What a launch does with the channel an older build stored. Every case runs against a scratch
/// defaults suite, never the app's own.
@Suite("Update channel migration")
struct UpdateChannelMigrationTests {
    typealias Store = UpdateChannelStore

    /// stored channel, legacy nightly bool, version → channel, moved off nightly
    @Test(arguments: [
        ("stable", nil, "1.2.3", UpdateChannel.stable, false),
        ("beta", nil, "1.2.3", .beta, false),
        ("rc", nil, "1.3.0-rc.1", .beta, false),
        ("nightly", nil, "0.0.0-nightly.202609211956", .beta, true),
        ("nightly", nil, "1.4.0-beta.1", .beta, true),
        (nil, true, "1.2.3", .beta, true),
        (nil, false, "1.2.3", .stable, false),
        (nil, nil, "1.3.0-beta.1", .beta, false),
        (nil, nil, "1.2.3", .stable, false),
        ("octopus", nil, "1.2.3", .stable, false),
        // An explicit choice beats the legacy bool.
        ("stable", true, "1.2.3", .stable, false),
    ] as [(String?, Bool?, String, UpdateChannel, Bool)])
    func shepherdMapsEveryStoredChannelOntoStableOrBeta(stored: String?, legacy: Bool?, version: String,
                                                        channel: UpdateChannel, moved: Bool) {
        let resolution = Store.resolve(edition: .main, stored: stored, legacyNightly: legacy, version: version)
        #expect(resolution == Store.Resolution(channel: channel, movedFromNightly: moved))
        #expect(UpdateChannel.choices(for: .main).contains(resolution.channel))
    }

    @Test(arguments: [nil, "stable", "beta", "rc", "nightly"])
    func shepherdNightlyAlwaysRidesNightly(stored: String?) {
        let resolution = Store.resolve(edition: .nightly, stored: stored, legacyNightly: true, version: "1.2.3")
        #expect(resolution == Store.Resolution(channel: .nightly, movedFromNightly: false))
    }

    @Test func anRcInstallMovesToBetaWithoutANotice() {
        let defaults = Fixture.defaults()
        defaults.set("rc", forKey: Store.channelKey)
        let store = Store(defaults: defaults, edition: .main)

        #expect(store.resolveAtLaunch(version: "0.1.0-rc.1") == .beta)
        #expect(defaults.string(forKey: Store.channelKey) == "beta")
        #expect(!store.nightlyMovedNoticePending)
    }

    /// The everyday copy that rode nightly: it moves to Beta, and the notice is armed once and
    /// stays until dismissed; later launches never arm it again.
    @Test func aNightlyInstallMovesToBetaAndIsToldOnce() {
        let defaults = Fixture.defaults()
        defaults.set("nightly", forKey: Store.channelKey)
        let store = Store(defaults: defaults, edition: .main)

        #expect(store.resolveAtLaunch(version: "0.2.0-beta.1") == .beta)
        #expect(defaults.string(forKey: Store.channelKey) == "beta")
        #expect(store.nightlyMovedNoticePending)

        #expect(store.resolveAtLaunch(version: "0.2.0-beta.1") == .beta)
        #expect(store.nightlyMovedNoticePending, "an undismissed notice survives a relaunch")

        store.dismissNightlyMovedNotice()
        #expect(!store.nightlyMovedNoticePending)
        #expect(store.resolveAtLaunch(version: "0.2.0-beta.2") == .beta)
        #expect(!store.nightlyMovedNoticePending, "dismissed stays dismissed")
    }

    @Test func aPrePickerNightlyInstallIsToldToo() {
        let defaults = Fixture.defaults()
        defaults.set(true, forKey: Store.legacyNightlyKey)
        let store = Store(defaults: defaults, edition: .main)

        #expect(store.resolveAtLaunch(version: "0.2.0") == .beta)
        #expect(store.nightlyMovedNoticePending)
    }

    @Test func anExplicitChoiceIsKept() {
        let defaults = Fixture.defaults()
        defaults.set("stable", forKey: Store.channelKey)
        let store = Store(defaults: defaults, edition: .main)

        // A stable rider who updated to a beta build stays on Stable.
        #expect(store.resolveAtLaunch(version: "0.2.0-beta.1") == .stable)
        #expect(defaults.string(forKey: Store.channelKey) == "stable")
    }

    @Test func aFreshInstallStoresItsBirthChannel() {
        let defaults = Fixture.defaults()
        #expect(Store(defaults: defaults, edition: .main).resolveAtLaunch(version: "0.2.0-beta.1") == .beta)
        #expect(defaults.string(forKey: Store.channelKey) == "beta")
    }

    @Test func shepherdCanNeverSelectNightlyOrRc() {
        let defaults = Fixture.defaults()
        let store = Store(defaults: defaults, edition: .main)
        store.resolveAtLaunch(version: "1.2.3")

        #expect(!store.select(.nightly))
        #expect(defaults.string(forKey: Store.channelKey) == "stable")
        #expect(store.select(.beta))
        #expect(store.resolveWithoutMigrating(version: "1.2.3") == .beta)

        // Whatever an older build or a hand edit left behind, Sparkle reads Stable or Beta.
        for (raw, channel) in [("nightly", UpdateChannel.beta), ("rc", .beta), ("octopus", .stable)] {
            defaults.set(raw, forKey: Store.channelKey)
            #expect(store.resolveWithoutMigrating(version: "1.2.3") == channel, "stored \(raw)")
        }
    }

    /// The Dev build shares the everyday app's preferences domain: it rides what the migration
    /// would pick but leaves the stored channel and the notice to the installed app.
    @Test func aReadWithoutMigratingWritesNothing() {
        let defaults = Fixture.defaults()
        defaults.set("nightly", forKey: Store.channelKey)
        let store = Store(defaults: defaults, edition: .main)

        #expect(store.resolveWithoutMigrating(version: "0.1.0") == .beta)
        #expect(defaults.string(forKey: Store.channelKey) == "nightly")
        #expect(!store.nightlyMovedNoticePending)
    }

    @Test func shepherdNightlyReadsNightlyAndStoresNothing() {
        let defaults = Fixture.defaults()
        defaults.set("stable", forKey: Store.channelKey)
        let store = Store(defaults: defaults, edition: .nightly)

        #expect(store.resolveAtLaunch(version: "0.0.0-nightly.202609232100") == .nightly)
        #expect(store.resolveWithoutMigrating(version: "0.0.0-nightly.202609232100") == .nightly)
        #expect(!store.select(.stable) && !store.select(.beta))
        #expect(defaults.string(forKey: Store.channelKey) == "stable", "untouched")
        #expect(!store.nightlyMovedNoticePending)
    }
}
