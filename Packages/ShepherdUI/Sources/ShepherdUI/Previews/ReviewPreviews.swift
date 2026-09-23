import SwiftUI

/// The Review board's FleetView diff.
private enum ReviewSample {
    static func line(_ id: Int, _ kind: NWDiffLineKind, old: Int?, new: Int?, _ code: String) -> NWDiffRow {
        .line(NWDiffLineContent(id: "l\(id)", key: id, kind: kind, oldNumber: old, newNumber: new, text: AttributedString(code), source: code))
    }

    static let rows: [NWDiffRow] = [
        .hunk(id: "h1", header: "@@ -12,55 +12,10 @@ struct FleetView: View {"),
        line(1, .context, old: 12, new: 12, "    let connected = connection.phase == .connected"),
        line(2, .removed, old: 15, new: nil, "        Section {"),
        line(3, .removed, old: 16, new: nil, "          if let configuration = connection.configuration {"),
        .fold(id: "f1", count: 13, kind: .removed, range: "18–32"),
        line(4, .removed, old: 33, new: nil, "              Button(\"reconnect\") { connection.reconnect() }"),
        line(5, .added, old: nil, new: 15, "        Section {"),
        line(6, .added, old: nil, new: 16, "          HostCard(connection: connection)"),
        line(7, .context, old: 60, new: 17, "        Section {"),
    ]

    static let files: [NWFileStrip.Item] = [
        .init(id: "a", path: "App/iOS/FleetView.swift", status: .modified, added: 10, removed: 54),
        .init(id: "b", path: "App/iOS/ThreadView.swift", status: .modified, added: 48, removed: 3, isTouched: true),
        .init(id: "c", path: "App/iOS/HostCard.swift", status: .added, added: 31, removed: 0),
        .init(id: "d", path: "App/iOS/MobileTokens.swift", status: .deleted, added: 0, removed: 88, isViewed: true),
    ]
}

#Preview("Diff") {
    NWPreviewBoth {
        VStack(spacing: 0) {
            NWFileHeader(path: "App/iOS/FleetView.swift", hunkCount: 2, commentCount: 1, isExpanded: true, isViewed: false,
                         toggle: {}, toggleViewed: {}, revert: {})
            NWDiffView(ReviewSample.rows, onComment: { _ in }, onExpand: { _ in }) { line in
                if line.key == 4 {
                    NWInlineComment(initial: "B", author: "You", meta: "line 33 · just now",
                                    text: "Keep reconnect reachable from the row — flaky Wi-Fi users lose the one-tap retry.",
                                    onEdit: {}, onDelete: {})
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: NW.Radius.m))
        .nwBorder(.nw.lineSubtle, radius: NW.Radius.m)
        .frame(width: 560)
    }
}

#Preview("File headers") {
    NWPreviewBoth {
        VStack(spacing: NW.Space.m) {
            NWFileHeader(path: "App/iOS/FleetView.swift", hunkCount: 2, isExpanded: true, isViewed: false,
                         toggle: {}, toggleViewed: {}, revert: {}, open: {})
            NWFileHeader(path: "README.md", hunkCount: 1, commentCount: 2, isExpanded: false, isViewed: true,
                         toggle: {}, toggleViewed: {})
        }
        .frame(width: 520)
    }
}

#Preview("File strip") {
    NWPreviewBoth {
        NWFileStrip(ReviewSample.files, selection: "a") { _ in }
            .frame(width: 560)
    }
}

#Preview("Comment editor") {
    @Previewable @State var draft = "Name this constant"
    @Previewable @FocusState var focused: Bool
    NWPreviewBoth {
        NWCommentEditor(text: $draft, isFocused: $focused, onSave: {}, onCancel: {})
            .frame(width: 440)
    }
}

#Preview("Review composer") {
    @Previewable @State var summary = ""
    @Previewable @FocusState var focused: Bool
    NWPreviewBoth {
        NWReviewComposer(text: $summary, isFocused: $focused, inlineCount: 1, canCommit: true, canRequestChanges: true,
                         onCommit: {}, onRequestChanges: {})
            .frame(width: 528)
    }
}
