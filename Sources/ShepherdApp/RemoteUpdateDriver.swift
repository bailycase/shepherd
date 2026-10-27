import AppKit
import Sparkle
import ShepherdProtocol
import ShepherdSessions

/// A single updater, with Sparkle's ordinary UI for local checks and no UI for remote checks.
/// No installation starts until an explicit, offer-fenced authorization arrives.
@MainActor
final class RemoteUpdateDriver: SPUStandardUserDriver {
    var remote = false
    var status: HostUpdateStatus
    var onEnd: (() -> Void)?
    var beforeRestart: (() async -> Bool)?
    private var choice: ((SPUUserUpdateChoice) -> Void)?
    private var cancel: (() -> Void)?
    private var deadline: Timer?
    private var installationStarted = false
    private(set) var installationHandedOff = false
    private(set) var restartAuthorized = false

    init(status: HostUpdateStatus) {
        self.status = status
        super.init(hostBundle: .main, delegate: nil)
    }

    func begin() {
        remote = true
        status.phase = .checking
        status.error = nil
        status.offerID = nil
        status.canInstall = false
        bound(seconds: 60)
    }

    func install(offerID: UUID) -> Bool {
        guard remote, status.phase == .available, status.offerID == offerID, let choice else { return false }
        guard Self.supportsNoninteractiveInstallation(Bundle.main.bundleURL),
              FileManager.default.isWritableFile(atPath: Bundle.main.bundleURL.deletingLastPathComponent().path) else {
            fail("This update requires local installation.")
            return false
        }
        self.choice = nil
        status.canInstall = false
        status.phase = .downloading
        installationStarted = true
        bound(seconds: 600)
        choice(.install)
        return true
    }

    func fail(_ message: String) {
        status.phase = .failed
        status.error = message
        status.canInstall = false
        status.offerID = nil
        deadline?.invalidate()
        // Sparkle's choice callbacks are single-use, not cancellation handles. Once handed
        // off, no public API proves cancellation: keep admission fenced until process exit.
        guard !installationHandedOff else {
            status.error = message + " The installer has already started; this host remains reserved and may require attention locally."
            return
        }
        restartAuthorized = false
        let choice = self.choice, cancel = self.cancel
        self.choice = nil; self.cancel = nil
        choice?(.skip)
        cancel?()
        if !installationStarted { onEnd?() }
    }

    /// Sparkle calls this after abort/cleanup completes, not merely after dismissing its UI.
    func updateCycleFinished() {
        guard installationStarted, !installationHandedOff else { return }
        installationStarted = false
        remote = false
        deadline?.invalidate()
        onEnd?()
    }

    func bound(seconds: Double) {
        deadline?.invalidate()
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.fail("Remote update timed out and may require attention on the host. Reconnect and check status before trying again.")
            }
        }
        deadline = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    override func show(_ request: SPUUpdatePermissionRequest,
                                             reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        guard remote else { super.show(request, reply: reply); return }
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
        fail("Update permission must be configured locally.")
    }

    override func showUpdateInFocus() {
        if !remote { super.showUpdateInFocus() }
    }

    override func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        guard remote else { super.showUserInitiatedUpdateCheck(cancellation: cancellation); return }
        cancel = cancellation
    }

    override func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                                  reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard remote else { super.showUpdateFound(with: appcastItem, state: state, reply: reply); return }
        guard status.phase == .checking, state.stage == .notDownloaded,
              !appcastItem.isInformationOnlyUpdate, appcastItem.installationType == "application",
              Self.supportsNoninteractiveInstallation(Bundle.main.bundleURL),
              FileManager.default.isWritableFile(atPath: Bundle.main.bundleURL.deletingLastPathComponent().path) else {
            reply(.skip)
            fail("This update requires local installation.")
            return
        }
        cancel = nil
        choice = reply
        status.phase = .available
        status.offeredVersion = appcastItem.displayVersionString
        status.offerID = UUID()
        status.canInstall = true
        bound(seconds: 300)
    }

    override func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        guard remote else { super.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement); return }
        status.phase = .upToDate
        deadline?.invalidate()
        acknowledgement()
        onEnd?()
    }

    override func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        guard remote else { super.showUpdaterError(error, acknowledgement: acknowledgement); return }
        fail(error.localizedDescription)
        acknowledgement()
    }

    override func showDownloadInitiated(cancellation: @escaping () -> Void) {
        guard remote else { super.showDownloadInitiated(cancellation: cancellation); return }
        cancel = cancellation
        if status.phase != .downloading { cancellation() }
    }

    /// Sparkle's last public notification before extraction/installer launch. Permission changes
    /// outside the app can still race this check; Sparkle may then require host-local approval.
    func preflightBeforeExtraction() {
        guard remote, status.phase == .downloading else { return }
        if !Self.supportsNoninteractiveInstallation(Bundle.main.bundleURL)
            || !FileManager.default.isWritableFile(atPath: Bundle.main.bundleURL.deletingLastPathComponent().path) {
            fail("Installation permissions changed. This update requires attention on the host.")
        }
    }

    override func showDownloadDidStartExtractingUpdate() {
        guard remote else { super.showDownloadDidStartExtractingUpdate(); return }
        cancel = nil
    }

    override func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard remote else { super.showReady(toInstallAndRelaunch: reply); return }
        installationStarted = true
        choice = reply
        Task {
            guard status.phase == .downloading, await beforeRestart?() == true else {
                fail("Host became busy. Installation canceled; stop active work and check again.")
                return
            }
            guard status.phase == .downloading else { return }
            guard let reply = choice else { return }
            choice = nil
            installationHandedOff = true
            restartAuthorized = true
            status.phase = .installing
            reply(.install)
        }
    }

    override func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                                      retryTerminatingApplication: @escaping () -> Void) {
        guard remote else {
            super.showInstallingUpdate(withApplicationTerminated: applicationTerminated, retryTerminatingApplication: retryTerminatingApplication)
            return
        }
        // Never repeatedly ask the app to terminate or surface a local confirmation.
    }

    override func dismissUpdateInstallation() {
        guard remote else { super.dismissUpdateInstallation(); return }
        choice = nil; cancel = nil
        guard !installationHandedOff else { return }
        deadline?.invalidate()
        remote = false
        if !installationStarted { onEnd?() }
    }

    static func supportsNoninteractiveInstallation(_ bundle: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: bundle.path),
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { return false }
        // Sparkle can preserve the owner without preserving the group; a primary-group
        // mismatch does not mean installation needs authorization.
        return FileManager.default.isWritableFile(atPath: bundle.path)
    }

    override func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        guard remote else { super.showUpdateInstalledAndRelaunched(relaunched, acknowledgement: acknowledgement); return }
        acknowledgement()
        // A successful handoff may still leave this process alive. Never reopen admission.
        if !installationHandedOff { updateCycleFinished() }
    }

    override func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        if !remote { super.showUpdateReleaseNotes(with: downloadData) }
    }
    override func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        if !remote { super.showUpdateReleaseNotesFailedToDownloadWithError(error) }
    }
    override func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        if !remote { super.showDownloadDidReceiveExpectedContentLength(expectedContentLength) }
    }
    override func showDownloadDidReceiveData(ofLength length: UInt64) {
        if !remote { super.showDownloadDidReceiveData(ofLength: length) }
    }
    override func showExtractionReceivedProgress(_ progress: Double) {
        if !remote { super.showExtractionReceivedProgress(progress) }
    }
}
