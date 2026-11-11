import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdUI
import SwiftUI

/// The sidebar's pull request badges: the links and kept-open notes the background host on this
/// Mac pushes (`RemoteReply.pullRequestLinks`). The host looks them up and closes merged threads
/// (Settings ▸ Worktrees).
@MainActor
extension ShepherdViewModel {
    /// The host's links and notes, as pushed.
    func applyPullRequestLinks(_ links: [AgentID: ThreadPullRequest], notes: [AgentID: String]) {
        if pullRequestLinks != links { pullRequestLinks = links }
        if pullRequestCloseNotes != notes { pullRequestCloseNotes = notes }
    }

    /// A deleted thread's link goes with it.
    func forgetPullRequestLink(_ id: AgentID) {
        if pullRequestLinks[id] != nil { pullRequestLinks.removeValue(forKey: id) }
        if pullRequestCloseNotes[id] != nil { pullRequestCloseNotes.removeValue(forKey: id) }
        if branchPullRequests[id] != nil { branchPullRequests.removeValue(forKey: id) }
    }

    /// What the sidebar's badges draw: each linked thread's number in its state's color; a merged
    /// one kept open draws in the attention color and its help says why.
    var sidebarPullRequests: [AgentID: SidebarPullRequest] {
        Dictionary(uniqueKeysWithValues: pullRequestLinks.map { id, link in
            let (word, tone) = ForgePresentation.badge(link.state)
            let kept = pullRequestCloseNotes[id]
            return (id, SidebarPullRequest(
                badge: SHSidebarRow.Badge("#\(link.ref.number)", color: kept == nil ? tone.color : Color.sh.lanternText),
                line: "Pull request #\(link.ref.number) \(word.lowercased())" + (kept.map { ", kept open: \($0)" } ?? "")))
        })
    }
}

/// A thread row's pull request: its badge, and the line its help and VoiceOver label gain.
struct SidebarPullRequest: Equatable {
    var badge: SHSidebarRow.Badge
    var line: String
}

extension SidebarListRow {
    mutating func attach(_ pull: SidebarPullRequest) {
        pullRequest = pull.badge
        help += "\n" + pull.line
        accessibilityLabel += ", " + pull.line
    }
}
