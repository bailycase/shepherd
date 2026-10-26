import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdUI

// What the Git chip, panel, merge dialog and merge card draw for a design (docs/designs.md ›
// Sharing with Git; boards GitDesignChanges and DesignGitStatus). Pure: the model passes the
// engine's state in, the views draw what comes out.
enum DesignGitPresentation {
    struct Chip: Equatable {
        var label: String
        var tone: SHGitTone
        var hint: String
    }

    static let shareHint = "Share this design through Git. Shepherd manages its local storage."
    static let statusHint = "Git status for this design. Saved locally; share by committing and pushing."

    /// The toolbar chip: "Share with Git" until the design is shared, then the branch and its one
    /// most urgent state (DesignGitStatus).
    static func chip(_ state: DesignGitState?, drawing: Bool) -> Chip {
        guard let state else { return Chip(label: "Share with Git", tone: .primary, hint: shareHint) }
        let s = state.status
        let branch = s.branch
        func chip(_ text: String, _ tone: SHGitTone) -> Chip { Chip(label: "\(branch) · \(text)", tone: tone, hint: statusHint) }
        switch state.merge?.phase {
        case .conflict?, .stopped?, .failed?: return chip("Pull paused", .attention)
        case .running?: return chip("Merging", .running)
        case .ready?: return chip("Merge ready", .attention)
        case nil: break
        }
        if s.offline { return chip("Offline", .secondary) }
        if !s.files.isEmpty { return chip(s.files.count == 1 ? "1 change" : "\(s.files.count) changes", .primary) }
        if s.behind > 0 { return chip("Pull \(s.behind)", .running) }
        if s.ahead > 0 { return chip("Push \(s.ahead)", .primary) }
        return chip("Up to date", .done)
    }

    /// A tracked path as the panel shows it: `project/A.dc.html` is `A.dc.html`.
    static func shown(_ path: String) -> String {
        path.hasPrefix("project/") ? String(path.dropFirst("project/".count)) : path
    }

    /// The trailing label of a changed file: its board's name, else what the file is.
    static func label(_ path: String, boards: [DesignPath: DesignIndex.Board]) -> String {
        let file = shown(path)
        if file == "canvas.json" { return "Board placement" }
        if file == "comments.json" { return "Pinned comments" }
        if let board = boards.first(where: { $0.key.rawValue == file })?.value { return boardName(board.title) ?? file }
        if file.hasPrefix("ds/") { return "Design system" }
        if file.hasPrefix("assets/") || file.hasPrefix("_ds/") { return "Asset" }
        return ""
    }

    /// A board's title as the panel names it: "A · Funnel first" is "Funnel first", "A · phone"
    /// is "Phone" (the letter is in the file's name beside it).
    static func boardName(_ title: String?) -> String? {
        guard let title, !title.isEmpty else { return nil }
        let name = title.components(separatedBy: " · ").dropFirst().joined(separator: " · ")
        let shown = name.isEmpty ? title : name
        return shown.prefix(1).uppercased() + shown.dropFirst()
    }

    /// The remote as the panel's header shows it: `acme/checkout-design` from either URL form.
    static func repository(_ url: String) -> String {
        var path = url
        if let range = path.range(of: "://") { path = String(path[range.upperBound...]) }
        if let colon = path.firstIndex(of: ":"), !url.contains("://") { path = String(path[path.index(after: colon)...]) }
        else if let slash = path.firstIndex(of: "/") { path = String(path[path.index(after: slash)...]) }
        if path.hasSuffix(".git") { path.removeLast(4) }
        let parts = path.split(separator: "/")
        return parts.suffix(2).joined(separator: "/")
    }

    /// The time of the last fetch, as "10:42".
    static func clock(_ ms: Double?) -> String? {
        guard let ms else { return nil }
        return Date(timeIntervalSince1970: ms / 1000).formatted(date: .omitted, time: .shortened)
    }

    struct PanelInput: Equatable {
        var state: DesignGitState
        var drawing: Bool
        var working: Bool
        var selected: String?
        var preview: SHGitPanelState.Preview?
        var boards: [DesignPath: DesignIndex.Board]
        var lastChecked: Double?
        /// The last Git action's failure, shown in the panel's notice.
        var failure: String? = nil
        /// A commit message is written: the commit buttons wait for one.
        var hasMessage = true
    }

    /// The Git panel (GitDesignChanges): one of its modes, from the engine's state.
    static func panel(_ input: PanelInput) -> SHGitPanelState {
        let s = input.state.status
        let merge = input.state.merge
        let reviewing = merge?.phase == .ready
        let drawing = input.drawing
        let failed = s.pushFailed != nil && s.ahead > 0
        let incoming = s.behind > 0 && s.isClean && merge == nil
        let sync: String
        let syncTone: SHGitTone
        if reviewing {
            sync = "Merge prepared · not committed"; syncTone = .attention
        } else if s.offline {
            sync = "Offline" + (clock(input.lastChecked ?? s.fetchedAt).map { " · last checked \($0)" } ?? ""); syncTone = .attention
        } else if failed {
            sync = s.ahead == 1 ? "1 local commit · push failed" : "\(s.ahead) local commits · push failed"; syncTone = .attention
        } else if s.behind > 0 {
            let commits = s.behind == 1 ? "1 commit to pull" : "\(s.behind) commits to pull"
            sync = s.isClean ? "\(commits) · no local changes" : commits; syncTone = .running
        } else if s.ahead > 0 {
            sync = s.ahead == 1 ? "1 local commit to push" : "\(s.ahead) local commits to push"; syncTone = .primary
        } else {
            sync = "Remote is up to date"; syncTone = .done
        }
        let canPull = incoming && !drawing && !input.working && !s.offline
        let pullHint: String = canPull ? "Pull the new commit and reload the design"
            : drawing ? "Wait for the design agent to finish this turn"
            : s.offline ? "Reconnect before pulling"
            : !s.isClean ? "Commit local changes before pulling"
            : "Nothing to pull"

        var notice: SHGitPanelState.Notice?
        if let failure = input.failure {
            notice = .init(title: "Git couldn't finish", text: failure, tone: .attention)
        } else if s.offline {
            notice = .init(title: "You can keep working offline", text: "Save or commit locally. Reconnect before pulling or pushing.", tone: .attention)
        } else if drawing {
            notice = .init(title: "Design agent is drawing",
                           text: "Commit and pull are paused until the current turn finishes, so Git doesn't capture a half-drawn design.", tone: .attention)
        } else if reviewing {
            notice = .init(title: "Agent resolved the merge",
                           text: "Boards and canvas pass the checks. The merge commit keeps both parents.", tone: .done)
        } else if failed {
            notice = .init(title: "Your commit is safe on this Mac",
                           text: "The remote could not be reached. Check your connection and Git access, then try pushing again.", tone: .attention)
        }

        var changes: SHGitPanelState.Changes?
        let files = reviewing ? input.state.mergeFiles : s.files
        if reviewing || !s.isClean {
            // Boards by name (A, then A-phone), then the canvas and the rest, as the board lists them.
            let rows = files.map { SHGitPanelState.File(id: shown($0.path), letter: $0.letter, label: label($0.path, boards: input.boards)) }
                .sorted { order($0.id) < order($1.id) }
            let blocked = drawing || input.working
            changes = .init(title: reviewing ? "Review merge" : "Local changes",
                            note: reviewing ? "Both commits are preserved. Review before committing." : "Saved on this Mac. Not shared yet.",
                            files: rows, selected: input.selected.map(shown), preview: input.preview,
                            localTitle: reviewing ? "Commit merge locally" : "Commit locally",
                            pushTitle: reviewing ? "Commit merge & push" : "Commit & push",
                            canCommit: !blocked && !rows.isEmpty && input.hasMessage,
                            canPush: !blocked && !rows.isEmpty && input.hasMessage && !s.offline)
        }
        let incomingCard = incoming ? s.incoming.map {
            SHGitPanelState.Incoming(subject: $0.subject, author: $0.author, hash: $0.hash, files: $0.files.map(shown))
        } : nil
        let push: String? = !reviewing && s.isClean && s.ahead > 0 && s.behind == 0 && !s.offline ? (failed ? "Retry push" : "Push") : nil
        return SHGitPanelState(branch: s.branch, repository: repository(s.remoteURL), sync: sync, syncTone: syncTone,
                               canPull: canPull, pullHint: pullHint, notice: notice, changes: changes, incoming: incomingCard,
                               pushTitle: push, working: input.working)
    }

    /// The merge's card in the design chat, while the merge is the agent's.
    static func mergePhase(_ merge: DesignGitMerge?) -> SHGitMergePhase? {
        switch merge?.phase {
        case .running?: .running
        case .ready?: .ready
        case .stopped?: .stopped(merge?.reason)
        case .failed?: .failed(merge?.reason)
        case .conflict?, nil: nil
        }
    }

    /// A file's place in the panel's list: boards first by their names, then everything else.
    private static func order(_ file: String) -> (Int, String) {
        file.hasSuffix(DesignPath.fileExtension) ? (0, String(file.dropLast(DesignPath.fileExtension.count))) : (1, file)
    }

    /// The merge dialog's two commits. The local one is the user's own: "You" (GitDesignConflict).
    static func commit(_ c: DesignGitStatus.Commit, local: Bool = false) -> SHGitMergeCommit {
        SHGitMergeCommit(subject: c.subject, author: local ? "You" : c.author, hash: c.hash, files: c.files.map(shown).sorted { order($0) < order($1) })
    }

    /// A one-line preview of a board's text for the panel's two columns: the first words that
    /// changed, else the file's first line of text.
    static func preview(path: String, before: String?, after: String?, boards: [DesignPath: DesignIndex.Board], merge: Bool) -> SHGitPanelState.Preview {
        // The board's own title ("A · Funnel first"), else the file.
        let board = boards.first { $0.key.rawValue == shown(path) }?.value.title
        let (a, b) = firstDifference(before ?? "", after ?? "")
        return SHGitPanelState.Preview(title: board ?? shown(path),
                                       beforeTitle: merge ? "Your version" : "Committed", before: before == nil ? "New file" : a,
                                       afterTitle: merge ? "Merge result" : "Working copy", after: after == nil ? "Deleted" : b)
    }

    /// The first piece of visible text that differs between two boards ("Checkout started" and
    /// "Checkout started · 12,904"): each text run between tags, markup and comments dropped. A
    /// change only to markup says so.
    static func firstDifference(_ before: String, _ after: String) -> (String, String) {
        func runs(_ text: String) -> [String] {
            text.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "<>", options: .regularExpression)
                .replacingOccurrences(of: "<(style|script)[\\s\\S]*?</\\1>", with: "<>", options: .regularExpression)
                .components(separatedBy: CharacterSet(charactersIn: "<>"))
                .enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
                .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
                .filter { !$0.isEmpty }
        }
        let x = runs(before), y = runs(after)
        var i = 0
        while i < min(x.count, y.count), x[i] == y[i] { i += 1 }
        let a = i < x.count ? x[i] : ""
        let b = i < y.count ? y[i] : ""
        if a.isEmpty, b.isEmpty, before != after { return ("Markup only", "Markup only") }
        return (String(a.prefix(80)), String(b.prefix(80)))
    }
}
