import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// Whether a paired host offers Issues & PRs: the sidebar's row and its Pinned section show then (iPadIPReview).
@MainActor
enum ForgeEntry {
    static func available(_ hosts: MobileHosts) -> Bool {
        hosts.hosts.contains { $0.supports(RemoteProtocol.forgeCapability) }
    }
}

