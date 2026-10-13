import SwiftUI
import ShepherdCore
import ShepherdUI

/// What a design's chat shows of its Git state (GitDesignShell): the merge's card after the last
/// turn while the merge is the agent's, and the intro in the empty chat of a design opened from Git.
/// The design screen sets it around the chat; nil everywhere else.
struct DesignGitChat {
    static let rowID = "design-git-merge"

    var phase: NWGitMergePhase?
    /// The design came from Git and its chat has said nothing yet: "No agent has started".
    var opened: Bool
    var review: (() -> Void)?
    var retry: (() -> Void)?
}

extension EnvironmentValues {
    @Entry var designGitChat: DesignGitChat? = nil
}

/// The design screen's chat with its Git state around it.
struct DesignGitChatEnvironment: ViewModifier {
    var vm: ShepherdViewModel
    let designID: DesignID

    func body(content: Content) -> some View {
        let git = vm.designGit(designID)
        let phase = DesignGitPresentation.mergePhase(git.state?.merge)
        // A shared design's empty chat says its agent waits for a message (the thread shows the
        // intro only while it has no rows).
        let opened = git.state != nil
        content.environment(\.designGitChat, phase == nil && !opened ? nil : DesignGitChat(
            phase: phase, opened: opened,
            review: { vm.reviewDesignGitMerge(designID) },
            retry: { vm.resolveDesignGitMerge(designID) }))
    }
}
