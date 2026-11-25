import SwiftUI

// Git sharing for designs (GitDesignPublish, GitDesignOpen, GitDesignCoworker, GitDesignChanges,
// GitDesignConflict, GitDesignMerge, GitDesignMergeReview, GitDesignMergeFailed).
// Everything here takes its words and state as values: nothing runs git.

/// The boards' own measures for the Git surfaces.
public enum SHGitMetrics {
    // The toolbar chip (.gdz-chip)
    public static let chipHeight: CGFloat = 28
    public static let chipPadding: CGFloat = 9
    public static let chipSpacing: CGFloat = 6
    public static let chipGlyph: CGFloat = 13
    public static let chipChevron: CGFloat = 9
    // Sheets (.gdz-sheet)
    public static let shareWidth: CGFloat = 540
    public static let openWidth: CGFloat = 500
    public static let dialogWidth: CGFloat = 620
    public static let sheetRadius: CGFloat = 16
    public static let sheetPaddingTop: CGFloat = 18
    public static let sheetPaddingHorizontal: CGFloat = 20
    public static let sheetPaddingBottom: CGFloat = 16
    public static let titleSize: CGFloat = 15
    public static let closeSize: CGFloat = 24
    public static let closeGlyph: CGFloat = 11
    public static let messageTop: CGFloat = 8
    public static let labelTop: CGFloat = 16
    public static let labelGap: CGFloat = 6
    public static let captionTop: CGFloat = 6
    public static let fieldHeight: CGFloat = 32
    public static let fieldPadding: CGFloat = 10
    public static let rowHeight: CGFloat = 34
    public static let noteTop: CGFloat = 8
    public static let footerTop: CGFloat = 18
    public static let footerSpacing: CGFloat = 18
    public static let linkSize: CGFloat = 13
    // The panel (.gdz-gp)
    public static let panelWidth: CGFloat = 470
    public static let panelRadius: CGFloat = 14
    public static let panelHeaderHeight: CGFloat = 46
    public static let panelHeaderLeading: CGFloat = 16
    public static let panelHeaderTrailing: CGFloat = 8
    public static let panelPaddingTop: CGFloat = 12
    public static let panelPaddingHorizontal: CGFloat = 16
    public static let panelPaddingBottom: CGFloat = 14
    public static let panelFooterHeight: CGFloat = 40
    public static let syncHeight: CGFloat = 28
    public static let boxTop: CGFloat = 10
    public static let boxRadius: CGFloat = 10
    public static let boxPaddingVertical: CGFloat = 10
    public static let boxPaddingHorizontal: CGFloat = 12
    public static let sectionTop: CGFloat = 14
    public static let fileRowHeight: CGFloat = 30
    public static let fileRowSpacing: CGFloat = 10
    /// A selected file's wash reaches this far past the panel's text on each side.
    public static let fileRowInset: CGFloat = 8
    public static let fileLetter: CGFloat = 12
    public static let compareRadius: CGFloat = 10
    public static let compareTitlePaddingVertical: CGFloat = 7
    public static let compareColumnPaddingTop: CGFloat = 8
    public static let compareColumnPaddingBottom: CGFloat = 10
    public static let actionsTop: CGFloat = 12
    public static let actionsSpacing: CGFloat = 16
    /// The panel's least height in a short window (it scrolls inside).
    public static let panelMinHeight: CGFloat = 240
    public static let commitLines = 3
    // The merge dialog's two commits (.gdz-cmt2)
    public static let commitSpacing: CGFloat = 10
    public static let commitPaddingVertical: CGFloat = 10
    public static let commitTop: CGFloat = 14
    // The merge card in the chat (.gdz-mg)
    public static let cardRadius: CGFloat = 12
    public static let cardPaddingTop: CGFloat = 11
    public static let cardPaddingBottom: CGFloat = 12
    public static let cardPaddingHorizontal: CGFloat = 12
    public static let cardTop: CGFloat = 14
    // The canvas notices (.gdz-notice)
    public static let noticeHeight: CGFloat = 36
    public static let noticeSpacing: CGFloat = 10
    public static let noticePaddingLeading: CGFloat = 14
    public static let noticePaddingTrailing: CGFloat = 6
    public static let noticeClose: CGFloat = 24
    public static let dismissGlyph: CGFloat = 10
    /// The notices stand this far under the canvas's top edge.
    public static let noticeTop: CGFloat = 14
    // The design agent's intro (.gdz-h, .gdz-p)
    public static let introTitleSize: CGFloat = 14
    public static let introSpacing: CGFloat = 10
}

public enum SHGitTone: Sendable, Equatable { case primary, done, running, attention, secondary }

extension SHGitTone {
    /// The words a state is said in: amber when it needs the person, else `textSecondary` (the boards' `.t2`).
    @MainActor var color: Color {
        switch self {
        case .attention: Color.sh.lanternText
        case .primary, .done, .running, .secondary: Color.sh.textSecondary
        }
    }
}

private typealias M = SHGitMetrics

// MARK: Chip

/// The design toolbar's Git chip (DesignGitStatus): "Share with Git", "main  Up to date", "main  3 changes" … The
/// branch in mono, its state after it in `textSecondary`, amber when it needs the person.
public struct SHDesignGitChip: View, Equatable {
    let label: String
    let tone: SHGitTone
    let hint: String
    let isOpen: Bool
    let action: () -> Void
    /// The label as "branch · state": the branch and the state, split once.
    private let branch: String?
    private let state: String

    public init(label: String, tone: SHGitTone, hint: String, isOpen: Bool = false, action: @escaping () -> Void) {
        self.label = label
        self.tone = tone
        self.hint = hint
        self.isOpen = isOpen
        self.action = action
        if let range = label.range(of: " · ") {
            branch = String(label[..<range.lowerBound])
            state = String(label[range.upperBound...])
        } else {
            branch = nil
            state = label
        }
    }

    public nonisolated static func == (a: Self, b: Self) -> Bool {
        a.label == b.label && a.tone == b.tone && a.hint == b.hint && a.isOpen == b.isOpen
    }

    public var body: some View {
        let sh = Color.sh
        let shape = RoundedRectangle(cornerRadius: SH.Radius.s)
        let amber = tone == .attention
        Button(action: action) {
            HStack(spacing: M.chipSpacing) {
                Image(systemName: SHGlyph.gitBranch.symbolName).font(.system(size: M.chipGlyph))
                    .foregroundStyle(sh.textSecondary)
                    .accessibilityHidden(true)
                if let branch {
                    Text(branch).font(.sh(.mono)).foregroundStyle(amber ? tone.color : sh.textPrimary).lineLimit(1)
                    Text(state).font(.sh(.ui)).foregroundStyle(tone.color).lineLimit(1)
                } else {
                    Text(state).font(.sh(.ui)).foregroundStyle(amber ? tone.color : sh.textPrimary).lineLimit(1)
                }
                Image(systemName: "chevron.down").font(.system(size: M.chipChevron, weight: .medium)).foregroundStyle(sh.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, M.chipPadding)
            .frame(height: M.chipHeight)
            .background(isOpen ? sh.bgSelected : .clear, in: shape)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(hint)
        .accessibilityLabel("\(label). \(hint)")
    }
}

// MARK: Shared pieces

/// The close x at a sheet's or panel's corner: bare, in `textTertiary`.
private struct GitClose: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: "xmark").font(.system(size: M.closeGlyph)) }
            .buttonStyle(.shIcon(size: M.closeSize))
            .help(label)
            .accessibilityLabel(label)
    }
}

/// A sheet's title and close (.gdz-sheet h2), then what it holds on the raised fill at radius 16.
private struct GitSheetFrame<Content: View>: View {
    let width: CGFloat
    let title: String
    let closeLabel: String
    let close: (() -> Void)?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: SH.Space.m) {
                Text(title).font(.shSans(M.titleSize, .semibold)).foregroundStyle(Color.sh.textPrimary).accessibilityAddTraits(.isHeader)
                Spacer(minLength: SH.Space.m)
                if let close { GitClose(label: closeLabel, action: close) }
            }
            content()
        }
        .padding(EdgeInsets(top: M.sheetPaddingTop, leading: M.sheetPaddingHorizontal, bottom: M.sheetPaddingBottom,
                            trailing: M.sheetPaddingHorizontal))
        .frame(width: width)
        .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: M.sheetRadius))
        .shPopover(radius: M.sheetRadius)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isModal)
    }
}

/// A sheet's last line (.sf): what it does not do, Cancel as a quiet word and the one action as the ink pill.
private struct GitFooter<Leading: View>: View {
    let cancelTitle: String
    let cancel: () -> Void
    let actionTitle: String
    let action: () -> Void
    let enabled: Bool
    @ViewBuilder let leading: () -> Leading

    var body: some View {
        HStack(spacing: M.footerSpacing) {
            Spacer(minLength: 0)
            leading()
            Button(cancelTitle, action: cancel)
                .buttonStyle(.shLink(color: Color.sh.textSecondary, font: .sh(.ui)))
                .keyboardShortcut(.cancelAction)
            Button(actionTitle, action: action)
                .buttonStyle(SHPillButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!enabled)
        }
        .padding(.top, M.footerTop)
    }
}

/// A labelled 32pt field (.fl, .fld, .cap2): the label in `textSecondary`, the field on the raised fill with a line, its caption under it.
private struct GitField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var mono = false
    var caption: String?
    var enabled = true
    var submit: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.sh(.caption)).foregroundStyle(Color.sh.textSecondary)
            let shape = RoundedRectangle(cornerRadius: SH.Radius.m)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(mono ? .sh(.mono) : .sh(.ui))
                .foregroundStyle(Color.sh.textPrimary)
                .autocorrectionDisabled()
                .padding(.horizontal, M.fieldPadding)
                .frame(minHeight: M.fieldHeight)
                .background(Color.sh.bgRaised, in: shape)
                .shBorder(Color.sh.lineStrong, in: shape)
                // The app's focus ring, for keyboard focus only (as `SHLeadFieldStyle` draws it).
                .shFocusRing(radius: SH.Radius.m)
                .disabled(!enabled)
                .shEnabledOpacity(enabled)
                .onSubmit(submit)
                .accessibilityLabel(title)
                .padding(.top, M.labelGap)
            if let caption {
                Text(caption).shText(.caption).foregroundStyle(Color.sh.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, M.captionTop)
            }
        }
        .padding(.top, M.labelTop)
    }
}

private struct GitErrorBox: View {
    let error: SHGitSheetError

    var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.xxs) {
            Text(error.title).font(.sh(.ui, weight: .semibold)).foregroundStyle(AgentState.failed.textColor)
            Text(error.detail).shText(.caption).foregroundStyle(Color.sh.textSecondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, M.boxPaddingVertical)
        .padding(.horizontal, M.boxPaddingHorizontal)
        .background(AgentState.failed.tint ?? Color.clear, in: RoundedRectangle(cornerRadius: M.boxRadius))
        .padding(.top, M.labelTop)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
        // The board's role=alert: VoiceOver reads it as it appears.
        .onAppear { AccessibilityNotification.Announcement("\(error.title). \(error.detail)").post() }
    }
}

/// A faint box inside a panel or card: the board's `--mac-hover` wash at radius 10.
private extension View {
    func gitWash() -> some View {
        padding(.vertical, M.boxPaddingVertical).padding(.horizontal, M.boxPaddingHorizontal)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.sh.bgHover, in: RoundedRectangle(cornerRadius: M.boxRadius))
    }

    /// A box with a line (.gdz-cmt2 > div, .gdz-cc).
    func gitOutlined(radius: CGFloat) -> some View {
        shBorder(Color.sh.lineStrong, in: RoundedRectangle(cornerRadius: radius))
    }
}

public struct SHGitSheetError: Equatable, Sendable {
    public var title: String
    public var detail: String
    public init(title: String, detail: String) {
        self.title = title
        self.detail = detail
    }
}

// MARK: Share sheet

/// Share with Git (Git 1, GitDesignPublish).
public struct SHGitShareSheet: View {
    @Binding var repository: String
    @Binding var message: String
    let boards: Int
    let error: SHGitSheetError?
    let working: Bool
    let close: () -> Void
    let share: () -> Void

    public init(repository: Binding<String>, message: Binding<String>, boards: Int, error: SHGitSheetError?, working: Bool,
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
        GitSheetFrame(width: M.shareWidth, title: "Share with Git", closeLabel: "Close share dialog", close: close) {
            // Whole when it fits; in a short window (or at a large text size) the middle scrolls
            // between the header and the buttons, which stay in reach.
            ViewThatFits(in: .vertical) {
                shareBody
                ScrollView { shareBody }
            }
            GitFooter(cancelTitle: "Cancel", cancel: close, actionTitle: working ? "Sharing…" : "Create commit & push", action: share,
                      enabled: canShare) { EmptyView() }
        }
    }

    private var shareBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Share this design through a Git repository. Your coworkers can open the same canvas in Shepherd. Shepherd manages the local copy for everyone.")
                .shText(.ui).foregroundStyle(Color.sh.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, M.messageTop)
            GitField(title: "Repository URL", placeholder: "SSH or HTTPS Git URL", text: $repository, mono: true,
                     caption: "Use an empty repository you already have access to, on any Git host.", enabled: !working, submit: submitIfValid)
            included
            GitField(title: "First commit", placeholder: "Commit message", text: $message,
                     caption: "Your design stays in Shepherd’s storage. Changes save locally and are shared only when you commit and push.",
                     enabled: !working, submit: submitIfValid)
            if let error { GitErrorBox(error: error) }
        }
    }

    private func submitIfValid() { if canShare { share() } }

    private var included: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("What goes in the repository").font(.sh(.ui, weight: .semibold)).foregroundStyle(Color.sh.textPrimary)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, M.labelGap)
            VStack(spacing: 0) {
                SHHairline()
                includedRow("Canvas, pages, notes and every board", trailing: boards == 1 ? "1 board" : "\(boards) boards")
                includedRow("Shared pieces, design system and local assets", trailing: nil)
                includedRow("Pinned comments and replies", trailing: nil)
            }
            Text("Agent chat, credentials, caches and your local viewing state stay on this Mac. Review the design files for private content before sharing.")
                .shText(.caption).foregroundStyle(Color.sh.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, M.noteTop)
        }
        .padding(.top, M.labelTop)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("What will be shared")
    }

    private func includedRow(_ text: String, trailing: String?) -> some View {
        HStack(spacing: M.fileRowSpacing) {
            Text(text).font(.sh(.ui)).foregroundStyle(Color.sh.textPrimary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: SH.Space.m)
            if let trailing { Text(trailing).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary) }
        }
        .frame(minHeight: M.rowHeight)
        .overlay(alignment: .bottom) { SHHairline() }
    }
}

// MARK: Open sheet

/// Open from Git (Git 2, GitDesignOpen).
public struct SHGitOpenSheet: View {
    @Binding var repository: String
    let error: SHGitSheetError?
    let working: Bool
    let close: () -> Void
    let clone: () -> Void

    public init(repository: Binding<String>, error: SHGitSheetError?, working: Bool, close: @escaping () -> Void, clone: @escaping () -> Void) {
        _repository = repository
        self.error = error
        self.working = working
        self.close = close
        self.clone = clone
    }

    private var canClone: Bool { !working && !repository.trimmingCharacters(in: .whitespaces).isEmpty }

    public var body: some View {
        GitSheetFrame(width: M.openWidth, title: "Open from Git", closeLabel: "Close dialog", close: close) {
            Text("Open a shared design from its repository URL. Shepherd clones it into its own storage and adds it to Designs. Opening does not start an agent.")
                .shText(.ui).foregroundStyle(Color.sh.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, M.messageTop)
            GitField(title: "Repository URL", placeholder: "SSH or HTTPS Git URL", text: $repository, mono: true,
                     caption: "Uses your configured Git credentials. No folder setup needed.", enabled: !working,
                     submit: { if canClone { clone() } })
            if let error { GitErrorBox(error: error) }
            GitFooter(cancelTitle: "Cancel", cancel: close, actionTitle: working ? "Cloning…" : error != nil ? "Retry clone" : "Clone & open",
                      action: clone, enabled: canClone) { EmptyView() }
        }
    }
}

// MARK: Panel

public struct SHGitPanelState: Equatable, Sendable {
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
        public var tone: SHGitTone
        public init(title: String, text: String, tone: SHGitTone) {
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
    public var syncTone: SHGitTone
    public var canPull: Bool
    public var pullHint: String?
    public var notice: Notice?
    public var changes: Changes?
    public var incoming: Incoming?
    /// A primary button ("Retry push", "Push") under the notice when commits wait to go up; nil hides it.
    public var pushTitle: String?
    /// A git action is running: every button is disabled.
    public var working: Bool

    public init(branch: String, repository: String, sync: String, syncTone: SHGitTone, canPull: Bool, pullHint: String?, notice: Notice?,
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

/// The Git panel under the chip (GitDesignChanges; Git 4 and, in merge mode, Git 7): 470pt at radius 14.
public struct SHGitPanel: View {
    let state: SHGitPanelState
    @Binding var message: String
    let maxHeight: CGFloat
    let close: () -> Void
    let pull: () -> Void
    let select: (String) -> Void
    let commit: (Bool) -> Void
    let push: () -> Void
    let copyURL: () -> Void

    public init(state: SHGitPanelState, message: Binding<String>, maxHeight: CGFloat = .infinity, close: @escaping () -> Void,
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
                // Its own height when that fits (the board's card hugs its content), else capped.
                ViewThatFits(in: .vertical) {
                    card(scrolling: false)
                    card(scrolling: true)
                }
                .frame(maxHeight: maxHeight)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                card(scrolling: false)
            }
        }
        .frame(width: M.panelWidth)
        .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: M.panelRadius))
        .shPopover(radius: M.panelRadius)
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
        let sh = Color.sh
        return HStack(spacing: SH.Space.m) {
            Image(systemName: SHGlyph.gitBranch.symbolName).font(.system(size: M.chipGlyph))
                .foregroundStyle(sh.textPrimary).accessibilityHidden(true)
            Text(state.branch).font(.sh(.code, weight: .semibold)).foregroundStyle(sh.textPrimary).lineLimit(1)
            Text(state.repository).font(.sh(.ui)).foregroundStyle(sh.textTertiary).lineLimit(1)
            Spacer(minLength: SH.Space.m)
            GitClose(label: "Close Git changes", action: close)
        }
        .padding(.leading, M.panelHeaderLeading)
        .padding(.trailing, M.panelHeaderTrailing)
        .frame(height: M.panelHeaderHeight)
        .overlay(alignment: .bottom) { SHHairline() }
    }

    private var content: some View {
        let sh = Color.sh
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: SH.Space.l) {
                Text(state.sync).font(.sh(.ui)).foregroundStyle(state.syncTone.color).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                let canPull = state.canPull && !state.working
                Button("Pull", action: pull)
                    .buttonStyle(.shLink(color: canPull ? sh.textPrimary : sh.textTertiary, font: .sh(.ui, weight: canPull ? .medium : .regular)))
                    .disabled(!canPull)
                    .help(state.pullHint ?? "")
            }
            .frame(minHeight: M.syncHeight)
            if let notice = state.notice {
                VStack(alignment: .leading, spacing: SH.Space.xxs) {
                    Text(notice.title).font(.sh(.ui, weight: .semibold)).foregroundStyle(notice.tone == .attention ? notice.tone.color : sh.textPrimary)
                    Text(notice.text).shText(.caption).foregroundStyle(sh.textSecondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .gitWash()
                .padding(.top, M.boxTop)
                .accessibilityElement(children: .combine)
            }
            if let changes = state.changes { changesSection(changes) }
            if let incoming = state.incoming { incomingSection(incoming) }
            if let pushTitle = state.pushTitle {
                HStack {
                    Spacer(minLength: 0)
                    Button(pushTitle, action: push).buttonStyle(SHPillButtonStyle()).disabled(state.working)
                }
                .padding(.top, M.actionsTop)
            }
            Text("Git only shares what you commit and push. Shepherd never pushes automatically.")
                .shText(.caption).foregroundStyle(sh.textTertiary).fixedSize(horizontal: false, vertical: true)
                .padding(.top, M.boxTop)
        }
        .padding(EdgeInsets(top: M.panelPaddingTop, leading: M.panelPaddingHorizontal, bottom: M.panelPaddingBottom,
                            trailing: M.panelPaddingHorizontal))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: SH.Space.m) {
            Button("Copy repository URL", action: copyURL)
                .buttonStyle(.shLink(color: Color.sh.textSecondary, font: .sh(.caption)))
            Spacer(minLength: 0)
            Text("Managed by Shepherd").font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
        }
        .padding(.horizontal, M.panelPaddingHorizontal)
        .frame(height: M.panelFooterHeight)
        .overlay(alignment: .top) { SHHairline() }
    }

    /// A section's title with its count at the right and its line under it (.h3 and its small).
    private func sectionHeader(_ title: String, trailing: String?, note: String) -> some View {
        let sh = Color.sh
        return VStack(alignment: .leading, spacing: SH.Space.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
                Text(title).font(.sh(.ui, weight: .semibold)).foregroundStyle(sh.textPrimary).accessibilityAddTraits(.isHeader)
                Spacer(minLength: SH.Space.m)
                if let trailing { Text(trailing).font(.sh(.caption)).foregroundStyle(sh.textTertiary) }
            }
            Text(note).shText(.caption).foregroundStyle(sh.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, M.sectionTop)
    }

    private func changesSection(_ changes: SHGitPanelState.Changes) -> some View {
        let sh = Color.sh
        return VStack(alignment: .leading, spacing: 0) {
            sectionHeader(changes.title, trailing: changes.files.count == 1 ? "1 file" : "\(changes.files.count) files", note: changes.note)
            VStack(spacing: 0) {
                ForEach(changes.files) { file in
                    fileRow(file, selected: file.id == changes.selected)
                }
            }
            .padding(.top, M.noteTop)
            .padding(.horizontal, -M.fileRowInset)
            if let preview = changes.preview { previewBox(preview).padding(.top, M.noteTop) }
            Text("Commit message").font(.sh(.caption)).foregroundStyle(sh.textSecondary)
                .padding(.top, M.sectionTop).padding(.bottom, M.labelGap)
            let shape = RoundedRectangle(cornerRadius: SH.Radius.m)
            TextField("", text: $message, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.sh(.ui))
                .lineLimit(1...M.commitLines)
                .padding(.vertical, SH.Space.s)
                .padding(.horizontal, M.fieldPadding)
                .frame(minHeight: M.fieldHeight, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(sh.bgRaised, in: shape)
                .shBorder(sh.lineStrong, in: shape)
                .disabled(state.working)
                .accessibilityLabel("Commit message")
            HStack(spacing: M.actionsSpacing) {
                Spacer(minLength: 0)
                Button(changes.localTitle) { commit(false) }
                    .buttonStyle(.shLink(color: sh.textSecondary, font: .sh(.ui)))
                    .disabled(!changes.canCommit || state.working)
                Button(changes.pushTitle) { commit(true) }
                    .buttonStyle(SHPillButtonStyle())
                    .disabled(!changes.canPush || state.working)
            }
            .padding(.top, M.actionsTop)
        }
    }

    private func fileRow(_ file: SHGitPanelState.File, selected: Bool) -> some View {
        let sh = Color.sh
        return Button { select(file.id) } label: {
            HStack(spacing: M.fileRowSpacing) {
                Text(file.letter).font(.shMono(M.fileLetter)).foregroundStyle(sh.textTertiary)
                Text(file.id).font(.sh(.mono)).foregroundStyle(sh.textPrimary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: SH.Space.m)
                Text(file.label).font(.sh(.caption)).foregroundStyle(sh.textTertiary).lineLimit(1)
            }
            .padding(.horizontal, M.fileRowInset)
            .frame(maxWidth: .infinity, minHeight: M.fileRowHeight, alignment: .leading)
            .background(selected ? sh.bgSelected : Color.clear, in: RoundedRectangle(cornerRadius: SH.Radius.s))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(file.id), \(file.label)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// What the selected file said before and says now (.gdz-cmp): its name, then two columns, the new one washed green.
    private func previewBox(_ preview: SHGitPanelState.Preview) -> some View {
        let sh = Color.sh
        return VStack(spacing: 0) {
            Text(preview.title).font(.sh(.caption)).foregroundStyle(sh.textTertiary)
                .padding(.vertical, M.compareTitlePaddingVertical).padding(.horizontal, M.boxPaddingHorizontal)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) { SHHairline() }
            HStack(spacing: 0) {
                previewColumn(preview.beforeTitle, preview.before, fill: nil)
                previewColumn(preview.afterTitle, preview.after, fill: AgentState.done.tint)
                    .overlay(alignment: .leading) { SHHairline(.vertical) }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .clipShape(RoundedRectangle(cornerRadius: M.compareRadius))
        .gitOutlined(radius: M.compareRadius)
        // A named group whose texts (committed and working) VoiceOver still reads.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Selected change preview")
    }

    private func previewColumn(_ title: String, _ text: String, fill: Color?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
            Text(text).font(.sh(.ui)).foregroundStyle(Color.sh.textPrimary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, M.boxPaddingHorizontal)
        .padding(.top, M.compareColumnPaddingTop)
        .padding(.bottom, M.compareColumnPaddingBottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(fill ?? Color.clear)
    }

    private func incomingSection(_ incoming: SHGitPanelState.Incoming) -> some View {
        let sh = Color.sh
        return VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Incoming update", trailing: nil,
                          note: "Pull updates the design files and reloads the canvas. Your agent chat stays on this Mac.")
            VStack(alignment: .leading, spacing: SH.Space.xs) {
                Text(incoming.subject).font(.sh(.ui, weight: .medium)).foregroundStyle(sh.textPrimary)
                (Text("\(incoming.author) · ") + Text(incoming.hash).font(.sh(.mono)))
                    .font(.sh(.caption)).foregroundStyle(sh.textSecondary)
                ForEach(incoming.files, id: \.self) { Text($0).font(.sh(.mono)).foregroundStyle(sh.textSecondary) }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, M.boxPaddingVertical).padding(.horizontal, M.boxPaddingHorizontal)
            .frame(maxWidth: .infinity, alignment: .leading)
            .gitOutlined(radius: M.compareRadius)
            .padding(.top, M.noteTop)
        }
    }
}

// MARK: Merge dialog

public struct SHGitMergeCommit: Equatable, Sendable {
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
public struct SHGitMergeDialog: View {
    let branch: String
    let upstream: String
    let local: SHGitMergeCommit
    let incoming: SHGitMergeCommit
    let keepLocal: () -> Void
    let resolve: () -> Void
    /// Why the last attempt didn't start or finish, shown above the buttons.
    let failure: String?
    /// Drops the waiting merge (both commits stay; Pull again later). Not on the board: the way
    /// out of a merge the user won't resolve now, offered once it is waiting.
    let drop: (() -> Void)?

    public init(branch: String, upstream: String, local: SHGitMergeCommit, incoming: SHGitMergeCommit, failure: String? = nil,
                keepLocal: @escaping () -> Void, resolve: @escaping () -> Void, drop: (() -> Void)? = nil) {
        self.branch = branch
        self.upstream = upstream
        self.local = local
        self.incoming = incoming
        self.failure = failure
        self.keepLocal = keepLocal
        self.resolve = resolve
        self.drop = drop
    }

    private func mono(_ text: String) -> Text { Text(text).font(.sh(.mono)).foregroundColor(Color.sh.textPrimary) }

    public var body: some View {
        let sh = Color.sh
        GitSheetFrame(width: M.dialogWidth, title: "Pull needs a merge", closeLabel: "", close: nil) {
            (Text("Your ") + mono(branch) + Text(" and ") + mono(upstream)
                + Text(" each have a new commit. Shepherd has not changed your design files."))
                .shText(.ui).foregroundStyle(sh.textSecondary).fixedSize(horizontal: false, vertical: true)
                .padding(.top, M.messageTop)
            HStack(spacing: M.commitSpacing) {
                commitCard("Your local commit", local)
                commitCard("Incoming commit", incoming)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, M.commitTop)
            Text("Let your design agent combine both versions and check the result. Shepherd manages the merge without moving your design.")
                .shText(.ui).foregroundStyle(sh.textSecondary).fixedSize(horizontal: false, vertical: true)
                .padding(.top, M.commitTop)
            Text("The agent uses a merge copy and your current model and limits. Both original commits stay available. No commit or push without you.")
                .shText(.caption).foregroundStyle(sh.textTertiary).fixedSize(horizontal: false, vertical: true)
                .padding(.top, SH.Space.l)
            if let failure {
                GitErrorBox(error: SHGitSheetError(title: "Couldn't start the merge", detail: failure))
            }
            GitFooter(cancelTitle: "Keep working locally", cancel: keepLocal, actionTitle: "Resolve with agent", action: resolve, enabled: true) {
                if let drop {
                    Button("Drop merge", action: drop)
                        .buttonStyle(.shLink(color: sh.textTertiary, font: .sh(.ui)))
                        .help("Stop waiting on this merge. Both commits stay; pull again later.")
                }
            }
        }
    }

    private func commitCard(_ title: String, _ commit: SHGitMergeCommit) -> some View {
        let sh = Color.sh
        return VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.sh(.caption)).foregroundStyle(sh.textTertiary)
            Text(commit.subject).font(.sh(.ui, weight: .medium)).foregroundStyle(sh.textPrimary).padding(.top, SH.Space.xs)
            (Text("\(commit.author) · ") + Text(commit.hash).font(.sh(.mono)))
                .font(.sh(.caption)).foregroundStyle(sh.textSecondary).padding(.top, SH.Space.xs)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(commit.files, id: \.self) { Text($0).font(.sh(.mono)).foregroundStyle(sh.textSecondary) }
            }
            .padding(.top, M.noteTop)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.vertical, M.commitPaddingVertical)
        .padding(.horizontal, M.boxPaddingHorizontal)
        .gitOutlined(radius: M.boxRadius)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Chat

/// The merge's phase in the chat. Stopped carries why when Shepherd stopped it (its time limit).
public enum SHGitMergePhase: Equatable, Sendable { case running, ready, stopped(String? = nil), failed(String?) }

/// The merge's card in the design chat (Git 6/7; GitDesignMerge, GitDesignMergeFailed): outlined at
/// radius 12, its title in 600 (amber when it needs a look, red when it failed), its words in `textSecondary`.
public struct SHGitMergeCard: View, Equatable {
    let phase: SHGitMergePhase
    let review: (() -> Void)?
    let retry: (() -> Void)?

    public init(phase: SHGitMergePhase, review: (() -> Void)? = nil, retry: (() -> Void)? = nil) {
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

    private var titleColor: Color {
        switch phase {
        case .running: Color.sh.textPrimary
        case .ready, .stopped: Color.sh.lanternText
        case .failed: AgentState.failed.textColor
        }
    }

    private var line: String? {
        switch phase {
        case .running, .ready: nil
        case .stopped(let why): (why.map { $0 + " " } ?? "") + "Your original design and both commits are still available. The merge copy was not applied."
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
        let sh = Color.sh
        VStack(alignment: .leading, spacing: SH.Space.s) {
            // Working shimmers its title; the board's spinner is not drawn.
            Text(title).font(.sh(.ui, weight: .semibold)).foregroundStyle(titleColor).accessibilityAddTraits(.isHeader)
                .shShimmer(active: phase == .running)
            if let line { Text(line).shText(.ui).foregroundStyle(sh.textSecondary).fixedSize(horizontal: false, vertical: true) }
            Text(note).shText(.ui).foregroundStyle(sh.textSecondary).fixedSize(horizontal: false, vertical: true)
            switch phase {
            case .ready:
                if let review {
                    Button("Review merge", action: review).buttonStyle(.shLink(color: sh.textPrimary, font: .sh(.ui, weight: .medium)))
                        .padding(.top, SH.Space.xs)
                }
            case .stopped, .failed:
                if let retry {
                    Button("Try again with agent", action: retry).buttonStyle(.shLink(color: sh.textPrimary, font: .sh(.ui, weight: .medium)))
                        .padding(.top, SH.Space.xs)
                }
            case .running:
                EmptyView()
            }
        }
        .padding(EdgeInsets(top: M.cardPaddingTop, leading: M.cardPaddingHorizontal, bottom: M.cardPaddingBottom, trailing: M.cardPaddingHorizontal))
        .frame(maxWidth: .infinity, alignment: .leading)
        .gitOutlined(radius: M.cardRadius)
        .padding(.top, M.cardTop - SH.Space.l)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.updatesFrequently)
        // The board's role=status: a new phase is announced as it lands.
        .onChange(of: title, initial: false) { _, now in AccessibilityNotification.Announcement(now).post() }
    }
}

/// The design chat before anything is said in a design opened from Git (GitDesignPublish's chat):
/// "Your design agent" in 14 semibold, then two paragraphs.
public struct SHGitDesignIntro: View {
    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: M.introSpacing) {
            Text("Your design agent").font(.shSans(M.introTitleSize, .semibold)).foregroundStyle(Color.sh.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text("The design is open. Ask for a change when you’re ready. No agent has started.")
                .shText(.ui).foregroundStyle(Color.sh.textPrimary)
            Text("The original conversation stays on its author’s Mac. Your agent reads the current boards, design system and pinned comments when you send a message.")
                .shText(.ui).foregroundStyle(Color.sh.textSecondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(SH.Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Canvas notice

/// A notice on the canvas, at its top center (.gdz-notice): "Opened from Git" or "Pull paused", a
/// 36pt capsule on the raised fill, the title in 600 (amber when paused) and its detail in `textSecondary`.
public struct SHGitCanvasNotice: View {
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
        let sh = Color.sh
        HStack(spacing: M.noticeSpacing) {
            Text(title).font(.sh(.ui, weight: .semibold)).foregroundStyle(kind == .paused ? sh.lanternText : sh.textPrimary)
            Text(detail).font(.sh(.ui)).foregroundStyle(sh.textSecondary).lineLimit(1)
            if let dismiss {
                Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: M.dismissGlyph, weight: .medium)) }
                    .buttonStyle(.shIcon(size: M.noticeClose))
                    .help("Dismiss")
                    .accessibilityLabel("Dismiss")
            }
        }
        .accessibilityElement(children: .contain)
        .padding(.leading, M.noticePaddingLeading)
        .padding(.trailing, dismiss == nil ? M.noticePaddingLeading : M.noticePaddingTrailing)
        .frame(height: M.noticeHeight)
        .shCard(radius: M.noticeHeight / 2, fill: sh.bgRaised, lift: true)
        .accessibilityAddTraits(.updatesFrequently)
    }
}
