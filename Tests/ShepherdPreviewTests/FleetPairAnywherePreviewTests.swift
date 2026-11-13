import AppKit
import Foundation
import ShepherdProtocol
@testable import ShepherdSessions
@testable import ShepherdRemote
import ShepherdUI
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp

/// Add a Mac and Join a fleet for a Mac Bonjour can't find (FleetPairAnywhere), in light and dark: see `PreviewTests` for how to run.
/// The sheets are drawn from the model's own path: the link is made by `pairingLink(for:)` and read back by `readLink`, and the SSH
/// find is `findOverSSH` with a fixture in place of `ssh` that answers with what `Shepherd --fleet-where` prints (`FleetWhere.line`).
@Suite("Fleet pair anywhere previews", .serialized, .mainActorExclusive, .enabled(if: Preview.enabled && !Preview.liveModel, "set SHEPHERD_PREVIEW_DIR (without SHEPHERD_LIVE_MODEL)"))
@MainActor
struct FleetPairAnywherePreviewTests {
    /// The Mac that shows the code: its routes as its host says them (the board's three kinds).
    static let routes = [FleetReportedRoute(host: "192.168.20.14", kind: .lan), FleetReportedRoute(host: "mini.example.internal", kind: .hostname),
                         FleetReportedRoute(host: "100.86.12.4", kind: .tailscale)]
    static let miniID = UUID(uuidString: "5B1F7A52-0F3C-4C55-A5A3-61C0E3F2B9D4")!

    /// The Mac mini's own Join screen model: a snapshot with its routes, the code open for 4:50.
    static func mini() -> FleetSettingsModel {
        let model = FleetPreviewTests.model(peers: [])
        model.snapshot = FleetSnapshot(enabled: true, hostID: miniID, name: "Mac mini", build: "1.9", addresses: ["192.168.20.14"], port: 7434, routes: routes, advertising: true)
        model.join = .init(code: "482913", expiresAt: Date().addingTimeInterval(4 * 60 + 50))
        return model
    }

    static func miniAddingADevice() -> FleetSettingsModel {
        let model = mini()
        model.deviceCode = .init(code: "482913", expiresAt: Date().addingTimeInterval(4 * 60 + 50))
        return model
    }

    /// The MacBook Pro's Add a Mac, with nothing found nearby.
    static func macBook(browse: [FoundMac] = []) -> FleetSettingsModel {
        let model = FleetPreviewTests.model(peers: [])
        model.browse = { update in update(browse); return {} }
        return model
    }

    /// A link as the Mac mini would share it, pasted on the MacBook Pro.
    static func openedLink() -> (model: FleetSettingsModel, code: String) {
        let mini = Self.mini()
        let link = mini.pairingLink(for: mini.join!)!
        let model = macBook()
        model.readLink(link.url(scheme: model.linkScheme).absoluteString, asClient: false)
        return (model, link.code)
    }

    /// The SSH find, run through the model against an answer printed and read as the command does.
    static func found(typed: String = "me@mini.example.internal") async -> FleetSettingsModel.SSHState {
        let model = macBook()
        let printed = FleetWhere(hostID: miniID, name: "Mac mini", app: "Shepherd Nightly", build: "1.9", port: 7434,
                                 routes: [FleetReportedRoute(host: "192.168.20.14", kind: .lan)]).line()
        model.sshFind = { _ in FleetWhere.read(Data(printed.utf8))! }
        model.sshTarget = typed
        await model.findOverSSH()
        return model.ssh
    }

    static func sshModel(_ state: FleetSettingsModel.SSHState) -> FleetSettingsModel {
        let model = macBook()
        model.sshTarget = "me@mini.example.internal"
        model.ssh = state
        return model
    }

    /// What `ssh` and a half-copied link each say when they can't be used: the host refuses a key, and the link is cut short.
    static func failedModel() -> FleetSettingsModel {
        let model = macBook()
        model.sshTarget = "me@mini.example.internal"
        model.ssh = .failed(FleetSSHFinder.Failure.connection(FleetSSHFinder.connectionFailure("me@mini: Permission denied (publickey).", target: "me@mini.example.internal")).message)
        model.readLink("shepherd-nightly://fleet/join?v=1", asClient: false)
        return model
    }

    static func sheet(_ model: FleetSettingsModel, code: String = "") -> some View {
        FleetPairSheet(model: model, code: code) {}.padding(SH.Space.xxl).frame(width: 640, height: 900).background(Color.sh.scrim)
    }

    // MARK: Add a Mac (the board's `way`: none, link, ssh)

    @Test func addAMacWithNothingFoundNearbyOffersTheOtherWays() async throws {
        try await Preview.renderMatrix("fleet-pair-ways-none", size: CGSize(width: 640, height: 900)) {
            Self.sheet(Self.macBook())
        }
    }

    @Test func addAMacWithALinkOpened() async throws {
        try await Preview.renderMatrix("fleet-pair-ways-link", size: CGSize(width: 640, height: 900)) {
            Self.sheet(Self.openedLink().model, code: Self.openedLink().code)
        }
    }

    @Test func addAMacFoundOverSSHAwaitingItsCode() async throws {
        let state = await Self.found()
        try await Preview.renderMatrix("fleet-pair-ways-ssh", size: CGSize(width: 640, height: 900)) {
            Self.sheet(Self.sshModel(state), code: "482")
        }
    }

    @Test func addAMacWhenSSHFailsAndWhenALinkCannotBeUsed() async throws {
        try await Preview.render("fleet-pair-ways-failed", size: CGSize(width: 640, height: 900)) {
            Self.sheet(Self.failedModel())
        }
    }

    // MARK: Join a fleet

    @Test func joinAFleetOffersALinkAndTheRoutes() async throws {
        try await Preview.renderMatrix("fleet-join-link", size: CGSize(width: 640, height: 640)) {
            FleetJoinView(model: Self.mini()) {}.padding(SH.Space.xxl).frame(width: 640, height: 640).background(Color.sh.scrim)
        }
    }

    @Test func addADeviceOffersALinkToo() async throws {
        try await Preview.render("fleet-add-device-link", size: CGSize(width: 640, height: 820)) {
            FleetDeviceSheet(model: Self.miniAddingADevice()) {}.padding(SH.Space.xxl).frame(width: 640, height: 820).background(Color.sh.scrim)
        }
    }
}
