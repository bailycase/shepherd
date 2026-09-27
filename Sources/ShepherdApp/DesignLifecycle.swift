import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// Deleting, duplicating and importing designs and design systems (DesignLifecycleStates) as
// plain values: which items each menu holds, what each dialog and toast says. Pure, so the
// words and rules are tested without a window; the views draw them and the view model acts.

// MARK: - Menus

/// Where a design's menu opens (DesignMenu): a card on Designs, its row in Recents, or ••• in
/// its own toolbar.
enum DesignMenuContext: Equatable {
    case card, recents, toolbar
}

/// What a menu item does.
enum DesignMenuAction: Hashable {
    case open, showSystem, rename, duplicate, export, removeFromRecents, delete
    // A design system's (SystemMenu).
    case resync, duplicateSystem, deleteSystem
}

/// One item of a design's or a system's menu: its words, glyph, and whether it is off (with
/// why, under it).
struct DesignMenuItem: Hashable, Identifiable {
    let action: DesignMenuAction
    let title: String
    let symbol: String
    var destructive = false
    /// Off, with the reason under it ("Night Watch is built into Shepherd…").
    var disabledReason: String?

    var id: DesignMenuAction { action }
    var enabled: Bool { disabledReason == nil }
}

/// A menu's items in sections, divided where the boards draw a hairline.
struct DesignMenu: Hashable {
    let sections: [[DesignMenuItem]]

    var items: [DesignMenuItem] { sections.flatMap { $0 } }

    /// A design's menu (DesignCardMenu, DesignRecentsMenu, DesignToolbarMenu): Open (in its own
    /// toolbar, Show design system in its place, after Export), Rename…, Duplicate, Export…,
    /// Remove from Recents in Recents, then Delete design…. A host's design (`remote`) offers what
    /// its host does: Duplicate, Export and Remove from Recents stay here only, and Delete needs
    /// a host that deletes for other devices (`hostDeletes`).
    static func design(_ context: DesignMenuContext, hasSystem: Bool, remote: String? = nil, hostDeletes: Bool = true) -> DesignMenu {
        var main: [DesignMenuItem] = []
        if context != .toolbar { main.append(DesignMenuItem(action: .open, title: "Open", symbol: "arrow.up.forward.app")) }
        main.append(DesignMenuItem(action: .rename, title: "Rename…", symbol: "pencil"))
        if remote == nil {
            main.append(DesignMenuItem(action: .duplicate, title: "Duplicate", symbol: "plus.square.on.square"))
            main.append(DesignMenuItem(action: .export, title: "Export…", symbol: "square.and.arrow.up"))
        }
        if context == .toolbar, hasSystem, remote == nil {
            main.append(DesignMenuItem(action: .showSystem, title: "Show design system", symbol: "paintpalette"))
        }
        if context == .recents, remote == nil {
            main.append(DesignMenuItem(action: .removeFromRecents, title: "Remove from Recents", symbol: "clock.badge.xmark"))
        }
        var delete = DesignMenuItem(action: .delete, title: "Delete design…", symbol: "trash", destructive: true)
        if let remote, !hostDeletes {
            delete.destructive = false
            delete.disabledReason = "\(remote) doesn’t delete designs for other devices yet. Update Shepherd there, or delete it on \(remote)."
        }
        return DesignMenu(sections: [main, [delete]])
    }

    /// A design system's menu (SystemCardMenu, SystemBuiltIn): Open, Re-sync from its repo (when
    /// it was read from one), Rename…, Duplicate, then Delete design system…. A built-in offers
    /// Open and "Duplicate as a new system", and keeps Delete in the menu, off, with the reason
    /// under it. A build still reading its repo offers Open and Delete.
    static func system(name: String, builtIn: Bool, repo: String?, building: Bool) -> DesignMenu {
        let open = DesignMenuItem(action: .open, title: "Open", symbol: "arrow.up.forward.app")
        let delete = DesignMenuItem(action: .deleteSystem, title: "Delete design system…", symbol: "trash", destructive: true)
        if builtIn {
            var off = delete
            off.destructive = false
            off.disabledReason = "\(name) is built into Shepherd. Duplicate it to make one you can change or delete."
            return DesignMenu(sections: [[open, DesignMenuItem(action: .duplicateSystem, title: "Duplicate as a new system",
                                                               symbol: "plus.square.on.square")], [off]])
        }
        if building { return DesignMenu(sections: [[open], [delete]]) }
        var main = [open]
        if let repo { main.append(DesignMenuItem(action: .resync, title: "Re-sync from \(repo)", symbol: "arrow.triangle.2.circlepath")) }
        main.append(DesignMenuItem(action: .rename, title: "Rename…", symbol: "pencil"))
        main.append(DesignMenuItem(action: .duplicateSystem, title: "Duplicate", symbol: "plus.square.on.square"))
        return DesignMenu(sections: [main, [delete]])
    }
}

// MARK: - Delete design

/// DeleteDesignDialog as values: it names the design, lists what goes and what stays, and says
/// Undo is there; while its agent draws, a warning and "Stop and delete".
struct DeleteDesignWords: Hashable {
    struct Line: Hashable {
        enum Role: Hashable { case goes, stays }
        let role: Role
        /// A bold lead ("4 boards"), then the rest.
        let lead: String?
        let text: String
        /// A mono span after `text` ("acme-web"), then `tail`.
        var mono: String?
        var tail: String?
    }

    let title: String
    let lines: [Line]
    let note: String
    let warning: String?
    let confirm: String

    init(name: String, boards: Int, versions: Int?, comments: Int?, system: String?, agentWorking: Bool, drawing: Int) {
        title = "Delete “\(name)”?"
        var lines = [Line(role: .goes, lead: Self.count(boards, "board"), text: Self.after(boards: boards, versions: versions, comments: comments))]
        lines.append(Line(role: .goes, lead: nil, text: "The design agent’s chat for this design"))
        if let system {
            lines.append(Line(role: .stays, lead: nil, text: "Stays: ", mono: system, tail: ", the design system it uses"))
        }
        self.lines = lines
        note = "You can undo right after."
        if agentWorking {
            let what = drawing > 0 ? "is drawing \(Self.count(drawing, "board")) right now" : "is drawing right now"
            warning = "The design agent \(what). Deleting stops it, and what it’s drawing is lost."
            confirm = "Stop and delete"
        } else {
            warning = nil
            confirm = "Delete"
        }
    }

    /// "4 boards", "1 board".
    static func count(_ n: Int, _ noun: String) -> String { n == 1 ? "1 \(noun)" : "\(n) \(noun)s" }

    /// What follows the boards: ", their 23 versions and 2 comments", " and their 23 versions",
    /// " and 2 comments", or nothing.
    static func after(boards: Int, versions: Int?, comments: Int?) -> String {
        let their = boards == 1 ? "its" : "their"
        let kept = (versions ?? 0) > 0 ? "\(their) \(count(versions ?? 0, "version"))" : nil
        let said = (comments ?? 0) > 0 ? count(comments ?? 0, "comment") : nil
        switch (kept, said) {
        case let (kept?, said?): return ", \(kept) and \(said)"
        case let (kept?, nil): return " and \(kept)"
        case let (nil, said?): return " and \(said)"
        case (nil, nil): return ""
        }
    }
}

/// The boards the design agent is drawing in the turn it is working on: the distinct paths of
/// its board writes since the viewer's last message.
func designBoardsDrawing(_ messages: [NativeThreadMessage]) -> Int {
    var paths = Set<String>()
    for message in messages.reversed() {
        if message.role == "user" { break }
        guard message.toolName == "board_write", let data = message.argumentsText?.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let path = args["path"] as? String else { continue }
        paths.insert(path)
    }
    return paths.count
}

// MARK: - Delete design system

/// DeleteSystemDialog as values: what goes, who uses it (they keep their copy), the repo it was
/// read from (never touched); for a system still being built, "Stop and delete".
struct DeleteSystemWords: Hashable {
    struct Line: Hashable {
        enum Role: Hashable { case stays, note }
        let role: Role
        let lead: String?
        let text: String
        /// Mono spans: the repo's name inside `text`, split as before · mono · after.
        var mono: String?
        var tail: String?
    }

    let title: String
    /// The message before the list; `messageMono` is a repo's name inside it.
    let message: String
    var messageMono: String?
    var messageTail: String?
    let lines: [Line]
    let confirm: String

    init(name: String, components: Int, usedBy: [String], repo: String?, building: Bool) {
        let used: Line = usedBy.isEmpty
            ? Line(role: .stays, lead: nil, text: "No designs use it yet")
            : Line(role: .stays, lead: "Used by \(DeleteDesignWords.count(usedBy.count, "design")); they keep their copy.",
                   text: " " + usedBy.joined(separator: ", "))
        if building {
            title = "Delete “\(name)”?"
            if let repo {
                message = "It’s still being built from "
                messageMono = repo
                messageTail = ". Deleting stops the build and keeps nothing from it."
            } else {
                message = "It’s still being built. Deleting stops the build and keeps nothing from it."
            }
            var lines = [used]
            if let repo { lines.append(Line(role: .stays, lead: nil, text: "The repo ", mono: repo, tail: " isn’t touched")) }
            self.lines = lines
            confirm = "Stop and delete"
        } else {
            title = "Delete the design system “\(name)”?"
            let parts = components > 0 ? "Its colors, type, spacing and \(DeleteDesignWords.count(components, "component"))"
                : "Its colors, type and spacing"
            message = "\(parts) go from Shepherd."
            var lines = [used]
            if let repo {
                lines.append(Line(role: .stays, lead: nil, text: "Built from ", mono: repo, tail: ". The repo isn’t touched."))
                lines.append(Line(role: .note, lead: nil, text: "New designs can’t pick it. Build it again from the repo any time."))
            } else {
                lines.append(Line(role: .note, lead: nil, text: "New designs can’t pick it."))
            }
            self.lines = lines
            confirm = "Delete"
        }
    }
}

// MARK: - The toast

/// The toast over the main column after a deletion (UndoToast, DeleteFailedToast).
struct DesignToast: Identifiable, Equatable {
    enum Kind: Equatable {
        /// Deleted, with Undo until the host lets the files go.
        case deleted(DesignDeletion, host: UUID?)
        /// A design that couldn't be deleted is back; Try again.
        case designFailed(DesignID, host: UUID?)
        /// A system that couldn't be deleted stays; Try again.
        case systemFailed(DesignSystemTarget)
    }

    let id = UUID()
    let kind: Kind
    let name: String
    /// Why it failed, after the name.
    var reason: String?

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }

    var isFailure: Bool { if case .deleted = kind { false } else { true } }
    var actionTitle: String { isFailure ? "Try again" : "Undo" }
    var actionSymbol: String { isFailure ? "arrow.clockwise" : "arrow.uturn.backward" }

    /// "Deleted " name "." / "Couldn’t delete " name ". <reason>"
    var words: (before: String, after: String) {
        isFailure ? ("Couldn’t delete ", "." + (reason.map { " \($0)" } ?? "")) : ("Deleted ", ".")
    }

    /// Why a host's design came back: its host didn't answer (it's "where it's saved"), or what
    /// it said.
    static func remoteReason(host: String, error: Error) -> String {
        switch error {
        case RemoteHostClientError.rejected(_, let message): return "\(host) said: \(message)"
        default: return "\(host), where it’s saved, didn’t answer, so it’s back."
        }
    }
}

// MARK: - Import

/// The card an import fills on Designs while it runs (ImportProgress).
struct DesignImporting: Equatable {
    var file: String
    var title: String?
    var done = 0
    var total = 0
    var system: String?

    mutating func apply(_ progress: DesignImportProgress) {
        switch progress {
        case .checking(let file): self.file = file
        case .boards(let done, let total, let title, let system):
            self.done = done
            self.total = total
            self.title = title
            self.system = system
        case .opening(let title): self.title = title
        }
    }

    /// The card's title: the project's once it is read, else the file's name.
    var shownTitle: String { title ?? (file.lowercased().hasSuffix(".zip") ? String(file.dropLast(4)) : file) }
}

/// What an import asks the viewer (ImportFailed, ImportAgain).
enum DesignImportPrompt: Identifiable, Equatable {
    /// It couldn't become a design; nothing was imported.
    case failed(file: String, DesignImportFailure)
    /// Boards that can't be read: cancel, or import the rest on purpose.
    case unreadable(DesignImportPreview)
    /// The same project is in Designs already: a separate copy, or the one there is.
    case again(DesignImportPreview, existing: Design, copyName: String)

    var id: String {
        switch self {
        case .failed(let file, let failure): "failed.\(file).\(failure.message.hashValue)"
        case .unreadable(let preview): "unreadable.\(preview.id)"
        case .again(let preview, _, _): "again.\(preview.id)"
        }
    }
}

/// ImportAgainDialog as values.
struct ImportAgainWords: Hashable {
    let title: String
    let name: String
    let date: String
    /// "New copy: " then the copy's name bold, then " · 12 boards · 3 pages".
    let copyName: String
    let copyRest: String
    /// "Design system: uses the " then the system in mono, then " you already have".
    let systemBefore: String?
    let system: String?
    let systemAfter: String?

    init(preview: DesignImportPreview, existing: Design, copyName: String, now: Date = Date(),
         calendar: Calendar = .current, locale: Locale = Locale(identifier: "en_US_POSIX")) {
        let name = existing.importedFrom?.title ?? existing.name
        title = "“\(name)” is already in Designs"
        self.name = name
        let imported = Date(timeIntervalSince1970: (existing.importedFrom?.importedAt ?? existing.createdAt) / 1000)
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = calendar.isDate(imported, equalTo: now, toGranularity: .year) ? "MMM d" : "MMM d, yyyy"
        date = formatter.string(from: imported)
        self.copyName = copyName
        let pages = preview.pages > 1 ? " · \(DeleteDesignWords.count(preview.pages, "page"))" : ""
        copyRest = " · \(DeleteDesignWords.count(preview.boards, "board"))\(pages)"
        if let first = preview.systems.first {
            systemBefore = first.existing != nil ? "Design system: uses the " : "Design system: "
            system = first.title
            systemAfter = first.existing != nil ? " you already have" : " comes along as a system of its own"
        } else {
            systemBefore = nil
            system = nil
            systemAfter = nil
        }
    }

    /// "You imported " name " on Sep 20. Import it again as a separate copy, or open the one you
    /// have. The two don’t affect each other."
    var messageAfter: String {
        " on \(date). Import it again as a separate copy, or open the one you have. The two don’t affect each other."
    }
}

/// What the first message to an imported design's agent says (ImportDone: it reads everything
/// and changes nothing until asked).
enum DesignImportBrief {
    static func text(file: String) -> String {
        "This design was imported from Claude Design (\(file)), with its pages, notes and layout as they were. Read its boards, "
            + "notes and design system, run design_check, and tell me in a few sentences what you found (anything off-system "
            + "included). Change nothing until I ask, and end by asking what to work on first."
    }
}

/// Whether a dropped or chosen file can be a Claude Design project: a folder, or a `.zip`.
enum DesignImportSource {
    static func accepts(_ url: URL) -> Bool {
        if url.pathExtension.lowercased() == "zip" { return true }
        var folder: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &folder) && folder.boolValue
    }
}
