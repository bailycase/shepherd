import FileProvider
import Foundation
import Observation
import UIKit

/// Keeps the Shepherd location in Files in step with the app: its domain added, the paired Macs shared with the
/// extension (their tokens moved into the shared Keychain group), and the location read again whenever the app comes to
/// the front. That is also when Files tries again a save that waited for an unreachable Mac.
@MainActor
final class FilesLocationBridge {
    private let hosts: MobileHosts
    private var shared: [FilesSharedHost]?
    private var activation: NSObjectProtocol?

    init(hosts: MobileHosts) {
        self.hosts = hosts
        NSFileProviderManager.add(FilesShared.domain) { _ in }
        activation = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil,
                                                            queue: .main) { _ in Self.signal() }
        track()
    }

    /// Shares the Macs again when one is added, edited, forgotten or learns its fleet id.
    private func track() {
        let current = withObservationTracking {
            hosts.hosts.map { FilesSharedHost(record: $0.record, expecting: hosts.expectedFleetID($0)) }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.track() }
        }
        guard current != shared else { return }
        shared = current
        for host in current { HostKeychain.share(account: HostKeychain.account(host.record.id)) }
        FilesShared.write(current)
        Self.signal()
    }

    private static func signal() {
        NSFileProviderManager(for: FilesShared.domain)?.signalEnumerator(for: .workingSet) { _ in }
    }
}
