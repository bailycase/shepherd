import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdUI

/// What the Tweak tab edits: the latest pick on the canvas, an element or a board whole.
struct DesignTweakTarget: Hashable, Sendable {
    let board: DesignPath
    /// The element; nil for a board picked whole (its data-props only).
    let element: DesignElementID?
    let kind: DesignElementKind
    /// "card · Checkout funnel".
    let tag: String?
}

/// Reads and writes a design's files for Tweak: the host's design mutations.
struct DesignTweakIO {
    var snapshot: () async throws -> DesignSnapshot
    var board: (DesignPath) async throws -> DesignBoardSource
    var writeBoards: ([DesignPath: String], UInt64?) async throws -> DesignBoardsWrite
    var updateIndex: (JSONValue, UInt64?) async throws -> DesignWriteResult
    var restore: ([DesignPath: Int], [DesignPath: String]?) async throws -> DesignBoardsWrite
    /// The custom properties the design's project declares (read off the main actor).
    var projectTokens: () async -> DesignTokens
}

/// The Tweak tab (DZTweak; docs/designs.md › Tweak): the selected element's inline-style controls
/// and its board's data-props, snapped to the design's tokens.
///
/// While a slider drags, the change shows in the board's live view (`DesignHost.previewStyle`)
/// and nothing is written; on release it is written once: an inline-style splice at the parser's
/// offsets on every board in scope (`writeDesignBoards`, one revision), or the data-props value in
/// canvas.json's `tweaks`. Each write names the revision it read; a stale one is read again and
/// made once more. Each kept tweak registers an undo (the boards' versions, or the old values).
@MainActor @Observable
final class DesignTweakModel {
    enum Phase: Sendable { case changed, ended }
    typealias Scope = NWTweakScope.Scope

    /// What the tab shows: its header, its groups and footer, as plain values.
    struct Presentation: Equatable {
        var board = ""
        var element: String?
        var groups: [DesignTweakGroup] = []
        var scopeName: String?
        var scopeNote: String?
        var canReset = false
        /// A write that didn't go, or a selection Tweak can't edit.
        var problem: String?
        /// Nothing is selected.
        var isEmpty = true
    }

    private(set) var presentation = Presentation()
    private(set) var target: DesignTweakTarget?
    var scope: Scope = .board {
        didSet { if scope != oldValue { Task { await rebuild(loadingScope: true) } } }
    }
    /// Tests: writes made (board writes and index updates).
    @ObservationIgnored private(set) var writes = 0
    /// Tests: previews sent to live views.
    @ObservationIgnored private(set) var previews = 0

    @ObservationIgnored weak var undoManager: UndoManager?
    @ObservationIgnored let designID: DesignID
    @ObservationIgnored private let io: DesignTweakIO
    @ObservationIgnored private weak var host: DesignHost?
    /// The design's name for its system, in the scope's note.
    @ObservationIgnored var systemName = "the design's"
    /// Told when a board's live view previewed a change, so its selection is measured again.
    @ObservationIgnored var previewed: ((DesignPath) -> Void)?
    /// The last snapshot the canvas pulled, for revisions and hashes.
    @ObservationIgnored private var snapshot: DesignSnapshot?
    /// Board sources read, by path, with the hash they had.
    @ObservationIgnored private var sources: [DesignPath: DesignBoardSource] = [:]
    @ObservationIgnored private var projectTokens: DesignTokens?
    /// Every board's elements named like the target's (`data-el`), for "Every <name>".
    @ObservationIgnored private var named: [DesignPath: [Int]] = [:]
    /// Values shown while a slider drags, before they are written.
    @ObservationIgnored private var dragging: [DesignTweakRow.ID: Double] = [:]
    /// What this session changed, for Reset: each element's declared values before the first
    /// change (nil where it declared none), and each board's props before theirs.
    @ObservationIgnored private var originals: [DesignPath: [Int: [String: String?]]] = [:]
    @ObservationIgnored private var propOriginals: [DesignPath: [String: JSONValue?]] = [:]
    /// Previews go one at a time; the latest waits.
    @ObservationIgnored private var previewing: Task<Void, Never>?
    @ObservationIgnored private var pendingPreview: [DesignPath: [Int: [String: String?]]]?
    @ObservationIgnored private var pendingProps: (path: DesignPath, json: String)?
    @ObservationIgnored private var loadSerial = 0

    init(designID: DesignID, io: DesignTweakIO, host: DesignHost?) {
        self.designID = designID
        self.io = io
        self.host = host
    }

    // MARK: Loading

    /// The canvas pulled a new snapshot: sources whose hash moved are read again.
    func snapshotChanged(_ next: DesignSnapshot) async {
        guard snapshot != next else { return }
        snapshot = next
        guard target != nil else { return }
        await rebuild(loadingScope: scope == .every)
    }

    /// The canvas's latest pick changed (nil: nothing selected).
    func select(_ next: DesignTweakTarget?) async {
        guard target != next else { return }
        let sameElement = target?.board == next?.board && target?.element?.tid == next?.element?.tid
        target = next
        if !sameElement { dragging = [:] }
        await rebuild(loadingScope: scope == .every)
    }

    /// Works the tab out again from the target's board as it is now.
    private func rebuild(loadingScope: Bool) async {
        loadSerial += 1
        let serial = loadSerial
        guard let target else {
            presentation = Presentation()
            return
        }
        do {
            if snapshot == nil { snapshot = try await io.snapshot() }
            let source = try await self.source(target.board)
            if projectTokens == nil { projectTokens = await io.projectTokens() }
            if loadingScope, let name = elementName(target, in: source.source) { try await loadNamed(name) }
            guard serial == loadSerial else { return }
            presentation = present(target, source: source.source)
        } catch {
            guard serial == loadSerial else { return }
            presentation = Presentation(board: boardTitle(target.board), element: target.tag, problem: Self.describe(error), isEmpty: false)
        }
    }

    /// A board's source, read again when its hash moved since.
    private func source(_ path: DesignPath) async throws -> DesignBoardSource {
        if let cached = sources[path], cached.sha256 == snapshot?.boards[path] { return cached }
        let read = try await io.board(path)
        sources[path] = read
        return read
    }

    private func loadNamed(_ name: String) async throws {
        guard let snapshot else { return }
        var found: [DesignPath: [Int]] = [:]
        for path in DesignScreenModel.canvasOrder(snapshot.index) {
            let tids = DesignStyleEdit.elements(named: name, in: try await source(path).source)
            if !tids.isEmpty { found[path] = tids }
        }
        named = found
    }

    private func elementName(_ target: DesignTweakTarget, in source: String) -> String? {
        guard let tid = target.element?.tid else { return nil }
        return DesignStyleEdit.attribute("data-el", of: tid, in: source).flatMap { $0.contains("{{") || $0.isEmpty ? nil : $0 }
    }

    private func tokens(for source: String) -> (all: DesignTokens, board: DesignTokens) {
        let board = DesignTokens.read(board: source)
        return (board.merged(with: projectTokens ?? DesignTokens()), board)
    }

    private func boardTitle(_ path: DesignPath) -> String {
        snapshot?.index.boards[path]?.title?.trimmingCharacters(in: .whitespaces).nonEmpty ?? path.stem
    }

    private func present(_ target: DesignTweakTarget, source: String) -> Presentation {
        var out = Presentation(board: boardTitle(target.board), element: target.tag, isEmpty: false)
        let (tokens, _) = self.tokens(for: source)
        var groups: [DesignTweakGroup] = []
        if let id = target.element {
            if let style = DesignStyleEdit.style(of: id.tid, in: source) {
                groups += DesignTweakControls.styleGroups(style, kind: target.kind, tokens: tokens)
            } else {
                out.problem = "This element takes no style of its own."
            }
            if let name = elementName(target, in: source) {
                out.scopeName = name
                let reach = DesignScreenModel.canvasOrder(snapshot?.index ?? DesignIndex(title: nil)).filter { named[$0] != nil }
                let fromTokens = DesignTokens.Role.allCases.allSatisfy { !tokens.scale($0).isEmpty }
                out.scopeNote = DesignTweakControls.scopeNote(name: name, boards: scope == .every ? reach.map(boardTitle) : [],
                                                              system: systemName, fromTokens: fromTokens)
            }
        }
        let editors = DesignProps.editors(in: source)
        groups += DesignTweakControls.propGroups(editors, tweaks: snapshot?.index.tweaks(for: target.board) ?? [:], tokens: tokens)
        out.groups = groups.map { group in
            DesignTweakGroup(title: group.title, rows: group.rows.map(showingDrag))
        }
        out.canReset = !resetChanges(target).styles.isEmpty || !(propOriginals[target.board] ?? [:]).isEmpty
        if out.problem == nil { out.problem = keptProblem }
        return out
    }

    /// A row as the slider being dragged shows it.
    private func showingDrag(_ row: DesignTweakRow) -> DesignTweakRow {
        guard let value = dragging[row.id] else { return row }
        switch row.control {
        case .steps(let values, _): return DesignTweakRow(id: row.id, label: row.label, control: .steps(values: values, index: Int(value)))
        case .slider(_, let min, let max, let step):
            return DesignTweakRow(id: row.id, label: row.label, control: .slider(value: value, min: min, max: max, step: step))
        default: return row
        }
    }

    /// A problem worth keeping on screen until the next change.
    @ObservationIgnored private var keptProblem: String?

    private func report(_ problem: String?) {
        keptProblem = problem
        presentation.problem = problem
    }

    // MARK: Style

    /// Where a change to the target's style goes: its element, or every element of its name.
    private func scopeTargets(_ target: DesignTweakTarget) -> [DesignPath: [Int]] {
        guard let tid = target.element?.tid else { return [:] }
        if scope == .every, !named.isEmpty { return named }
        return [target.board: [tid]]
    }

    /// A slider over a scale's steps moved (`index`), or was let go.
    func setStep(_ property: DesignTweakProperty, index: Int, phase: Phase) {
        guard let target, let role = property.role,
              case .steps(let values, _)? = row(.style(property))?.control, values.indices.contains(index) else { return }
        dragging[.style(property)] = Double(index)
        let px = values[index]
        let value = DesignTweakControls.lengthValue(px, role: role, boardTokens: boardTokens(target.board))
        change(property, to: value, phase: phase)
    }

    /// A segmented choice (direction, radius, text size).
    func choose(_ property: DesignTweakProperty, _ value: String) {
        guard let target else { return }
        let written: String
        switch property {
        case .radius, .textSize, .gap, .padding:
            guard let px = Double(value), let role = property.role else { return }
            written = DesignTweakControls.lengthValue(px, role: role, boardTokens: boardTokens(target.board))
        default:
            written = value
        }
        change(property, to: written, phase: .ended)
    }

    /// A token chip.
    func choose(_ property: DesignTweakProperty, color: DesignTweakColor) {
        guard let target else { return }
        change(property, to: DesignTweakControls.colorValue(color, boardTokens: boardTokens(target.board)), phase: .ended)
    }

    private func boardTokens(_ path: DesignPath) -> DesignTokens {
        sources[path].map { DesignTokens.read(board: $0.source) } ?? DesignTokens()
    }

    private func row(_ id: DesignTweakRow.ID) -> DesignTweakRow? {
        presentation.groups.lazy.flatMap(\.rows).first { $0.id == id }
    }

    private func change(_ property: DesignTweakProperty, to value: String, phase: Phase) {
        guard let target, let tid = target.element?.tid, let source = sources[target.board]?.source,
              let style = DesignStyleEdit.style(of: tid, in: source) else { return }
        let css = DesignTweakControls.cssProperty(property, style: style)
        let changes = scopeTargets(target).mapValues { tids in Dictionary(uniqueKeysWithValues: tids.map { ($0, [css: Optional(value)]) }) }
        preview(changes)
        if phase == .changed {
            presentation.groups = presentation.groups.map { DesignTweakGroup(title: $0.title, rows: $0.rows.map(showingDrag)) }
            return
        }
        Task { await commit(changes, name: "Tweak") }
    }

    // MARK: Previews

    private func preview(_ changes: [DesignPath: [Int: [String: String?]]]) {
        pendingPreview = changes
        runPreviews()
    }

    private func runPreviews() {
        guard previewing == nil, let host else { return }
        previewing = Task { [weak self] in
            while let self, self.pendingPreview != nil || self.pendingProps != nil {
                if let changes = self.pendingPreview {
                    self.pendingPreview = nil
                    for (path, elements) in changes.sorted(by: { $0.key < $1.key }) where await host.previewStyle(path, elements) {
                        self.previews += 1
                        self.previewed?(path)
                    }
                }
                if let props = self.pendingProps {
                    self.pendingProps = nil
                    if await host.previewProps(props.path, props.json) { self.previews += 1 }
                }
            }
            self?.previewing = nil
        }
    }

    /// Waits for the previews sent so far.
    private func previewsSettled() async {
        while let running = previewing { await running.value }
    }

    // MARK: Writing

    /// Writes style changes to every board they reach as one change. A stale revision is read
    /// again and the change made once more on what is there now.
    private func commit(_ changes: [DesignPath: [Int: [String: String?]]], name: String, isReset: Bool = false) async {
        await previewsSettled()
        dragging = [:]
        for attempt in 0..<2 {
            do {
                let base = try await baseRevision(fresh: attempt > 0)
                var sources: [DesignPath: String] = [:]
                var edits = changes
                if attempt > 0, !isReset, let target, let refound = try await refind(target) { edits = refound.mapValues { tids in
                    Dictionary(uniqueKeysWithValues: tids.map { ($0, changes.values.first?.values.first ?? [:]) })
                } }
                for (path, elements) in edits {
                    let current = try await source(path)
                    if !isReset { remember(elements, on: path, in: current.source) }
                    sources[path] = try DesignStyleEdit.apply(elements, in: current.source)
                }
                writes += 1
                let written = try await io.writeBoards(sources, base)
                for (path, text) in sources {
                    if let sha = written.shas[path] { self.sources[path] = DesignBoardSource(path: path, source: text, sha256: sha, revision: written.result.revision) }
                }
                if isReset { originals = originals.filter { changes[$0.key] == nil } }
                snapshot = (try? await io.snapshot()) ?? snapshot
                registerUndo(.boards(written.versions, written.shas), name: name)
                report(nil)
                await rebuild(loadingScope: false)
                return
            } catch DesignStoreError.stale where attempt == 0 {
                continue
            } catch {
                for path in changes.keys { await host?.endPreview(path) }
                report("Couldn't keep the tweak: \(Self.describe(error))")
                await rebuild(loadingScope: false)
                return
            }
        }
        for path in changes.keys { await host?.endPreview(path) }
        report("Couldn't keep the tweak: the design kept changing. Try again.")
    }

    /// The revision a write names: the canvas's last snapshot, or the host's now.
    private func baseRevision(fresh: Bool) async throws -> UInt64 {
        if fresh || snapshot == nil { snapshot = try await io.snapshot() }
        return snapshot!.revision
    }

    /// After the design moved: where the target's element (by its path) and every element of its
    /// name are now. Nil when nothing needs finding again.
    private func refind(_ target: DesignTweakTarget) async throws -> [DesignPath: [Int]]? {
        guard let id = target.element else { return nil }
        let source = try await self.source(target.board)
        guard let template = DesignTemplate(board: source.source), template.element(for: id) != nil else {
            throw DesignTweakProblem.elementChanged
        }
        if scope == .every, let name = elementName(target, in: source.source) {
            try await loadNamed(name)
            return named
        }
        return [target.board: [id.tid]]
    }

    /// Keeps each element's declared values before this session's first change to them.
    private func remember(_ elements: [Int: [String: String?]], on path: DesignPath, in source: String) {
        for (tid, properties) in elements {
            guard let style = DesignStyleEdit.style(of: tid, in: source) else { continue }
            for property in properties.keys where originals[path]?[tid]?[property] == nil {
                originals[path, default: [:]][tid, default: [:]][property] = .some(style.value(property))
            }
        }
    }

    // MARK: Props

    /// A data-props control moved (a slider while dragging), or was set.
    func setProp(_ name: String, _ value: JSONValue, phase: Phase) {
        guard let target, let source = sources[target.board]?.source,
              let editor = DesignProps.editors(in: source).first(where: { $0.name == name }) else { return }
        let colors = Set(tokens(for: source).all.colors.map(\.hex))
        guard let accepted = editor.accepting(value, colors: colors) else { return }
        var props = snapshot?.index.tweaks(for: target.board) ?? [:]
        props[name] = accepted
        if let json = Self.json(.object(props)) {
            pendingProps = (target.board, json)
            runPreviews()
        }
        if phase == .changed {
            if let number = accepted.doubleValue { dragging[.prop(name)] = number }
            presentation.groups = presentation.groups.map { DesignTweakGroup(title: $0.title, rows: $0.rows.map(showingDrag)) }
            return
        }
        let before = snapshot?.index.tweaks(for: target.board)[name]
        if propOriginals[target.board]?[name] == nil { propOriginals[target.board, default: [:]][name] = .some(before) }
        Task { await commitProps(target.board, [name: accepted], undo: [name: before], name: "Tweak") }
    }

    /// An enum prop's option, by the title its picker shows: the value as data-props wrote it.
    func setPropChoice(_ name: String, _ title: String) {
        guard let target, let source = sources[target.board]?.source,
              let editor = DesignProps.editors(in: source).first(where: { $0.name == name }),
              let option = editor.options.first(where: { ($0.stringValue ?? $0.doubleValue.map(DesignTweakControls.format)) == title })
        else { return }
        setProp(name, option, phase: .ended)
    }

    /// A prop's text field was submitted: text for a text prop, a number for a number prop.
    func setPropText(_ name: String, _ text: String) {
        guard let target, let source = sources[target.board]?.source,
              let editor = DesignProps.editors(in: source).first(where: { $0.name == name }) else { return }
        switch editor.kind {
        case .int, .float, .range:
            guard let number = Double(text.trimmingCharacters(in: .whitespaces)) else { return }
            setProp(name, .number(number), phase: .ended)
        default:
            setProp(name, .string(text), phase: .ended)
        }
    }

    private func commitProps(_ path: DesignPath, _ values: [String: JSONValue?], undo: [String: JSONValue?], name: String) async {
        await previewsSettled()
        dragging = [:]
        let patch = DesignIndex.tweakPatch(path, values)
        for attempt in 0..<2 {
            do {
                let base = try await baseRevision(fresh: attempt > 0)
                writes += 1
                _ = try await io.updateIndex(patch, base)
                snapshot = try await io.snapshot()
                registerUndo(.props(path, undo, redo: values), name: name)
                report(nil)
                await rebuild(loadingScope: false)
                return
            } catch DesignStoreError.stale where attempt == 0 {
                continue
            } catch {
                break
            }
        }
        // Not kept: the board draws what canvas.json holds again.
        if let json = Self.json(.object(snapshot?.index.tweaks(for: path) ?? [:])) { _ = await host?.previewProps(path, json) }
        report("Couldn't keep the tweak. Try again.")
        await rebuild(loadingScope: false)
    }

    // MARK: Reset

    /// What Reset puts back for the target: its elements' values from before this session's
    /// changes (in scope), and its board's props.
    private func resetChanges(_ target: DesignTweakTarget) -> (styles: [DesignPath: [Int: [String: String?]]], props: [String: JSONValue?]) {
        var styles: [DesignPath: [Int: [String: String?]]] = [:]
        for (path, tids) in scopeTargets(target) {
            for tid in tids {
                if let values = originals[path]?[tid], !values.isEmpty { styles[path, default: [:]][tid] = values }
            }
        }
        return (styles, propOriginals[target.board] ?? [:])
    }

    /// Reset (DZTweak's footer): puts back what this session changed on the target.
    func reset() {
        guard let target else { return }
        let (styles, props) = resetChanges(target)
        Task {
            if !styles.isEmpty { await commit(styles, name: "Reset", isReset: true) }
            if !props.isEmpty {
                let now = snapshot?.index.tweaks(for: target.board) ?? [:]
                propOriginals[target.board] = nil
                let undo = Dictionary(uniqueKeysWithValues: props.keys.map { ($0, now[$0]) })
                await commitProps(target.board, props, undo: undo, name: "Reset")
            }
        }
    }

    // MARK: Undo

    private enum Step {
        /// Put boards back to kept versions, while they still have these hashes.
        case boards([DesignPath: Int], [DesignPath: String])
        /// Set a board's props back (`undo`), or forward again (`redo`).
        case props(DesignPath, [String: JSONValue?], redo: [String: JSONValue?])
    }

    /// Filled once a step has run, so its redo (registered while undoing, as UndoManager asks)
    /// knows what to put back.
    private final class Pending {
        var step: Step?
    }

    private func registerUndo(_ step: Step, name: String) {
        guard let undoManager else { return }
        if case .boards(let versions, _) = step, versions.isEmpty { return }
        undoManager.registerUndo(withTarget: self) { model in
            let pending = Pending()
            MainActor.assumeIsolated { model.run(step, name: name, then: pending) }
        }
        undoManager.setActionName(name)
    }

    private func run(_ step: Step, name: String, then pending: Pending) {
        // The step opposite this one, registered now so it lands as the redo (or undo).
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                guard let next = pending.step else { return }
                let again = Pending()
                model.run(next, name: name, then: again)
            }
        }
        undoManager?.setActionName(name)
        Task {
            do {
                switch step {
                case .boards(let versions, let shas):
                    writes += 1
                    let written = try await io.restore(versions, shas)
                    pending.step = .boards(written.versions, written.shas)
                case .props(let path, let values, let redo):
                    writes += 1
                    _ = try await io.updateIndex(DesignIndex.tweakPatch(path, values), nil)
                    snapshot = try await io.snapshot()
                    pending.step = .props(path, redo, redo: values)
                }
                report(nil)
            } catch {
                report("Couldn't undo: the board changed since.")
            }
            await rebuild(loadingScope: false)
        }
    }

    // MARK: Helpers

    static func json(_ value: JSONValue) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) }
    }

    static func describe(_ error: any Error) -> String {
        if let problem = error as? DesignTweakProblem { return problem.description }
        if let refused = error as? DesignStyleEdit.Problem { return refused.description }
        if let store = error as? DesignStoreError { return store.description }
        return String(describing: error)
    }
}

enum DesignTweakProblem: Error, CustomStringConvertible {
    case elementChanged

    var description: String {
        switch self {
        case .elementChanged: "the element changed on its board; select it again"
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
