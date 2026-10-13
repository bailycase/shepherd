import SwiftUI

// Git sharing for designs (GitDesignPublish, GitDesignOpen, GitDesignCoworker, GitDesignChanges,
// GitDesignConflict, GitDesignMerge, GitDesignMergeReview, DesignGitStatus, GitDesignShell).
// Everything here takes its words and state as values: nothing runs git.

/// The boards' own measures for the Git surfaces.
public enum NWGitMetrics {
    // The toolbar chip
    public static let chipHeight: CGFloat = 30
    public static let chipGlyph: CGFloat = 14
    public static let chipChevron: CGFloat = 10
    // Sheets
    public static let shareWidth: CGFloat = 620
    public static let openWidth: CGFloat = 560
    public static let panelWidth: CGFloat = 500
    public static let dialogWidth: CGFloat = 672
    public static let headerGlyph: CGFloat = 20
    public static let panelGlyph: CGFloat = 16
    public static let closeSize: CGFloat = 28
    public static let closeGlyph: CGFloat = 14
    public static let openCloseGlyph: CGFloat = 16
    public static let fieldHeight: CGFloat = 36
    public static let tickGlyph: CGFloat = 14
    public static let buttonHeight: CGFloat = 32
    public static let smallButtonHeight: CGFloat = 28
    public static let rowHeight: CGFloat = 40
    public static let commitLines = 2
    /// The mono a body line sets a name or hash in (the board's `.mono` span at 13.5).
    public static let bodyMono: CGFloat = 13.5
    // Notices
    public static let noticeGlyph: CGFloat = 14
    public static let noticeSpacing: CGFloat = 12
    public static let noticeMaxWidth: CGFloat = 520
    public static let dismissGlyph: CGFloat = 10
    /// A card's lines on the merge dialog and the chat card.
    public static let introSpacing = NW.Space.l
}

public enum NWGitTone: Sendable, Equatable { case primary, done, running, attention, secondary }

extension NWGitTone {
    @MainActor var color: Color {
        switch self {
        case .primary: Color.nw.textPrimary
        case .done: AgentState.done.textColor
        case .running: AgentState.running.textColor
        case .attention: AgentState.attention.textColor
        case .secondary: Color.nw.textSecondary
        }
    }
}

private typealias M = NWGitMetrics

// MARK: Chip

/// The design toolbar's Git chip (DesignGitStatus): "Share with Git", "main · Up to date", "main · 3 changes" …
public struct NWDesignGitChip: View, Equatable {
    let label: String
    let tone: NWGitTone
    let hint: String
    let isOpen: Bool
    let action: () -> Void

    public init(label: String, tone: NWGitTone, hint: String, isOpen: Bool = false, action: @escaping () -> Void) {
        self.label = label
        self.tone = tone
        self.hint = hint
        self.isOpen = isOpen
        self.action = action
    }

    public nonisolated static func == (a: Self, b: Self) -> Bool {
        a.label == b.label && a.tone == b.tone && a.hint == b.hint && a.isOpen == b.isOpen
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: NW.Radius.s)
        Button(action: action) {
            HStack(spacing: NW.Space.m) {
                Image(systemName: NWGlyph.gitBranch.symbolName).font(.system(size: M.chipGlyph, weight: .medium))
                Text(label).font(.nw(.ui)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: M.chipChevron, weight: .medium))
            }
            .foregroundStyle(tone.color)
            .padding(.horizontal, NW.Space.l)
            .frame(minHeight: M.chipHeight)
            .background(isOpen ? Color.nw.bgSelected : Color.nw.bgRaised, in: shape)
            .nwBorder(Color.nw.lineStrong, in: shape)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(hint)
        .accessibilityLabel("\(label). \(hint)")
    }
}

// MARK: Shared pieces

private struct GitClose: View {
    let label: String
    let glyph: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: glyph, weight: .medium))
                .foregroundStyle(Color.nw.textSecondary)
                .frame(width: M.closeSize, height: M.closeSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// A labelled 36pt field on `bgSunken`, as the Git boards draw it.
private struct GitField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var mono = false
    var caption: String?
    var enabled = true
    var submit: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: NW.Space.s) {
            Text(title).font(.nw(.ui))
            let shape = RoundedRectangle(cornerRadius: NW.Radius.m)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(mono ? .nw(.code) : .nw(.body))
                .foregroundStyle(Color.nw.textPrimary)
                .autocorrectionDisabled()
                .padding(.horizontal, NW.Space.l)
                .frame(minHeight: M.fieldHeight)
                .background(Color.nw.bgSunken, in: shape)
                .nwBorder(Color.nw.lineStrong, in: shape)
                .disabled(!enabled)
                .nwEnabledOpacity(enabled)
                .onSubmit(submit)
                .accessibilityLabel(title)
            if let caption {
                Text(caption).font(.nw(.caption)).foregroundStyle(Color.nw.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct GitErrorBox: View {
    let error: NWGitSheetError

    var body: some View {
        VStack(alignment: .leading, spacing: NW.Space.xs) {
            Text(error.title).font(.nw(.title)).foregroundStyle(AgentState.failed.textColor)
            Text(error.detail).nwText(.caption).foregroundStyle(Color.nw.textSecondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(NW.Space.l)
        .background(AgentState.failed.tint ?? Color.clear, in: RoundedRectangle(cornerRadius: NW.Radius.s))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }
}

/// The bordered `bgWindow` box inside a sheet.
private extension View {
    func gitBox(padding: EdgeInsets) -> some View {
        self.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .nwCard(radius: NW.Radius.m, fill: Color.nw.bgWindow)
    }
}

public struct NWGitSheetError: Equatable, Sendable {
    public var title: String
    public var detail: String
    public init(title: String, detail: String) {
        self.title = title
        self.detail = detail
    }
}

// MARK: Share sheet

/// Share with Git (Git 1, GitDesignPublish).
public struct NWGitShareSheet: View {
    @Binding var repository: String
    @Binding var message: String
    let boards: Int
    let error: NWGitSheetError?
    let working: Bool
    let close: () -> Void
    let share: () -> Void

    public init(repository: Binding<String>, message: Binding<String>, boards: Int, error: NWGitSheetError?, working: Bool,
                close: @escaping () -> Void, share: @escaping () -> Void) {
        _repository = repository
        _message = message
        self.boards = boards
        self.error = error
        self.working = working
        self.close = close
        self.share = share
    }

    private var canShare: Bool {
        !working && !repository.trimmingCharacters(in: .whitespaces).isEmpty && !message.trimmingCharacters(in: .whitespaces).isEmpty
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: NW.Space.l) {
                Image(systemName: NWGlyph.gitBranch.symbolName).font(.system(size: M.headerGlyph, weight: .medium))
                    .accessibilityHidden(true)
                Text("Share with Git").font(.nw(.title)).accessibilityAddTraits(.isHeader)
                Spacer(minLength: NW.Space.m)
                GitClose(label: "Close share dialog", glyph: M.closeGlyph, action: close)
            }
            .padding(.vertical, NW.Space.xl).padding(.horizontal, NW.Space.xxl)
            .overlay(alignment: .bottom) { NWHairline() }
            VStack(alignment: .leading, spacing: NW.Space.xl) {
                Text("Share this design through a Git repository. Your coworkers can open the same canvas in Shepherd. Shepherd manages the local copy for everyone.")
                    .nwText(.body).foregroundStyle(Color.nw.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                GitField(title: "Repository URL", placeholder: "SSH or HTTPS Git URL", text: $repository, mono: true,
                         caption: "Use an empty repository you already have access to, on any Git host.", enabled: !working, submit: submitIfValid)
                included
                GitField(title: "First commit", placeholder: "Commit message", text: $message, enabled: !working, submit: submitIfValid)
                Text("Your design stays in Shepherd's storage. Changes save locally and are shared only when you commit and push.")
                    .nwText(.caption).foregroundStyle(Color.nw.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let error { GitErrorBox(error: error) }
            }
            .padding(NW.Space.xxl)
            HStack(spacing: NW.Space.m) {
                Spacer(minLength: 0)
                Button("Cancel", action: close).buttonStyle(.nw(.ghost, size: .l)).keyboardShortcut(.cancelAction)
                Button(working ? "Sharing…" : "Create commit & push", action: share)
                    .buttonStyle(.nw(.primary, size: .l)).keyboardShortcut(.defaultAction).disabled(!canShare)
            }
            .padding(.vertical, NW.Space.xl).padding(.horizontal, NW.Space.xxl)
            .overlay(alignment: .top) { NWHairline() }
        }
        .frame(width: M.shareWidth)
        .nwPopover(radius: NW.Radius.l)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private func submitIfValid() { if canShare { share() } }

    private var included: some View {
        VStack(alignment: .leading, spacing: NW.Space.l) {
            Text("What goes in the repository").font(.nw(.headline)).accessibilityAddTraits(.isHeader)
            includedRow("Canvas, pages, notes and every board", trailing: boards == 1 ? "1 board" : "\(boards) boards")
            includedRow("Shared pieces, design system and local assets", trailing: nil)
            includedRow("Pinned comments and replies", trailing: nil)
            Text("Agent chat, credentials, caches and your local viewing state stay on this Mac. Review the design files for private content before sharing.")
                .nwText(.caption).foregroundStyle(Color.nw.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, NW.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { NWHairline() }
        }
        .gitBox(padding: EdgeInsets(top: NW.Space.xl, leading: NW.Space.xl, bottom: NW.Space.xl, trailing: NW.Space.xl))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("What will be shared")
    }

    private func includedRow(_ text: String, trailing: String?) -> some View {
        HStack(spacing: NW.Space.m) {
            Image(systemName: "checkmark").font(.system(size: M.tickGlyph, weight: .semibold))
                .foregroundStyle(AgentState.done.color).accessibilityHidden(true)
            Text(text).nwText(.body).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: NW.Space.m)
            if let trailing { Text(trailing).font(.nw(.mono)).foregroundStyle(Color.nw.textSecondary) }
        }
    }
}

// MARK: Open sheet

/// Open from Git (Git 2, GitDesignOpen).
public struct NWGitOpenSheet: View {
    @Binding var repository: String
    let error: NWGitSheetError?
    let working: Bool
    let close: () -> Void
    let clone: () -> Void

    public init(repository: Binding<String>, error: NWGitSheetError?, working: Bool, close: @escaping () -> Void, clone: @escaping () -> Void) {
        _repository = repository
        self.error = error
        self.working = working
        self.close = close
        self.clone = clone
    }

    private var canClone: Bool { !working && !repository.trimmingCharacters(in: .whitespaces).isEmpty }

    public var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: NW.Space.xl) {
                HStack {
                    Text("Open from Git").font(.nw(.title)).accessibilityAddTraits(.isHeader)
                    Spacer(minLength: NW.Space.m)
                    GitClose(label: "Close dialog", glyph: M.openCloseGlyph, action: close)
                }
                Text("Open a shared design from its repository URL. Shepherd clones it into its own storage and adds it to Designs. Opening does not start an agent.")
                    .nwText(.body).foregroundStyle(Color.nw.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                GitField(title: "Repository URL", placeholder: "SSH or HTTPS Git URL", text: $repository, mono: true,
                         caption: "Uses your configured Git credentials. No folder setup needed.", enabled: !working,
                         submit: { if canClone { clone() } })
                if let error { GitErrorBox(error: error) }
            }
            .padding(NW.Space.xxl)
            HStack(spacing: NW.Space.m) {
                Spacer(minLength: 0)
                Button("Cancel", action: close).buttonStyle(.nw(.secondary, size: .l)).keyboardShortcut(.cancelAction)
                Button(working ? "Cloning…" : error != nil ? "Retry clone" : "Clone & open", action: clone)
                    .buttonStyle(.nw(.primary, size: .l)).keyboardShortcut(.defaultAction).disabled(!canClone)
            }
            .padding(.vertical, NW.Space.xl).padding(.horizontal, NW.Space.xxl)
            .overlay(alignment: .top) { NWHairline() }
        }
        .frame(width: M.openWidth)
        .nwPopover(radius: NW.Radius.l)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

// MARK: Panel

public struct NWGitPanelState: Equatable, Sendable {
    public struct File: Equatable, Sendable, Identifiable {
        public var id: String
        public var letter: String
        public var label: String
        public init(id: String, letter: String, label: String) {
            self.id = id
            self.letter = letter
            self.label = label
        }
    }

    public struct Preview: Equatable, Sendable {
        public var title: String
        public var beforeTitle: String
        public var before: String
        public var afterTitle: String
        public var after: String
        public init(title: String, beforeTitle: String, before: String, afterTitle: String, after: String) {
            self.title = title
            self.beforeTitle = beforeTitle
            self.before = before
            self.afterTitle = afterTitle
            self.after = after
        }
    }

    public struct Notice: Equatable, Sendable {
        public var title: String
        public var text: String
        public var tone: NWGitTone
        public init(title: String, text: String, tone: NWGitTone) {
            self.title = title
            self.text = text
            self.tone = tone
        }
    }

    public struct Incoming: Equatable, Sendable {
        public var subject: String
        public var author: String
        public var hash: String
        public var files: [String]
        public init(subject: String, author: String, hash: String, files: [String]) {
            self.subject = subject
            self.author = author
            self.hash = hash
            self.files = files
        }
    }

    public struct Changes: Equatable, Sendable {
        public var title: String
        public var note: String
        public var files: [File]
        public var selected: String?
        public var preview: Preview?
        public var localTitle: String
        public var pushTitle: String
        public var canCommit: Bool
        public var canPush: Bool
        public init(title: String, note: String, files: [File], selected: String?, preview: Preview?, localTitle: String, pushTitle: String,
                    canCommit: Bool, canPush: Bool) {
            self.title = title
            self.note = note
            self.files = files
            self.selected = selected
            self.preview = preview
            self.localTitle = localTitle
            self.pushTitle = pushTitle
            self.canCommit = canCommit
            self.canPush = canPush
        }
    }

    public var branch: String
    public var repository: String
    public var sync: String
    public var syncTone: NWGitTone
    public var canPull: Bool
    public var pullHint: String?
    public var notice: Notice?
    public var changes: Changes?
    public var incoming: Incoming?
    /// A primary button ("Retry push", "Push") under the notice when commits wait to go up; nil hides it.
    public var pushTitle: String?
    /// A git action is running: every button is disabled.
    public var working: Bool

    public init(branch: String, repository: String, sync: String, syncTone: NWGitTone, canPull: Bool, pullHint: String?, notice: Notice?,
                changes: Changes?, incoming: Incoming?, pushTitle: String?, working: Bool) {
        self.branch = branch
        self.repository = repository
        self.sync = sync
        self.syncTone = syncTone
        self.canPull = canPull
        self.pullHint = pullHint
        self.notice = notice
        self.changes = changes
        self.incoming = incoming
        self.pushTitle = pushTitle
        self.working = working
    }
}

/// The Git panel under the chip (GitDesignChanges; Git 4 and, in merge mode, Git 7).
public struct NWGitPanel: View {
    let state: NWGitPanelState
    @Binding var message: String
    let maxHeight: CGFloat
    let close: () -> Void
    let pull: () -> Void
    let select: (String) -> Void
    let commit: (Bool) -> Void
    let push: () -> Void
    let copyURL: () -> Void

    public init(state: NWGitPanelState, message: Binding<String>, maxHeight: CGFloat = .infinity, close: @escaping () -> Void,
                pull: @escaping () -> Void, select: @escaping (String) -> Void, commit: @escaping (_ push: Bool) -> Void,
                push: @escaping () -> Void, copyURL: @escaping () -> Void) {
        self.state = state
        _message = message
        self.maxHeight = maxHeight
        self.close = close
        self.pull = pull
        self.select = select
        self.commit = commit
        self.push = push
        self.copyURL = copyURL
    }

    public var body: some View {
        // Whole when it fits, else its middle scrolls between the header and the footer.
        Group {
            if maxHeight.isFinite {
                ViewThatFits(in: .vertical) {
                    card(scrolling: false)
                    card(scrolling: true)
                }
                .frame(maxHeight: maxHeight)
            } else {
                card(scrolling: false)
            }
        }
        .frame(width: M.panelWidth)
        .nwPopover(radius: NW.Radius.l)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Git changes for this design")
    }

    private func card(scrolling: Bool) -> some View {
        VStack(spacing: 0) {
            header
            if scrolling {
                ScrollView { content }
            } else {
                content
            }
            footer
        }
    }

    private var header: some View {
        HStack(spacing: NW.Space.m) {
            Image(systemName: NWGlyph.gitBranch.symbolName).font(.system(size: M.panelGlyph, weight: .medium))
                .foregroundStyle(Color.nw.textSecondary).accessibilityHidden(true)
            Text(state.branch).font(.nw(.code)).fontWeight(.semibold).lineLimit(1)
            Text(state.repository).font(.nw(.caption)).foregroundStyle(Color.nw.textSecondary).lineLimit(1)
            Spacer(minLength: NW.Space.m)
            GitClose(label: "Close Git changes", glyph: M.closeGlyph, action: close)
        }
        .padding(NW.Space.xl)
        .overlay(alignment: .bottom) { NWHairline() }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: NW.Space.xl) {
            HStack(spacing: NW.Space.l) {
                Text(state.sync).font(.nw(.ui)).foregroundStyle(state.syncTone.color).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Pull", action: pull).buttonStyle(.nw(.secondary, size: .m))
                    .disabled(!state.canPull || state.working)
                    .help(state.pullHint ?? "")
            }
            if let notice = state.notice {
                VStack(alignment: .leading, spacing: NW.Space.s) {
                    Text(notice.title).font(.nw(.ui)).foregroundStyle(notice.tone.color)
                    Text(notice.text).nwText(.caption).foregroundStyle(Color.nw.textSecondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .gitBox(padding: EdgeInsets(top: NW.Space.l, leading: NW.Space.l, bottom: NW.Space.l, trailing: NW.Space.l))
                .accessibilityElement(children: .combine)
            }
            if let changes = state.changes { changesSection(changes) }
            if let incoming = state.incoming { incomingSection(incoming) }
            if let pushTitle = state.pushTitle {
                HStack {
                    Spacer(minLength: 0)
                    Button(pushTitle, action: push).buttonStyle(.nw(.primary, size: .l)).disabled(state.working)
                }
            }
            Text("Git only shares what you commit and push. Shepherd never pushes automatically.")
                .nwText(.caption).foregroundStyle(Color.nw.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(NW.Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: NW.Space.m) {
            Button("Copy repository URL", action: copyURL).buttonStyle(.nw(.ghost, size: .m))
            Spacer(minLength: 0)
            Text("Managed by Shepherd").font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
        }
        .padding(.vertical, NW.Space.l).padding(.horizontal, NW.Space.xl)
        .overlay(alignment: .top) { NWHairline() }
    }

    private func changesSection(_ changes: NWGitPanelState.Changes) -> some View {
        VStack(alignment: .leading, spacing: NW.Space.xl) {
            VStack(alignment: .leading, spacing: NW.Space.m) {
                HStack {
                    Text(changes.title).font(.nw(.headline)).accessibilityAddTraits(.isHeader)
                    Spacer(minLength: NW.Space.m)
                    Text(changes.files.count == 1 ? "1 file" : "\(changes.files.count) files")
                        .font(.nw(.mono)).foregroundStyle(Color.nw.textSecondary)
                }
                Text(changes.note).nwText(.caption).foregroundStyle(Color.nw.textSecondary).fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 0) {
                    ForEach(Array(changes.files.enumerated()), id: \.element.id) { index, file in
                        if index > 0 { NWHairline() }
                        fileRow(file, selected: file.id == changes.selected)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: NW.Radius.m))
                .nwCard(radius: NW.Radius.m, fill: Color.nw.bgWindow)
            }
            if let preview = changes.preview { previewBox(preview) }
            VStack(alignment: .leading, spacing: NW.Space.s) {
                Text("Commit message").font(.nw(.ui))
                let shape = RoundedRectangle(cornerRadius: NW.Radius.m)
                TextField("", text: $message, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.nw(.body))
                    .lineLimit(M.commitLines, reservesSpace: true)
                    .padding(NW.Space.l)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(Color.nw.bgSunken, in: shape)
                    .nwBorder(Color.nw.lineStrong, in: shape)
                    .disabled(state.working)
                    .accessibilityLabel("Commit message")
            }
            HStack(spacing: NW.Space.m) {
                Spacer(minLength: 0)
                Button(changes.localTitle) { commit(false) }.buttonStyle(.nw(.secondary, size: .l))
                    .disabled(!changes.canCommit || state.working)
                Button(changes.pushTitle) { commit(true) }.buttonStyle(.nw(.primary, size: .l))
                    .disabled(!changes.canPush || state.working)
            }
        }
    }

    private func fileRow(_ file: NWGitPanelState.File, selected: Bool) -> some View {
        Button { select(file.id) } label: {
            HStack(spacing: NW.Space.l) {
                Text(file.letter).font(.nw(.micro)).foregroundStyle(AgentState.attention.textColor)
                Text(file.id).font(.nw(.code)).foregroundStyle(Color.nw.textPrimary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: NW.Space.m)
                Text(file.label).font(.nw(.caption)).foregroundStyle(Color.nw.textSecondary).lineLimit(1)
            }
            .padding(.horizontal, NW.Space.l)
            .frame(maxWidth: .infinity, minHeight: M.rowHeight, alignment: .leading)
            .background(selected ? Color.nw.bgSelected : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(file.id), \(file.label)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func previewBox(_ preview: NWGitPanelState.Preview) -> some View {
        VStack(spacing: 0) {
            Text(preview.title).font(.nw(.caption)).foregroundStyle(Color.nw.textSecondary)
                .padding(.vertical, NW.Space.m).padding(.horizontal, NW.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) { NWHairline() }
            HStack(spacing: 0) {
                previewColumn(preview.beforeTitle, preview.before, fill: nil)
                    .overlay(alignment: .trailing) { NWHairline(.vertical) }
                previewColumn(preview.afterTitle, preview.after, fill: AgentState.done.tint)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .clipShape(RoundedRectangle(cornerRadius: NW.Radius.m))
        .nwCard(radius: NW.Radius.m, fill: Color.nw.bgWindow)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Selected change preview")
    }

    private func previewColumn(_ title: String, _ text: String, fill: Color?) -> some View {
        VStack(alignment: .leading, spacing: NW.Space.m) {
            Text(title).font(.nw(.caption)).foregroundStyle(Color.nw.textSecondary)
            Text(text).nwText(.body)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(NW.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(fill ?? Color.clear)
    }

    private func incomingSection(_ incoming: NWGitPanelState.Incoming) -> some View {
        VStack(alignment: .leading, spacing: NW.Space.l) {
            Text("Incoming update").font(.nw(.headline)).accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: NW.Space.m) {
                Text(incoming.subject).nwText(.body)
                (Text("\(incoming.author) · ") + Text(incoming.hash).font(.nw(.mono)))
                    .font(.nw(.caption)).foregroundStyle(Color.nw.textSecondary)
                ForEach(incoming.files, id: \.self) { Text($0).font(.nw(.mono)).foregroundStyle(Color.nw.textSecondary) }
            }
            .fixedSize(horizontal: false, vertical: true)
            .gitBox(padding: EdgeInsets(top: NW.Space.xl, leading: NW.Space.xl, bottom: NW.Space.xl, trailing: NW.Space.xl))
            Text("Pull updates the design files and reloads the canvas. Your agent chat stays on this Mac.")
                .nwText(.caption).foregroundStyle(Color.nw.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: Merge dialog

public struct NWGitMergeCommit: Equatable, Sendable {
    public var subject: String
    public var author: String
    public var hash: String
    public var files: [String]
    public init(subject: String, author: String, hash: String, files: [String]) {
        self.subject = subject
        self.author = author
        self.hash = hash
        self.files = files
    }
}

/// Pull needs a merge (Git 5, GitDesignConflict's dialog).
public struct NWGitMergeDialog: View {
    let branch: String
    let upstream: String
    let local: NWGitMergeCommit
    let incoming: NWGitMergeCommit
    let keepLocal: () -> Void
    let resolve: () -> Void

    public init(branch: String, upstream: String, local: NWGitMergeCommit, incoming: NWGitMergeCommit,
                keepLocal: @escaping () -> Void, resolve: @escaping () -> Void) {
        self.branch = branch
        self.upstream = upstream
        self.local = local
        self.incoming = incoming
        self.keepLocal = keepLocal
        self.resolve = resolve
    }

    private func mono(_ text: String) -> Text { Text(text).font(.nwMono(M.bodyMono)) }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: NW.Space.l) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: M.headerGlyph, weight: .medium))
                    .foregroundStyle(AgentState.attention.textColor).accessibilityHidden(true)
                Text("Pull needs a merge").font(.nw(.title)).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
            }
            .padding(.vertical, NW.Space.xl).padding(.horizontal, NW.Space.xxl)
            .overlay(alignment: .bottom) { NWHairline() }
            VStack(alignment: .leading, spacing: NW.Space.xl) {
                (Text("Your ") + mono(branch) + Text(" and ") + mono(upstream)
                    + Text(" each have a new commit. Shepherd has not changed your design files."))
                    .nwText(.body).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: NW.Space.l) {
                    commitCard("Your local commit", local)
                    commitCard("Incoming commit", incoming)
                }
                .fixedSize(horizontal: false, vertical: true)
                Text("Let your design agent combine both versions and check the result. Shepherd manages the merge without moving your design.")
                    .nwText(.body).foregroundStyle(Color.nw.textSecondary).fixedSize(horizontal: false, vertical: true)
                Text("The agent uses a merge copy and your current model and limits. Both original commits stay available. No commit or push without you.")
                    .nwText(.caption).foregroundStyle(Color.nw.textSecondary).fixedSize(horizontal: false, vertical: true)
                    .gitBox(padding: EdgeInsets(top: NW.Space.l, leading: NW.Space.xl, bottom: NW.Space.l, trailing: NW.Space.xl))
            }
            .padding(NW.Space.xxl)
            HStack(spacing: NW.Space.m) {
                Button("Keep working locally", action: keepLocal).buttonStyle(.nw(.ghost, size: .l)).keyboardShortcut(.cancelAction)
                Spacer(minLength: NW.Space.m)
                Button("Resolve with agent", systemImage: "pencil.tip", action: resolve)
                    .buttonStyle(.nw(.primary, size: .l)).keyboardShortcut(.defaultAction)
            }
            .padding(.vertical, NW.Space.xl).padding(.horizontal, NW.Space.xxl)
            .overlay(alignment: .top) { NWHairline() }
        }
        .frame(width: M.dialogWidth)
        .nwPopover(radius: NW.Radius.l)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private func commitCard(_ title: String, _ commit: NWGitMergeCommit) -> some View {
        VStack(alignment: .leading, spacing: NW.Space.m) {
            Text(title).font(.nw(.headline))
            Text(commit.subject).nwText(.body)
            (Text("\(commit.author) · ") + Text(commit.hash).font(.nw(.mono)))
                .font(.nw(.caption)).foregroundStyle(Color.nw.textSecondary)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(commit.files, id: \.self) { Text($0).font(.nw(.mono)).foregroundStyle(Color.nw.textSecondary) }
            }
            .padding(.top, NW.Space.m)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(NW.Space.xl)
        .nwCard(radius: NW.Radius.m, fill: Color.nw.bgWindow)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Chat

public enum NWGitMergePhase: Equatable, Sendable { case running, ready, stopped, failed(String?) }

/// The merge's card in the design chat (Git 6/7; GitDesignShell's agentCopy).
public struct NWGitMergeCard: View, Equatable {
    let phase: NWGitMergePhase
    let review: (() -> Void)?
    let retry: (() -> Void)?

    public init(phase: NWGitMergePhase, review: (() -> Void)? = nil, retry: (() -> Void)? = nil) {
        self.phase = phase
        self.review = review
        self.retry = retry
    }

    public nonisolated static func == (a: Self, b: Self) -> Bool { a.phase == b.phase }

    private var title: String {
        switch phase {
        case .running: "Resolving the merge"
        case .ready: "Merge ready to review"
        case .stopped: "Merge stopped"
        case .failed: "Couldn't finish the merge"
        }
    }

    private var line: String? {
        switch phase {
        case .running, .ready: nil
        case .stopped: "Your original design and both commits are still available. The merge copy was not applied."
        case .failed(let reason): reason
        }
    }

    private var note: String {
        switch phase {
        case .running: "One merge attempt, within your current agent limits. You can stop it. Nothing will commit or push automatically."
        case .ready: "Review the local changes before creating the merge commit. Nothing has been committed or pushed."
        case .stopped: "Nothing was committed or pushed. The agent will not retry unless you ask."
        case .failed: "Review the attempt in this chat, then ask the agent to try again. Nothing was committed or pushed."
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: M.introSpacing) {
            Text(title).font(.nw(.title)).accessibilityAddTraits(.isHeader)
            if let line { Text(line).nwText(.body).foregroundStyle(Color.nw.textSecondary).fixedSize(horizontal: false, vertical: true) }
            Text(note).nwText(.caption).foregroundStyle(Color.nw.textSecondary).fixedSize(horizontal: false, vertical: true)
            switch phase {
            case .ready:
                if let review { Button("Review merge", action: review).buttonStyle(.nw(.secondary, size: .l)) }
            case .stopped, .failed:
                if let retry { Button("Try again with agent", action: retry).buttonStyle(.nw(.secondary, size: .l)) }
            case .running:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

/// The design chat before anything is said in a design opened from Git (GitDesignShell, agentCopy.none).
public struct NWGitDesignIntro: View {
    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: M.introSpacing) {
            Text("Your design agent").font(.nw(.title)).accessibilityAddTraits(.isHeader)
            Text("The design is open. Ask for a change when you're ready. No agent has started.")
                .nwText(.body).foregroundStyle(Color.nw.textSecondary)
            Text("The original conversation stays on its author's Mac. Your agent reads the current boards, design system and pinned comments when you send a message.")
                .nwText(.caption).foregroundStyle(Color.nw.textSecondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(NW.Space.xxl)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Canvas notice

/// A notice on the canvas: opened from Git (the toast) or a paused pull.
public struct NWGitCanvasNotice: View {
    public enum Kind: Sendable { case opened, paused }

    let kind: Kind
    let title: String
    let detail: String
    let dismiss: (() -> Void)?

    public init(_ kind: Kind, title: String, detail: String, dismiss: (() -> Void)? = nil) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.dismiss = dismiss
    }

    public var body: some View {
        HStack(spacing: M.noticeSpacing) {
            if kind == .opened {
                Image(systemName: "checkmark").font(.system(size: M.noticeGlyph, weight: .medium))
                    .foregroundStyle(AgentState.done.color).accessibilityHidden(true)
            }
            (Text(title).foregroundStyle(kind == .paused ? AgentState.attention.textColor : Color.nw.textPrimary)
                + Text("  ") + Text(detail).foregroundStyle(Color.nw.textSecondary))
                .nwText(.body)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let dismiss {
                Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: M.dismissGlyph, weight: .medium)) }
                    .buttonStyle(.nwIcon(size: NW.Height.controlS))
                    .help("Dismiss")
                    .accessibilityLabel("Dismiss")
            }
        }
        .padding(.vertical, NW.Space.l).padding(.horizontal, NW.Space.xl)
        .frame(maxWidth: M.noticeMaxWidth)
        .fixedSize(horizontal: false, vertical: true)
        .nwPopover(radius: NW.Radius.l)
        .accessibilityElement(children: .combine)
    }
}
