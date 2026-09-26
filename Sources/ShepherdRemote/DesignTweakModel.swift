import Foundation
import ShepherdCore
import ShepherdProtocol

/// What the Tweak tab edits: the latest pick on the canvas, an element or a board whole.
public struct DesignTweakTarget: Hashable, Sendable {
    public let board: DesignPath
    /// The element; nil for a board picked whole (its data-props only).
    public let element: DesignElementID?
    public let kind: DesignElementKind
    /// "card · Checkout funnel".
    public let tag: String?

    public init(board: DesignPath, element: DesignElementID?, kind: DesignElementKind, tag: String?) {
        self.board = board
        self.element = element
        self.kind = kind
        self.tag = tag
    }
}

/// Where a tweak applies: the element on its board, or every element of its name (`data-el`)
/// across the design.
public enum DesignTweakScope: Hashable, Sendable { case board, every }

/// Shows a tweak on a board's live view while it drags, without writing it: the canvas's
/// renderer (the Mac's `DesignHost`, the iPad's).
@MainActor
public protocol DesignTweakPreviews: AnyObject {
    func previewStyle(_ path: DesignPath, _ changes: [Int: [String: String?]]) async -> Bool
    func previewProps(_ path: DesignPath, _ json: String) async -> Bool
    func endPreview(_ path: DesignPath) async
}

/// Reads and writes a design's files for Tweak: the host's design mutations, this Mac's server
/// or a remote host's over `designs.v1`.
public struct DesignTweakIO {
    public var snapshot: () async throws -> DesignSnapshot
    public var board: (DesignPath) async throws -> DesignBoardSource
    public var writeBoards: ([DesignPath: String], UInt64?) async throws -> DesignBoardsWrite
    public var updateIndex: (JSONValue, UInt64?) async throws -> DesignWriteResult
    public var restore: ([DesignPath: Int], [DesignPath: String]?) async throws -> DesignBoardsWrite
    /// The custom properties the design's project declares (read off the main actor).
    public var projectTokens: () async -> DesignTokens
    /// Whether a write was refused for naming a revision the design moved past: the tab reads the
    /// design again and makes the change once more.
    public var isStale: (any Error) -> Bool

    public init(snapshot: @escaping () async throws -> DesignSnapshot, board: @escaping (DesignPath) async throws -> DesignBoardSource,
                writeBoards: @escaping ([DesignPath: String], UInt64?) async throws -> DesignBoardsWrite,
                updateIndex: @escaping (JSONValue, UInt64?) async throws -> DesignWriteResult,
                restore: @escaping ([DesignPath: Int], [DesignPath: String]?) async throws -> DesignBoardsWrite,
                projectTokens: @escaping () async -> DesignTokens, isStale: @escaping (any Error) -> Bool) {
        self.snapshot = snapshot
        self.board = board
        self.writeBoards = writeBoards
        self.updateIndex = updateIndex
        self.restore = restore
        self.projectTokens = projectTokens
        self.isStale = isStale
    }
}

/// The Tweak tab (DZTweak; docs/designs.md › Tweak): the selected element's inline-style controls
/// and its board's data-props, snapped to the design's tokens.
///
/// While a slider drags, the change shows in the board's live view (`DesignTweakPreviews`)
/// and nothing is written; on release it is written once: an inline-style splice at the parser's
/// offsets on every board in scope (`writeDesignBoards`, one revision), or the data-props value in
/// canvas.json's `tweaks`. Each write names the revision it read; a stale one is read again and
/// made once more. Each kept tweak registers an undo (the boards' versions, or the old values).
@MainActor @Observable
public final class DesignTweakModel {
    public enum Phase: Sendable { case changed, ended }
    public typealias Scope = DesignTweakScope

    /// What the tab shows: its header, its groups and footer, as plain values.
    public struct Presentation: Equatable {
        public var board = ""
        public var element: String?
        public var groups: [DesignTweakGroup] = []
        public var scopeName: String?
        public var scopeNote: String?
        public var canReset = false
        /// A write that didn't go, or a selection Tweak can't edit.
        public var problem: String?
        /// Nothing is selected.
        public var isEmpty = true

        public init(board: String = "", element: String? = nil, groups: [DesignTweakGroup] = [], scopeName: String? = nil,
                    scopeNote: String? = nil, canReset: Bool = false, problem: String? = nil, isEmpty: Bool = true) {
            self.board = board
            self.element = element
            self.groups = groups
            self.scopeName = scopeName
            self.scopeNote = scopeNote
            self.canReset = canReset
            self.problem = problem
            self.isEmpty = isEmpty
        }
    }

    public private(set) var presentation = Presentation()
    public private(set) var target: DesignTweakTarget?
    public var scope: Scope = .board {
        didSet { if scope != oldValue { Task { await rebuild(loadingScope: true) } } }
    }
    /// Tests: writes made (board writes and index updates).
    @ObservationIgnored public private(set) var writes = 0
    /// Tests: previews sent to live views.
    @ObservationIgnored public private(set) var previews = 0

    @ObservationIgnored public weak var undoManager: UndoManager?
    @ObservationIgnored public let designID: DesignID
    @ObservationIgnored private let io: DesignTweakIO
    @ObservationIgnored private weak var host: (any DesignTweakPreviews)?
    /// The design's name for its system, in the scope's note.
    @ObservationIgnored public var systemName = "the design's"
    /// Told when a board's live view previewed a change, so its selection is measured again.
    @ObservationIgnored public var previewed: ((DesignPath) -> Void)?
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
    /// Where each remembered element was in its template (tid → path), so a Reset after a later
    /// write never lands on another element.
    @ObservationIgnored private var originalPaths: [DesignPath: [Int: [Int]]] = [:]
    /// Previews go one at a time; the latest waits.
    @ObservationIgnored private var previewing: Task<Void, Never>?
    @ObservationIgnored private var pendingPreview: [DesignPath: [Int: [String: String?]]]?
    @ObservationIgnored private var pendingProps: (path: DesignPath, json: String)?
    @ObservationIgnored private var loadSerial = 0

    public init(designID: DesignID, io: DesignTweakIO, host: (any DesignTweakPreviews)?) {
        self.designID = designID
        self.io = io
        self.host = host
    }

    // MARK: Loading

    /// The canvas pulled a new snapshot: sources whose hash moved are read again.
    public func snapshotChanged(_ next: DesignSnapshot) async {
        guard snapshot != next else { return }
        snapshot = next
        guard target != nil else { return }
        await rebuild(loadingScope: scope == .every)
    }

    /// The canvas's latest pick changed (nil: nothing selected).
    public func select(_ next: DesignTweakTarget?) async {
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
        for path in Self.canvasOrder(snapshot.index) {
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
                let reach = Self.canvasOrder(snapshot?.index ?? DesignIndex(title: nil)).filter { named[$0] != nil }
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
    public func setStep(_ property: DesignTweakProperty, index: Int, phase: Phase) {
        guard let target, let role = property.role,
              case .steps(let values, _)? = row(.style(property))?.control, values.indices.contains(index) else { return }
        dragging[.style(property)] = Double(index)
        let px = values[index]
        let value = DesignTweakControls.lengthValue(px, role: role, boardTokens: boardTokens(target.board))
        change(property, to: value, phase: phase)
    }

    /// A segmented choice (direction, radius, text size).
    public func choose(_ property: DesignTweakProperty, _ value: String) {
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
    public func choose(_ property: DesignTweakProperty, color: DesignTweakColor) {
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
                // The elements as the board holds them now: an agent's write may have moved them
                // since the change was worked out.
                if !isReset, let target, let refound = try await refind(target) { edits = refound.mapValues { tids in
                    Dictionary(uniqueKeysWithValues: tids.map { ($0, changes.values.first?.values.first ?? [:]) })
                } }
                for (path, elements) in edits {
                    let current = try await source(path)
                    let elements = isReset ? unmoved(elements, on: path, in: current.source) : elements
                    if !isReset { remember(elements, on: path, in: current.source) }
                    guard !elements.isEmpty else { continue }
                    sources[path] = try DesignStyleEdit.apply(elements, in: current.source)
                }
                guard !sources.isEmpty else { throw DesignTweakProblem.elementChanged }
                writes += 1
                let written = try await io.writeBoards(sources, base)
                for (path, text) in sources {
                    if let sha = written.shas[path] { self.sources[path] = DesignBoardSource(path: path, source: text, sha256: sha, revision: written.result.revision) }
                }
                if isReset {
                    originals = originals.filter { changes[$0.key] == nil }
                    originalPaths = originalPaths.filter { changes[$0.key] == nil }
                }
                snapshot = (try? await io.snapshot()) ?? snapshot
                registerUndo(.boards(written.versions, written.shas), name: name)
                report(nil)
                await rebuild(loadingScope: false)
                return
            } catch let error where attempt == 0 && io.isStale(error) {
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
        // The path anchors the element: a write above it moves its tid, not its place.
        guard let template = DesignTemplate(board: source.source),
              let element = template.element(for: id) ?? template.elements.first(where: { $0.path == id.path }) else {
            throw DesignTweakProblem.elementChanged
        }
        if scope == .every, let name = DesignStyleEdit.attribute("data-el", of: element.tid, in: source.source),
           !name.isEmpty, !name.contains("{{") {
            try await loadNamed(name)
            return named
        }
        return [target.board: [element.tid]]
    }

    /// Keeps each element's declared values before this session's first change to them, and
    /// where it was in its template.
    private func remember(_ elements: [Int: [String: String?]], on path: DesignPath, in source: String) {
        let template = DesignTemplate(board: source)
        for (tid, properties) in elements {
            guard let style = DesignStyleEdit.style(of: tid, in: source) else { continue }
            if originalPaths[path]?[tid] == nil, let element = template?.elements[safe: tid] {
                originalPaths[path, default: [:]][tid] = element.path
            }
            for property in properties.keys where originals[path]?[tid]?[property] == nil {
                originals[path, default: [:]][tid, default: [:]][property] = .some(style.value(property))
            }
        }
    }

    /// The elements of a Reset still where they were when remembered: one a later write moved is
    /// left alone rather than having another element's values put on it.
    private func unmoved(_ elements: [Int: [String: String?]], on path: DesignPath, in source: String) -> [Int: [String: String?]] {
        guard let template = DesignTemplate(board: source) else { return [:] }
        return elements.filter { tid, _ in
            guard let remembered = originalPaths[path]?[tid] else { return false }
            return template.elements[safe: tid]?.path == remembered
        }
    }

    // MARK: Props

    /// A data-props control moved (a slider while dragging), or was set.
    public func setProp(_ name: String, _ value: JSONValue, phase: Phase) {
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
    public func setPropChoice(_ name: String, _ title: String) {
        guard let target, let source = sources[target.board]?.source,
              let editor = DesignProps.editors(in: source).first(where: { $0.name == name }),
              let option = editor.options.first(where: { ($0.stringValue ?? $0.doubleValue.map(DesignTweakControls.format)) == title })
        else { return }
        setProp(name, option, phase: .ended)
    }

    /// A prop's text field was submitted: text for a text prop, a number for a number prop.
    public func setPropText(_ name: String, _ text: String) {
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
            } catch let error where attempt == 0 && io.isStale(error) {
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
    public func reset() {
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

    public static func json(_ value: JSONValue) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) }
    }

    public static func describe(_ error: any Error) -> String {
        if let problem = error as? DesignTweakProblem { return problem.description }
        if let refused = error as? DesignStyleEdit.Problem { return refused.description }
        if case RemoteHostClientError.rejected(_, let message) = error { return message }
        return String(describing: error)
    }

    /// The boards back to front: canvas.json's `order`, then any it doesn't list by path.
    static func canvasOrder(_ index: DesignIndex) -> [DesignPath] {
        let listed = index.order.filter { index.boards[$0] != nil }
        let rest = index.boards.keys.filter { !listed.contains($0) }.sorted()
        return listed + rest
    }
}

public enum DesignTweakProblem: Error, CustomStringConvertible {
    case elementChanged

    public var description: String {
        switch self {
        case .elementChanged: "the element changed on its board; select it again"
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
