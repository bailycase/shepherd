import SwiftUI
import ShepherdCore

struct DiffReviewPane: View {
    @ObservedObject var session: ReviewSession
    let isFocused: Bool
    @EnvironmentObject private var vm: ShepherdViewModel
    @ObservedObject private var themes = ThemeManager.shared
    @State private var editingTarget: CommentTarget?
    @State private var draft = ""
    @State private var collapsedFiles: Set<String> = []
    @State private var highlightedHunks: [HunkKey: [AttributedString]] = [:]

    private struct CommentTarget: Hashable {
        let fileID: String
        let lineID: Int
    }

    private struct HunkKey: Hashable {
        let fileID: String
        let hunkID: String
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(Tokens.separator)
                .frame(height: 1)
            content
            if session.loadError == nil {
                Rectangle()
                    .fill(Tokens.separator)
                    .frame(height: 1)
                bottomBar
            }
        }
        .background(Tokens.terminalBg)
        .accessibilityLabel("diff review")
        .accessibilityValue(isFocused ? "focused" : "not focused")
        .onChange(of: themes.current.id) {
            highlightedHunks.removeAll()
        }
    }

    private var header: some View {
        HStack(spacing: Metrics.spacing8) {
            VStack(alignment: .leading, spacing: Metrics.spacing2) {
                Text("review")
                    .font(Fonts.mono(12, .semibold))
                    .foregroundStyle(isFocused ? Tokens.textPrimary : Tokens.textSecondary)
                Text("\(cwdTail) · \(session.reference ?? "working tree vs HEAD")")
                    .font(Fonts.mono(10.5))
                    .foregroundStyle(Tokens.textMetadata)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: Metrics.spacing8)
            Text("\(session.comments.count) comment\(session.comments.count == 1 ? "" : "s")")
                .font(Fonts.mono(10.5))
                .foregroundStyle(Tokens.textMetadata)
            ReviewActionButton("cancel") {
                vm.cancelReview(session)
            }
            ReviewActionButton("submit", prominent: true, disabled: session.loadError != nil) {
                vm.submitReview(session)
            }
        }
        .padding(.horizontal, Metrics.spacing12)
        .frame(height: Metrics.headerHeight)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        if let loadError = session.loadError {
            reviewMessage(loadError)
        } else if session.files.isEmpty {
            reviewMessage("no changes")
        } else {
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(session.files) { file in
                        fileView(file)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func reviewMessage(_ text: String) -> some View {
        VStack(spacing: Metrics.spacing8) {
            Text(text)
                .font(Fonts.mono(11))
                .foregroundStyle(session.loadError == nil ? Tokens.textDim : Tokens.statusBlocked)
            ReviewActionButton("cancel") {
                vm.cancelReview(session)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fileView(_ file: DiffFile) -> some View {
        let collapsed = collapsedFiles.contains(file.id)
        return VStack(alignment: .leading, spacing: 0) {
            fileHeader(file, collapsed: collapsed)
            if !collapsed {
                ForEach(file.hunks) { hunk in
                    hunkView(file: file, hunk: hunk)
                }
                Spacer().frame(height: Metrics.spacing12)
            }
        }
    }

    private func fileHeader(_ file: DiffFile, collapsed: Bool) -> some View {
        let commentCount = session.comments.filter { $0.fileID == file.id }.count
        return Button {
            if collapsed {
                collapsedFiles.remove(file.id)
            } else {
                collapsedFiles.insert(file.id)
            }
        } label: {
            HStack(spacing: Metrics.spacing8) {
                Text(collapsed ? "▸" : "▾")
                    .foregroundStyle(Tokens.textMetadata)
                Text(file.displayPath)
                    .font(Fonts.mono(11.5, .medium))
                    .foregroundStyle(Tokens.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Metrics.spacing8)
                if collapsed && commentCount > 0 {
                    Text("\(commentCount)↳")
                        .foregroundStyle(Tokens.textSecondary)
                }
                if file.addedCount > 0 {
                    Text("+\(file.addedCount)")
                        .foregroundStyle(Tokens.statusWorking)
                }
                if file.removedCount > 0 {
                    Text("-\(file.removedCount)")
                        .foregroundStyle(Tokens.statusBlocked)
                }
                ForEach(fileBadges(file), id: \.self) { badge in
                    Text(badge)
                        .foregroundStyle(Tokens.textDim)
                }
            }
            .font(Fonts.mono(10.5))
            .padding(.horizontal, Metrics.spacing12)
            .frame(height: Metrics.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.rowActiveHeader)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func fileBadges(_ file: DiffFile) -> [String] {
        var badges: [String] = []
        if file.isNew { badges.append("new") }
        if file.isDeleted { badges.append("deleted") }
        if file.isRenamed { badges.append("renamed") }
        if file.isBinary { badges.append("binary") }
        return badges
    }

    private var highlightStyle: CodeHighlight.Style { Tokens.codeHighlightStyle }

    private func hunkView(file: DiffFile, hunk: DiffHunk) -> some View {
        let key = HunkKey(fileID: file.id, hunkID: hunk.id)
        let highlightedLines = highlightedHunks[key] ?? []
        return VStack(alignment: .leading, spacing: 0) {
            Text(hunk.header)
                .font(Fonts.mono(10.5))
                .foregroundStyle(Tokens.textDim)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Metrics.spacing8)
                .frame(height: Metrics.rowHeight)
                .background(Tokens.workspaceBg)
            ForEach(hunk.lines.indices, id: \.self) { index in
                let line = hunk.lines[index]
                let highlighted = highlightedLines.indices.contains(index)
                    ? highlightedLines[index]
                    : AttributedString(line.text)
                lineView(file: file, line: line, highlighted: highlighted)
            }
        }
        .task(id: themes.current.id) {
            guard highlightedHunks[key] == nil else { return }
            highlightedHunks[key] = CodeHighlight.highlightLines(
                hunk.lines.map(\.text), path: file.displayPath, style: highlightStyle
            )
        }
    }

    private func lineView(file: DiffFile, line: DiffLine, highlighted: AttributedString) -> some View {
        let target = CommentTarget(fileID: file.id, lineID: line.id)
        let comment = session.comments.first {
            $0.fileID == target.fileID && $0.lineID == target.lineID
        }
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                beginComment(file: file, line: line)
            } label: {
                diffLineRow(line, highlighted: highlighted)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())

            if editingTarget == target {
                composer(target: target)
            } else if let comment {
                commentRow(comment) {
                    beginComment(file: file, line: line)
                }
            }
        }
    }

    private func diffLineRow(_ line: DiffLine, highlighted: AttributedString) -> some View {
        let background: Color = switch line.kind {
        case .added: Tokens.statusWorking.opacity(0.12)
        case .removed: Tokens.statusBlocked.opacity(0.12)
        case .context: Color.clear
        }
        return HStack(spacing: Metrics.spacing5) {
            Text(line.oldLine.map(String.init) ?? "")
                .foregroundStyle(Tokens.textMetadata)
                .frame(width: Metrics.spacing20 * 2, alignment: .trailing)
            Text(line.newLine.map(String.init) ?? "")
                .foregroundStyle(Tokens.textMetadata)
                .frame(width: Metrics.spacing20 * 2, alignment: .trailing)
            Text(line.kind.reviewMarker)
                .frame(width: Metrics.spacing20, alignment: .center)
                .foregroundStyle(line.kind == .added ? Tokens.statusWorking : line.kind == .removed ? Tokens.statusBlocked : Tokens.textMetadata)
            Text(highlighted)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(Fonts.mono(10.5))
        .foregroundStyle(Tokens.textPrimary)
        .padding(.horizontal, Metrics.spacing8)
        .frame(height: Metrics.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
    }

    private func commentRow(_ comment: ReviewComment, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Metrics.spacing5) {
                Text("↳")
                    .foregroundStyle(Tokens.textMetadata)
                Text(comment.text)
                    .font(Fonts.mono(10.5))
                    .foregroundStyle(Tokens.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, Metrics.spacing8)
            .padding(.vertical, Metrics.spacing5)
            .padding(.leading, Metrics.spacing20 * 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.rowSelection)
            .overlay(Rectangle().stroke(Tokens.paneBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func composer(target: CommentTarget) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacing5) {
            TextEditor(text: $draft)
                .font(Fonts.mono(10.5))
                .foregroundStyle(Tokens.textPrimary)
                .scrollContentBackground(.hidden)
                .frame(minHeight: Metrics.rowHeight * 2, maxHeight: Metrics.rowHeight * 3)
                .padding(.horizontal, Metrics.spacing5)
                .background(Tokens.workspaceBg)
                .overlay(Rectangle().stroke(Tokens.paneBorder, lineWidth: 1))
                // Enter saves the comment; ⇧Enter inserts a newline.
                .onKeyPress(.return, phases: .down) { press in
                    guard !press.modifiers.contains(.shift) else { return .ignored }
                    saveComment(target)
                    return .handled
                }
            HStack(spacing: Metrics.spacing5) {
                Spacer(minLength: 0)
                ReviewActionButton("cancel") {
                    editingTarget = nil
                }
                ReviewActionButton("save", prominent: true) {
                    saveComment(target)
                }
            }
        }
        .padding(.horizontal, Metrics.spacing20 * 2)
        .padding(.vertical, Metrics.spacing5)
        .background(Tokens.rowSelection)
    }

    private var bottomBar: some View {
        HStack(spacing: Metrics.spacing8) {
            TextField(
                "",
                text: $session.summary,
                prompt: Text("overall comments…").foregroundStyle(Tokens.textDim)
            )
            .textFieldStyle(.plain)
            .font(Fonts.mono(10.5))
            .foregroundStyle(Tokens.textPrimary)
            .padding(.horizontal, Metrics.spacing8)
            .frame(height: Metrics.rowHeight)
            .overlay(Rectangle().stroke(Tokens.paneBorder, lineWidth: 1))
            ReviewActionButton("submit", prominent: true, disabled: session.loadError != nil) {
                vm.submitReview(session)
            }
        }
        .padding(.horizontal, Metrics.spacing12)
        .padding(.vertical, Metrics.spacing8)
    }

    private var cwdTail: String {
        let expanded = (session.cwd as NSString).expandingTildeInPath
        let tail = (expanded as NSString).lastPathComponent
        return tail.isEmpty ? expanded : tail
    }

    private func beginComment(file: DiffFile, line: DiffLine) {
        editingTarget = CommentTarget(fileID: file.id, lineID: line.id)
        draft = session.comments.first {
            $0.fileID == file.id && $0.lineID == line.id
        }?.text ?? ""
    }

    private func saveComment(_ target: CommentTarget) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        session.comments.removeAll { $0.fileID == target.fileID && $0.lineID == target.lineID }
        if !text.isEmpty,
           let file = session.files.first(where: { $0.id == target.fileID }),
           let line = file.hunks.flatMap(\.lines).first(where: { $0.id == target.lineID }) {
            session.comments.append(ReviewComment(
                fileID: file.id,
                lineID: line.id,
                filePath: file.displayPath,
                lineNumber: line.newLine ?? line.oldLine ?? 0,
                marker: line.kind.reviewMarker,
                content: line.text,
                text: text
            ))
        }
        editingTarget = nil
    }
}

private struct ReviewActionButton: View {
    let label: String
    let prominent: Bool
    let disabled: Bool
    let action: () -> Void

    init(_ label: String, prominent: Bool = false, disabled: Bool = false, action: @escaping () -> Void) {
        self.label = label
        self.prominent = prominent
        self.disabled = disabled
        self.action = action
    }

    var body: some View {
        Button(label, action: action)
            .buttonStyle(.plain)
            .font(Fonts.mono(10.5, prominent ? .medium : .regular))
            .foregroundStyle(prominent ? Tokens.textPrimary : Tokens.textSecondary)
            .padding(.horizontal, Metrics.spacing8)
            .frame(height: Metrics.rowHeight)
            .overlay(Rectangle().stroke(prominent ? Tokens.accentButton : Tokens.paneBorder, lineWidth: 1))
            .disabled(disabled)
    }
}
