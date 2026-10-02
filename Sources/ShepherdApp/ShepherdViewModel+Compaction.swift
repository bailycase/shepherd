import Foundation
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions

extension ShepherdViewModel {
    /// Settings ▸ Agents ▸ Compact at: writes the share into pi's own settings for the models it
    /// offers, now (so a model added since is covered) and whenever the setting changes. The write
    /// waits for pi's settings lock and the catalog needs pi, so it runs off the main actor; a new
    /// agent's pi reads the file as it starts, a running one keeps what it had (docs/native-thread.md
    /// › Context and compaction).
    func installCompactionThreshold() {
        applyCompactionThreshold()
        settings.onCompactAtChange = { [weak self] _ in self?.applyCompactionThreshold() }
    }

    func applyCompactionThreshold() {
        let pi = server.pi
        let percent = settings.compactAtPercent
        Task.detached(priority: .utility) {
            do {
                try pi.applyCompactionThreshold(percent: percent)
            } catch {
                ShepherdLog.info("Shepherd couldn't write Compact at into its pi's settings: \(error)")
            }
        }
    }
}
