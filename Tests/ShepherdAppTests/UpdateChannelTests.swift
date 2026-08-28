import Foundation
import Testing
@testable import ShepherdApp

@Suite("Update channels")
struct UpdateChannelTests {
    /// Each channel reads its own feed; stable stays on Info.plist's URL.
    @Test func feedFilesAndAllowedChannels() {
        #expect(UpdateChannel.stable.feedFileName == nil)
        #expect(UpdateChannel.rc.feedFileName == "appcast-rc.xml")
        #expect(UpdateChannel.beta.feedFileName == "appcast-beta.xml")
        #expect(UpdateChannel.nightly.feedFileName == "appcast-nightly.xml")

        // Sparkle filters channel-tagged items unless allowed: stable allows
        // nothing (untagged feed), everything else exactly its own tag —
        // superset membership lives in the feed contents, not here.
        #expect(UpdateChannel.stable.allowedSparkleChannels.isEmpty)
        #expect(UpdateChannel.rc.allowedSparkleChannels == ["rc"])
        #expect(UpdateChannel.beta.allowedSparkleChannels == ["beta"])
        #expect(UpdateChannel.nightly.allowedSparkleChannels == ["nightly"])
    }

    /// A build defaults to the channel it was born on, so an rc install
    /// never reads the stable feed and reports itself newest forever.
    @Test func buildsDefaultToTheirBirthChannel() {
        #expect(UpdateChannel.defaultChannel(forVersion: "1.2.3") == .stable)
        #expect(UpdateChannel.defaultChannel(forVersion: "1.3.0-rc.1") == .rc)
        #expect(UpdateChannel.defaultChannel(forVersion: "1.3.0-beta.2") == .beta)
        #expect(UpdateChannel.defaultChannel(forVersion: "0.0.0-nightly.202608280344") == .nightly)
        #expect(UpdateChannel.defaultChannel(forVersion: "") == .stable)
    }
}
