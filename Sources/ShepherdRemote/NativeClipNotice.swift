import Foundation
import ShepherdProtocol

/// What a thread says when its snapshot shortened something or could not read it, in the words the
/// Mac and the iPhone and iPad share (docs/native-thread.md › RPCThreadState › Clipped). Each line is one fact the
/// host reported (`NativeThreadClips`), says what is missing and when it returns, and goes away
/// with the fact. Nothing here is an action: none of them has a way to see more than the thread
/// already shows.
///
/// Older history is never one of them. It is a scroll up (`olderCursor`), so a thread with only
/// older pages to load says nothing. A long message's own text is marked on its row.
public struct NativeClipNotice: Equatable, Sendable {
    public var lines: [String]

    /// The lines, one under another.
    public var text: String { lines.joined(separator: "\n") }

    public static let history = "Some messages couldn't be read from pi · they appear after the agent's next reply"
    public static let live = "Part of this turn's output is hidden while it runs · it shows when the turn ends"
    public static let oneQuestion = "A question from the agent is too large to show here"
    public static func questions(_ count: Int) -> String { "\(count) questions from the agent are too large to show here" }
    /// An older host says only that something is clipped, and with nothing older to load that is all
    /// there is to say.
    public static let unknown = "Some output is clipped"

    /// `running` is whether the thread shows its turn running: the live output left out is hidden
    /// only until that turn ends.
    public init?(_ snapshot: NativeThreadSnapshot?, running: Bool) {
        guard let snapshot else { return nil }
        var lines: [String] = []
        if let clips = snapshot.clips {
            if clips.history { lines.append(Self.history) }
            if clips.live > 0, running { lines.append(Self.live) }
            if clips.questions == 1 { lines.append(Self.oneQuestion) }
            if clips.questions > 1 { lines.append(Self.questions(clips.questions)) }
        } else if snapshot.clipped, snapshot.olderCursor == nil {
            lines.append(Self.unknown)
        }
        guard !lines.isEmpty else { return nil }
        self.lines = lines
    }
}
