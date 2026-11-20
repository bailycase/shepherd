import Foundation
import ShepherdProtocol

/// When a watched thread's goal update becomes a local alert: a goal that was live, stayed live,
/// and moved into a terminal state, while push is not delivering it instead. The first snapshot
/// is a baseline, reconnecting replays nothing, and elapsed/metadata revisions post nothing.
/// Gated on notification authorization at the call site, never on device idiom, so iPad and
/// iPhone Duo's inner display alert like the phone does.
public enum GoalAlertPolicy {
    public static func shouldPost(old: NativeGoal?, new: NativeGoal?,
                                  previouslyLive: Bool, live: Bool,
                                  pushEnabled: Bool) -> Bool {
        guard live, previouslyLive, let old, let new,
              old.id == new.id, old.state != new.state,
              new.state == .met || new.state == .needsYou,
              !pushEnabled else { return false }
        return true
    }
}
