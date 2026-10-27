import Foundation
import AppKit
import Testing
import Sparkle
import ShepherdProtocol
@testable import ShepherdApp
import ShepherdTestSupport

@Suite("Remote updater driver", .mainActorExclusive)
@MainActor
struct RemoteUpdateDriverTests {
    private func driver() -> RemoteUpdateDriver {
        RemoteUpdateDriver(status: HostUpdateStatus(version: "1", build: "1", channel: "stable", phase: .idle))
    }

    @Test func anUnresponsiveCheckTimesOutAndCancelsWithoutShowingUI() async throws {
        let driver = driver()
        var canceled = false
        var ended = false
        driver.onEnd = { ended = true }
        driver.begin()
        driver.showUserInitiatedUpdateCheck { canceled = true }
        driver.bound(seconds: 0)
        try await eventuallyOnMain("check times out") { driver.status.phase == .failed }
        #expect(canceled)
        #expect(ended)
        #expect(driver.status.error?.contains("attention on the host") == true)
        #expect(!driver.status.canInstall)
        #expect(!driver.restartAuthorized)
    }

    @Test func busyAtTheFinalBoundaryCancelsInsteadOfRestarting() async throws {
        let driver = driver()
        driver.begin()
        driver.status.phase = .downloading
        driver.beforeRestart = { false }
        var released = false
        driver.onEnd = { released = true }
        var choices: [SPUUserUpdateChoice] = []
        driver.showReady(toInstallAndRelaunch: { choices.append($0) })
        try await eventuallyOnMain("busy installation canceled") { driver.status.phase == .failed }
        #expect(choices == [.skip])
        #expect(!driver.restartAuthorized)
        #expect(!released)
        driver.dismissUpdateInstallation()
        #expect(!released)
        driver.updateCycleFinished()
        #expect(released)
    }

    @Test func timeoutAfterHandoffConsumesChoiceOnceAndKeepsAdmissionReserved() async throws {
        let driver = driver()
        driver.begin()
        driver.status.phase = .downloading
        driver.beforeRestart = { true }
        var released = false
        driver.onEnd = { released = true }
        var choices: [SPUUserUpdateChoice] = []
        driver.showReady(toInstallAndRelaunch: { choices.append($0) })
        try await eventuallyOnMain("restart authorized") { driver.restartAuthorized }
        driver.bound(seconds: 0)
        try await eventuallyOnMain("installer timeout reported") { driver.status.phase == .failed }
        driver.dismissUpdateInstallation()
        driver.updateCycleFinished()
        #expect(choices == [.install])
        #expect(driver.restartAuthorized)
        #expect(driver.remote)
        #expect(!released)
        #expect(driver.status.error?.contains("remains reserved") == true)
    }

    @Test func terminationRepliesRunInTheModalLoopWithoutDrainingTheMainQueue() {
        // AppKit adds modal-panel mode to the common modes. No windows or real quit required.
        CFRunLoopAddCommonMode(CFRunLoopGetMain(), .init(rawValue: RunLoop.Mode.modalPanel.rawValue as CFString))
        let keepAlive = Timer(timeInterval: 1, repeats: false) { _ in }
        RunLoop.main.add(keepAlive, forMode: .common)
        defer { keepAlive.invalidate() }
        var replied = false
        AppUpdater.performDuringTermination {
            replied = true
            CFRunLoopStop(CFRunLoopGetMain())
        }
        RunLoop.main.run(mode: .modalPanel, before: Date().addingTimeInterval(1))
        #expect(replied)
    }

    @Test func writableUserOwnedAppSupportsInstallationWithASupplementaryGroup() throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = directory.appendingPathComponent("Shepherd.app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)
        let count = getgroups(0, nil)
        #expect(count > 0)
        var groups = [gid_t](repeating: 0, count: max(0, Int(count)))
        let result = groups.withUnsafeMutableBufferPointer { getgroups(count, $0.baseAddress) }
        #expect(result == count)
        let group = try #require(groups.first { $0 != getgid() })
        try FileManager.default.setAttributes([.groupOwnerAccountID: NSNumber(value: group)], ofItemAtPath: bundle.path)

        #expect(RemoteUpdateDriver.supportsNoninteractiveInstallation(bundle))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: bundle.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundle.path) }
        #expect(!RemoteUpdateDriver.supportsNoninteractiveInstallation(bundle))
    }

    @Test func staleOffersAndMissingOffersNeverBeginInstallation() {
        let driver = driver()
        driver.begin()
        #expect(!driver.install(offerID: UUID()))
        #expect(driver.status.phase == .checking)
        driver.fail("test ended")
    }
}
