import SwiftUI
import ShepherdUI
import ShepherdRemote

/// The thread's Can't start banner above the composer, the Mac's (`Composer`): why the agent's pi
/// stopped, then the buttons `NativeStartBanner` names, or progress while a Retry is under way. It draws the
/// presentation it is given (the problem, the store's restart state, the host's capability and connection, all
/// folded in `NativeStartBanner`) and reports a tap; the thread's store owns the progress and the refusal.
struct StartProblemBanner: View, Equatable {
    let banner: NativeStartBanner
    let perform: (NativeStartAction) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.banner == rhs.banner }

    var body: some View {
        SHBanner(banner.inProgress ? .running : .failed, title: banner.title, message: banner.message.isEmpty ? nil : banner.message,
                 stacked: !banner.actions.isEmpty) {
            ForEach(banner.actions, id: \.self) { action in
                Button(action == .startNewConversation ? "Start new conversation" : "Retry") { perform(action) }
                    .buttonStyle(.sh(action == .startNewConversation ? .ghost : .secondary))
            }
        }
    }
}
