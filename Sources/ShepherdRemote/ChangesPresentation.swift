import Foundation
import ShepherdProtocol

// What the Changes pane says around its diff, shared by the Mac and the iOS client: the send
// bar that replaced the overall comment box (ChangesSplit, MobileChanges), the message it sends,
// and the "Edited N files" card drawn from the turns the host recorded.

/// "Send 1 comment", "Send 3 comments" (MobileChanges' button).
public func reviewSendTitle(comments: Int) -> String {
    "Send \(comments) comment\(comments == 1 ? "" : "s")"
}

/// The send bar's two lines: "1 comment" over "on outbox.go, not sent yet" (or "on 2 files").
public func reviewPendingText(_ comments: [ReviewComment]) -> (count: String, detail: String) {
    let count = "\(comments.count) comment\(comments.count == 1 ? "" : "s")"
    let files = Set(comments.map(\.fileID))
    let place = files.count == 1 ? (comments.first.map { ($0.filePath as NSString).lastPathComponent } ?? "") : "\(files.count) files"
    return (count, "on \(place), not sent yet")
}

/// The review as the agent's next turn: every line comment, in the order the pane lists files,
/// under the scope it was written against ("Branch · vs main"). There is no overall comment:
/// anything else is said in the thread.
public func formatChangesReview(fileIDs: [String], comments: [ReviewComment], scopeTitle: String) -> String {
    formatReview(fileIDs: fileIDs, comments: comments, summary: "", reference: scopeTitle)
}

extension NativeTurnChanges {
    /// The card for a turn the host recorded: its files (the first `ChangesLimits.turnFiles`)
    /// as the card lists them. nil for a turn that changed nothing.
    public init?(turn: ChangesTurn) {
        guard turn.fileCount > 0 else { return nil }
        let files = turn.files.map { file in
            File(path: file.path, status: file.status == .added ? .added : file.status == .deleted ? .deleted : .modified,
                 added: file.added, removed: file.removed)
        }
        self.init(files: files, added: turn.added, removed: turn.removed, fileCount: turn.fileCount, turnID: turn.id,
                  undone: turn.state == .undone, canUndo: turn.canUndo, canRedo: turn.canRedo)
    }
}

/// The turn the host recorded for the turn that `userTimestamp` (pi's stamp on the user message
/// that opened it) started.
public func changesTurn(forMessageAt userTimestamp: Double?, in turns: [ChangesTurn]?) -> ChangesTurn? {
    guard let userTimestamp, let turns else { return nil }
    return turns.last { $0.messageTimestamp == userTimestamp }
}
