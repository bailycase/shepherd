import SwiftUI
import ShepherdCore
import ShepherdSessions

struct ReviewComment: Identifiable, Hashable {
    let fileID: String
    let lineID: Int
    let filePath: String
    let lineNumber: Int
    let marker: String
    let content: String
    var text: String

    var id: String { "\(fileID):\(lineID)" }
    var path: String { filePath }
    var line: Int { lineNumber }

    init(
        fileID: String,
        lineID: Int,
        filePath: String,
        lineNumber: Int,
        marker: String = " ",
        content: String = "",
        text: String
    ) {
        self.fileID = fileID
        self.lineID = lineID
        self.filePath = filePath
        self.lineNumber = lineNumber
        self.marker = marker
        self.content = content
        self.text = text
    }
}

@MainActor
final class ReviewSession: ObservableObject, Identifiable {
    let id = UUID()
    let agentID: AgentID
    let paneID: PaneID
    let cwd: String
    let reference: String?
    @Published var files: [DiffFile]
    @Published var loadError: String?
    @Published var comments: [ReviewComment]
    @Published var summary: String

    init(
        agentID: AgentID,
        paneID: PaneID,
        cwd: String,
        reference: String?,
        files: [DiffFile] = [],
        loadError: String? = nil,
        comments: [ReviewComment] = [],
        summary: String = ""
    ) {
        self.agentID = agentID
        self.paneID = paneID
        self.cwd = cwd
        self.reference = reference
        self.files = files
        self.loadError = loadError
        self.comments = comments
        self.summary = summary
    }
}

func formatReview(files: [DiffFile], comments: [ReviewComment], summary: String, reference: String? = nil) -> String {
    var output = ["Diff review (\(reference ?? "working tree vs HEAD")):", ""]
    let fileOrder = Dictionary(uniqueKeysWithValues: files.enumerated().map { ($0.element.id, $0.offset) })
    let orderedComments = comments.filter {
        !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }.sorted { lhs, rhs in
        let leftFile = fileOrder[lhs.fileID] ?? Int.max
        let rightFile = fileOrder[rhs.fileID] ?? Int.max
        if leftFile != rightFile { return leftFile < rightFile }
        if lhs.lineNumber != rhs.lineNumber { return lhs.lineNumber < rhs.lineNumber }
        return lhs.lineID < rhs.lineID
    }

    if orderedComments.isEmpty {
        output.append("No line comments.")
    } else {
        for (index, comment) in orderedComments.enumerated() {
            if index > 0 { output.append("") }
            output.append("\(comment.filePath):\(comment.lineNumber) [\(comment.marker) \(comment.content)]")
            output.append(contentsOf: comment.text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { "  \($0)" }
            )
        }
    }

    let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedSummary.isEmpty {
        output.append("")
        output.append("Overall: \(trimmedSummary)")
    }
    return output.joined(separator: "\n")
}

extension DiffLine.Kind {
    var reviewMarker: String {
        switch self {
        case .context: return " "
        case .added: return "+"
        case .removed: return "-"
        }
    }
}
