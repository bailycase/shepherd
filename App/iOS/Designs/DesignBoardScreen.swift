import SwiftUI
import UIKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

/// One board at a time, full screen (MobileDesignBoard): back to the design, the board's label
/// with a dot per board, and Share; the board on the canvas's dot grid, fitted, with its comment
/// pins; a comment's card rising over it; and the toolbar: Comment, Ask the agent, Boards and
/// Export. Pinch zooms, a drag pans a zoomed board, and a sideways swipe on a fitted board moves
/// to the next one. With Comment on, a tap names the element under it and a comment goes there.
///
/// Tweak (the toolbar's): a tap picks the element, and the iPad's Tweak controls rise in a sheet
/// over the board, previewing on it and writing through the host (`DesignTweakModel`). Play (the
/// board actions, an interactive board): the board takes touches itself and its links turn to
/// their boards; Done ends it. A phone shows one board at a time, so there is no board to move.
///
/// The board is the one live web view on screen (`DesignLiveBoard`); every write goes to the host.
struct DesignBoardScreen: View {
    let ref: HostDesignRef
    let path: DesignPath?
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator
    @Environment(ThreadStores.self) private var threads
    @State private var model: DesignBoardModel?
    @State private var watchToken = UUID()

    var body: some View {
        Group {
            if let model {
                DesignBoardContent(model: model) { ask(model) }
            } else {
                Color.sh.bgBase
            }
        }
        .onAppear {
            let designs = MobileDesigns.of(hosts)
            let made = model ?? DesignBoardModel(ref: ref, designs: designs, initial: path)
            model = made
            DesignBoardModel.onScreen = made
            designs.watch(ref, on: true, token: watchToken) { [weak made] changed, files, comments in
                guard let made, changed == made.ref else { return }
                Task { await made.hostChanged(files: files, comments: comments) }
            }
            Task { await made.load() }
        }
        .onDisappear {
            MobileDesigns.of(hosts).watch(ref, on: false, token: watchToken)
            model?.close()
            if DesignBoardModel.onScreen === model { DesignBoardModel.onScreen = nil }
        }
        .onChange(of: MobileDesigns.of(hosts).page(ref)) { model?.pageChanged() }
        .onChange(of: DesignBoardJump.shared.target) { _, target in
            guard let target, target.ref == ref else { return }
            model?.show(target.path)
        }
    }

    /// Ask the agent: its thread, with what the board screen shows riding the next message.
    private func ask(_ model: DesignBoardModel) {
        guard let agent = model.designs.agent(ref) else { return }
        threads.store(for: agent).designContext = { [weak model] in model?.viewRecord }
        navigator.open(.thread(agent))
    }
}

/// Everything one board screen shows and does: the board on screen and its neighbors, the
/// canvas's zoom and pan, the comment picked or being written, and the pins' places.
@MainActor
@Observable
final class DesignBoardModel {
    let ref: HostDesignRef
    @ObservationIgnored let designs: MobileDesigns
    private(set) var current: DesignPath?
    private(set) var live: DesignLiveBoard?
    /// Comment is on: a tap names an element to comment on.
    var commenting = false {
        didSet { if commenting { tweaking = false } }
    }
    /// Tweak is on: a tap picks the element its controls change.
    var tweaking = false {
        didSet {
            guard tweaking != oldValue else { return }
            if tweaking { commenting = false } else { tweakPick = nil }
        }
    }
    /// The element Tweak changes (nil: the board whole).
    private(set) var tweakPick: DesignPick?
    /// Play: the board takes touches itself.
    private(set) var playing = false
    /// Tweak's model, shared with the iPad and the Mac: its writes go to the host.
    @ObservationIgnored private(set) lazy var tweak: DesignTweakModel? = designs.library(ref.host).map { library in
        let model = DesignTweakModel(designID: ref.design, io: PadDesignCanvas.tweakIO(library, source: library.source(ref.design),
                                                                                       design: ref.design), host: self)
        model.previewed = { [weak self] _ in Task { await self?.measurePins() } }
        if let system = designs.design(ref)?.systemNamespace { model.systemName = system }
        return model
    }
    /// The comment whose card is up.
    var selected: UUID? {
        didSet { if selected != oldValue { replyText = "" } }
    }
    var replyText = ""
    /// The element a comment is being written on, and its words.
    private(set) var draft: DesignPick?
    var draftText = ""
    private(set) var sending = false
    private(set) var problem: String?
    /// Where each pinned comment's element is drawn now (board points).
    private(set) var pinRects: [UUID: CGRect] = [:]
    /// The fitted board's zoom multiple (1 fits) and pan, at rest.
    var zoom: CGFloat = 1
    var pan: CGSize = .zero
    /// A file Export or Share made, for the share sheet.
    var shared: SharedFile?

    @ObservationIgnored private let initial: DesignPath?
    @ObservationIgnored private var opened = false
    /// The board screen showing now (the screenshot fixtures reach it here).
    static weak var onScreen: DesignBoardModel?

    init(ref: HostDesignRef, designs: MobileDesigns, initial: DesignPath?) {
        self.ref = ref
        self.designs = designs
        self.initial = initial
    }

    var index: DesignIndex? { designs.indexes[ref]?.snapshot.index }
    /// The boards of the shown board's page (every board on a canvas without pages): the dots and
    /// the steps between boards stay on it.
    var boards: [DesignPath] {
        index.map { index in RemoteDesignPresentation.boards(index, page: current.flatMap(index.page(of:)) ?? designs.page(ref)) } ?? []
    }
    var board: DesignIndex.Board? { current.flatMap { index?.boards[$0] } }
    var label: String { current.flatMap { path in index.map { RemoteDesignPresentation.label(path, in: $0) } } ?? "" }
    var pins: [DesignComment] { current.map { RemoteDesignPresentation.pins(designs.comments[ref], board: $0) } ?? [] }

    func load() async {
        async let comments: Void = designs.loadComments(ref)
        let index = await designs.sync(ref)
        _ = await comments
        if let index { await tweak?.snapshotChanged(index.snapshot) }
        if current == nil, let index {
            // The route's board opens once; back on an empty page, the page's first board (none).
            let boards = RemoteDesignPresentation.boards(index.snapshot.index)
            show((opened ? nil : initial).flatMap { boards.contains($0) ? $0 : nil } ?? self.boards.first)
            opened = true
        } else if live == nil {
            reopen()
        }
        await measurePins()
    }

    /// The screen came back (from the agent's thread, say) after giving up its web view: the
    /// board it showed goes live again where it was.
    private func reopen() {
        guard let current, let board, let source = designs.source(ref) else { return }
        live = DesignLiveBoard(ref: ref, path: current, size: CGSize(width: board.w, height: board.h), source: source)
        wire(live)
    }

    /// A live board's links turn to their boards while it plays.
    private func wire(_ live: DesignLiveBoard?) {
        live?.playing = playing
        live?.linked = { [weak self] target in self?.show(target) }
    }

    /// Shows `path`: its web view replaces the last board's, so one board is live at a time.
    func show(_ path: DesignPath?) {
        guard let path, path != current, let board = index?.boards[path], let source = designs.source(ref) else { return }
        live?.close()
        current = path
        zoom = 1
        pan = .zero
        draft = nil
        draftText = ""
        selected = nil
        tweakPick = nil
        pinRects = [:]
        live = DesignLiveBoard(ref: ref, path: path, size: CGSize(width: board.w, height: board.h), source: source)
        wire(live)
        if playing, index?.boards[path]?.isInteractive != true { play(false) }
        // The board's page is the design's page shown, here and on the iPad's canvas.
        if let page = index?.page(of: path) { designs.showPage(ref, page) }
    }

    /// Another page was chosen (the Boards sheet's title menu, or the design's other screens):
    /// its first board shows.
    /// A page with no boards shows none: no board, no dots, until a page with boards is chosen.
    func pageChanged() {
        // Before the screen opened its board, the page arriving with the design's index isn't a
        // choice: the route's board opens (`load`).
        guard opened, let index, let page = designs.page(ref) else { return }
        if let current, index.isOnPage(current, page) { return }
        if let first = RemoteDesignPresentation.boards(index, page: page).first {
            show(first)
        } else if current != nil {
            if playing { play(false) }
            live?.close()
            live = nil
            current = nil
            draft = nil
            draftText = ""
            selected = nil
            tweakPick = nil
            tweaking = false
            commenting = false
            pinRects = [:]
        }
    }

    var pageName: String? {
        guard let index, let page = designs.page(ref) else { return nil }
        return RemoteDesignPresentation.pages(index).first { $0.id == page }?.name
    }

    // MARK: Play

    /// The board on screen is interactive: it can play.
    var canPlay: Bool { board?.isInteractive == true }

    func play(_ on: Bool) {
        let on = on && canPlay
        guard playing != on else { return }
        playing = on
        if on {
            commenting = false
            tweaking = false
            zoom = 1
            pan = .zero
            cancelDraft()
            selected = nil
        }
        live?.playing = on
    }

    // MARK: Tweak

    /// What Tweak changes: the element picked, else the board whole.
    var tweakTarget: DesignTweakTarget? {
        guard tweaking, let current else { return nil }
        guard let pick = tweakPick, let element = DesignElementID(board: current.viewName, tid: pick.tid, path: pick.path) else {
            return DesignTweakTarget(board: current, element: nil, kind: .other, tag: nil)
        }
        return DesignTweakTarget(board: current, element: element, kind: pick.kind, tag: pick.tag)
    }

    /// The next board (`step` 1) or the one before (-1), stopping at either end.
    func step(_ step: Int) {
        guard let current, let at = boards.firstIndex(of: current) else { return }
        let next = at + step
        guard boards.indices.contains(next) else { return }
        show(boards[next])
    }

    func close() {
        live?.close()
        live = nil
    }

    /// The host changed the design's files or its comments: read what moved, and redraw the board
    /// in place when its own file changed.
    func hostChanged(files: Bool, comments: Bool) async {
        if comments { await designs.loadComments(ref) }
        if files {
            let before = current.flatMap { designs.indexes[ref]?.snapshot.boards[$0] }
            await designs.sync(ref)
            let after = current.flatMap { designs.indexes[ref]?.snapshot.boards[$0] }
            if let snapshot = designs.indexes[ref]?.snapshot { await tweak?.snapshotChanged(snapshot) }
            if let current, index?.boards[current] == nil {
                self.current = nil
                show(boards.first)
            } else if before != after {
                await live?.reload()
            }
        }
        await measurePins()
    }

    /// Finds each pin's element where the board draws it now, else where it was when pinned.
    func measurePins() async {
        var rects: [UUID: CGRect] = [:]
        for comment in pins {
            if let rect = await live?.rect(tid: comment.tid) {
                rects[comment.id] = rect
            } else if let rect = comment.rect {
                rects[comment.id] = CGRect(x: rect.x, y: rect.y, width: rect.w, height: rect.h)
            }
        }
        if rects != pinRects { pinRects = rects }
    }

    // MARK: Comments

    /// A tap on the board at `point` (board points).
    func tap(at point: CGPoint) async {
        if tweaking {
            tweakPick = await live?.pick(at: point)
            return
        }
        guard commenting else {
            selected = nil
            return
        }
        guard let pick = await live?.pick(at: point) else { return }
        selected = nil
        draft = pick
    }

    func cancelDraft() {
        draft = nil
        draftText = ""
    }

    /// Pins the comment on the host; the card of what it kept comes up.
    func sendDraft() async {
        guard let draft, let current, let text = DesignComment.text(draftText), !sending else {
            if DesignComment.text(draftText) == nil { cancelDraft() }
            return
        }
        sending = true
        defer { sending = false }
        let rect = DesignCommentRect(x: draft.rect.minX, y: draft.rect.minY, w: draft.rect.width, h: draft.rect.height)
        let comment = DesignCommentDraft(board: current, tid: draft.tid, path: draft.path, label: draft.label,
                                         target: draft.name ?? draft.label, rect: rect.isValid ? rect : nil, text: text)
        do {
            let kept = try await designs.addComment(ref, draft: comment)
            cancelDraft()
            selected = kept.id
            problem = nil
        } catch {
            problem = MobileDesignsError.words(error)
        }
        await measurePins()
    }

    func updateComment(resolve: Bool) async {
        guard let id = selected, !sending else { return }
        let text = DesignComment.text(replyText)
        guard resolve || text != nil else { return }
        sending = true
        defer { sending = false }
        do {
            _ = try await designs.writeComment(ref) { revision in
                resolve ? .resolveComment(designID: ref.design, commentID: id, resolved: true, baseRevision: revision)
                    : .replyToComment(designID: ref.design, commentID: id, text: text ?? "", baseRevision: revision)
            }
            if selected == id {
                replyText = ""
                if resolve { selected = nil }
            }
            problem = nil
        } catch {
            problem = MobileDesignsError.words(error)
        }
    }

    /// Picks an element as the tap would, for a screen that shows one being commented on.
    func pickForComment(at point: CGPoint) async {
        commenting = true
        await tap(at: point)
    }

    /// What the phone shows, for a message to the design agent.
    var viewRecord: DesignViewRecord? {
        guard let current else { return nil }
        if playing { return DesignViewRecord(mode: .focused, visibleBoards: [current.viewName]) }
        let element = draft.flatMap { DesignElementID(board: current.viewName, tid: $0.tid, path: $0.path) }
        return RemoteDesignPresentation.viewRecord(board: current, picked: element, kind: draft?.kind, label: draft?.label)
    }

    func duplicate() async {
        guard let current, !sending, let library = designs.library(ref.host) else { return }
        sending = true
        defer { sending = false }
        do {
            let result: RemoteDesignResult
            do {
                result = try await library.request(.duplicateBoard(designID: ref.design, path: current.rawValue,
                                                                    baseRevision: designs.indexes[ref]?.snapshot.revision))
            } catch RemoteHostClientError.rejected(let code, _) where code == "stale_revision" {
                guard let fresh = await designs.sync(ref) else { throw MobileDesignsError.unexpected }
                result = try await library.request(.duplicateBoard(designID: ref.design, path: current.rawValue,
                                                                    baseRevision: fresh.snapshot.revision))
            }
            guard case .duplicated(let copy, _) = result else { throw MobileDesignsError.unexpected }
            await designs.sync(ref)
            show(copy)
        } catch {
            problem = MobileDesignsError.words(error)
        }
    }

    // MARK: Export

    func export(_ format: DesignExportFormat) async {
        guard let current, let board, let source = designs.source(ref) else { return }
        do {
            let url = try await DesignRendering.shared.export(ref, source: source, path: current, board: board, name: label, format: format)
            shared = SharedFile(url: url)
            problem = nil
        } catch {
            problem = "Couldn't export \(label): \(MobileDesignsError.words(error))"
        }
    }

    func dismissProblem() { problem = nil }

    // MARK: References (design.references.v1)

    /// Copy Reference's words, until dismissed.
    var notice: String?
    /// Implement in a Thread…'s sheet, while it is up.
    var implementing: DesignImplementModel?

    /// What Implement and Copy Reference hand over: the element picked (Tweak's or Comment's),
    /// else the board on screen.
    var referencePick: DesignReferencePick? {
        guard let current else { return nil }
        if let pick = tweakPick ?? draft, let element = DesignElementID(board: current.viewName, tid: pick.tid, path: pick.path),
           let reference = DesignReference(designID: ref.design, board: current, element: element) {
            return DesignReferencePick(ref: ref, reference: reference, piece: pick.name.map { "\(pick.noun) “\($0)”" } ?? pick.tag)
        }
        return DesignReference(designID: ref.design, board: current).map { DesignReferencePick(ref: ref, reference: $0, piece: label) }
    }

    var takesReferences: Bool { designs.supports(ref.host, RemoteProtocol.designReferencesCapability) }

    func implement() {
        guard let pick = referencePick else { return }
        implementing = DesignImplementModel(pick: pick, threads: designs.referenceThreads(host: ref.host))
    }

    func copyReference() async {
        guard let pick = referencePick else { return }
        do {
            notice = try await designs.copyReference(pick)
            problem = nil
        } catch {
            problem = "Couldn't copy a reference: \(MobileDesignsError.words(error))"
        }
    }
}

/// Tweak previews on the board on screen, whichever it is.
extension DesignBoardModel: DesignTweakPreviews {
    func previewStyle(_ path: DesignPath, _ changes: [Int: [String: String?]]) async -> Bool {
        guard let live, live.path == path else { return false }
        return await live.previewStyle(changes)
    }

    func previewProps(_ path: DesignPath, _ json: String) async -> Bool {
        guard let live, live.path == path else { return false }
        return await live.previewProps(json)
    }

    func endPreview(_ path: DesignPath) async {
        guard let live, live.path == path else { return }
        await live.endPreview()
    }
}

/// A file for the share sheet.
struct SharedFile: Identifiable {
    let url: URL
    var id: URL { url }
}

/// The board screen's content, drawn from its model.
private struct DesignBoardContent: View {
    @Bindable var model: DesignBoardModel
    let ask: () -> Void
    @Environment(MobileNavigator.self) private var navigator
    @State private var exporting = false
    @State private var confirmingDuplicate = false

    var body: some View {
        VStack(spacing: 0) {
            DesignBoardCanvas(model: model)
                // The keyboard never refits the board: the comment being written rises over it.
                .ignoresSafeArea(.keyboard)
                .overlay(alignment: .bottom) { cardLayer }
            if model.playing {
                // Play's own bar: the board takes every touch until Done.
                HStack {
                    Text("Playing \(model.label)").shText(.caption).foregroundStyle(Color.sh.textSecondary).lineLimit(1)
                    Spacer(minLength: SH.Space.m)
                    Button("Done") { model.play(false) }.buttonStyle(.sh(.secondary))
                }
                .padding(.horizontal, MobileLayout.gutter)
                .padding(.vertical, SH.Space.m)
                .background(Color.sh.bgWindow)
            } else {
            SHBoardToolbar(tools: DesignBoardTools.all,
                           active: model.commenting ? DesignBoardTools.comment : model.tweaking ? DesignBoardTools.tweak : nil,
                           disabled: Set(model.designs.agent(model.ref) == nil ? [DesignBoardTools.ask] : [])
                               .union(model.current == nil ? [DesignBoardTools.comment, DesignBoardTools.tweak, DesignBoardTools.export] : [])) { id in
                switch id {
                case DesignBoardTools.comment:
                    model.commenting.toggle()
                    if !model.commenting { model.cancelDraft() }
                case DesignBoardTools.tweak:
                    model.tweaking.toggle()
                case DesignBoardTools.ask: ask()
                case DesignBoardTools.boards:
                    navigator.present(.designs(.boards(model.ref, current: model.current?.rawValue ?? "")))
                default: exporting = true
                }
            }
            }
        }
        .sheet(isPresented: Binding(get: { model.tweaking && model.tweak != nil }, set: { if !$0 { model.tweaking = false } })) {
            if let tweak = model.tweak {
                PadDesignTweakPane(model: tweak, target: model.tweakTarget) {
                    model.tweaking = false
                    ask()
                }
                .padding(.top, SH.Space.l)
                // Opaque: the controls read over the board, not through it.
                .presentationBackground(Color.sh.bgWindow)
                .presentationDetents([.fraction(MobileDesignLayout.tweakSheetFraction), .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .fraction(MobileDesignLayout.tweakSheetFraction)))
            }
        }
        .background(Color.sh.bgWindow)
        .navigationBarTitleDisplayMode(.inline)
        // The board's own toolbar takes the bottom edge (MobileDesignBoard).
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                // With pages, the title is the page menu (the grid's title menu, kept with the dots).
                if model.designs.hasPages(model.ref) {
                    Menu { DesignPagePicker(ref: model.ref) } label: {
                        HStack(spacing: SH.Space.xs) {
                            boardTitle
                            Image(systemName: "chevron.down").font(.sh(.caption, weight: .semibold))
                                .foregroundStyle(Color.sh.textTertiary)
                        }
                        .frame(minHeight: SH.Height.touch)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Page")
                    .accessibilityValue(model.pageName ?? "")
                } else {
                    boardTitle
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Share", systemImage: "square.and.arrow.up") { Task { await model.export(.png) } }
                    if model.canPlay {
                        Button("Play", systemImage: "play") { model.play(true) }
                    }
                    if model.takesReferences {
                        Divider()
                        Button("Implement in a Thread…", systemImage: "chevron.left.forwardslash.chevron.right") { model.implement() }
                        Button("Copy Reference", systemImage: "link") { Task { await model.copyReference() } }
                    }
                    Button("Duplicate Board…") { confirmingDuplicate = true }
                } label: {
                    Label("Board actions", systemImage: "ellipsis")
                }
                .disabled(model.current == nil || model.sending)
            }
        }
        .confirmationDialog("Duplicate \(model.label)?", isPresented: $confirmingDuplicate, titleVisibility: .visible) {
            Button("Duplicate Board") { Task { await model.duplicate() } }
        }
        .confirmationDialog("Export \(model.label)", isPresented: $exporting, titleVisibility: .visible) {
            ForEach(DesignExportFormat.allCases) { format in
                Button(format.title) { Task { await model.export(format) } }
            }
        }
        .sheet(item: $model.implementing) { implementing in
            DesignImplementSheet(model: implementing) { target, opens in
                if opens { navigator.open(.thread(target)) }
                else { model.notice = "Sent \(implementing.pick.piece) to \(model.designs.referenceThreads(host: target.host).first { $0.id == target.agent }?.name ?? "the thread")." }
            }
        }
        .sheet(item: $model.shared) { file in
            DesignShareSheet(url: file.url).ignoresSafeArea()
        }
    }

    /// The board's label over a dot per board of its page; the page's name on an empty one.
    private var boardTitle: some View {
        VStack(spacing: SH.Space.xxs) {
            Text(model.current == nil ? model.pageName ?? "" : model.label)
                .font(.shSans(SHPhoneDesignMetrics.boardTitleSize, .semibold))
                .foregroundStyle(Color.sh.textPrimary)
                .lineLimit(1)
            if model.boards.count > 1, let current = model.current {
                SHBoardDots(count: model.boards.count, current: model.boards.firstIndex(of: current) ?? 0)
            }
        }
    }

    /// The comment picked, or the one being written, over the board above the toolbar.
    @ViewBuilder private var cardLayer: some View {
        VStack(spacing: SH.Space.m) {
            if let notice = model.notice {
                Button { model.notice = nil } label: {
                    Label(notice, systemImage: SHGlyph.resolved.symbolName).shText(.caption).foregroundStyle(Color.sh.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(SH.Space.l)
                        .shPopover(radius: SHPhoneDesignMetrics.cardRadius)
                }
                .buttonStyle(.plain)
                .task(id: notice) {
                    try? await Task.sleep(for: MobileDesignLayout.noticeLifetime)
                    if model.notice == notice { model.notice = nil }
                }
            }
            if let problem = model.problem {
                Button { model.dismissProblem() } label: {
                    Text(problem).shText(.caption).foregroundStyle(Color.sh.failed)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(SH.Space.l)
                        .shPopover(radius: SHPhoneDesignMetrics.cardRadius)
                }
                .buttonStyle(.plain)
            }
            if let draft = model.draft {
                DesignCommentDraftCard(model: model, target: draft.name ?? draft.label ?? draft.noun)
            } else if let id = model.selected, let comment = model.pins.first(where: { $0.id == id }) {
                SHCommentThread(
                    author: comment.author == .agent ? "Design agent" : "You",
                    age: shCommentAge(since: comment.createdAt, now: .now),
                    note: comment.detached ? "element changed" : nil, text: comment.text,
                    entries: comment.replies.map { reply in
                        SHCommentEntry(id: reply.id.uuidString, author: reply.author == .agent ? "Design agent" : "You",
                                       age: shCommentAge(since: reply.createdAt, now: .now), text: reply.text)
                    }, reply: $model.replyText,
                    onResolve: { Task { await model.updateComment(resolve: true) } },
                    onReply: { Task { await model.updateComment(resolve: false) } },
                    onClose: { model.selected = nil })
                    .disabled(model.sending)
            }
        }
        .padding(.horizontal, MobileDesignLayout.cardInset)
        .padding(.bottom, MobileDesignLayout.cardInset)
    }
}

/// Writing a comment on the element picked: the review's comment editor, where its card will be.
private struct DesignCommentDraftCard: View {
    @Bindable var model: DesignBoardModel
    let target: String
    @FocusState private var focused: Bool

    var body: some View {
        SHCommentEditor(text: $model.draftText, isFocused: $focused, placeholder: "Comment for the design agent",
                        context: "on \(model.label) · \(target)",
                        onSave: { Task { await model.sendDraft() } }, onCancel: { model.cancelDraft() })
            .disabled(model.sending)
    }
}

/// The board on the canvas's dot grid: fitted under the navigation, pinch to zoom and drag to
/// pan (a sideways swipe on a fitted board turns to the next), the pins on their elements, and
/// the element being commented on ringed.
private struct DesignBoardCanvas: View {
    @Bindable var model: DesignBoardModel
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            let space = CGSize(width: proxy.size.width - 2 * MobileLayout.gutter,
                               height: proxy.size.height - 2 * MobileDesignLayout.boardTop)
            ZStack(alignment: .top) {
                SHDotGrid(spacing: SHDesignMetrics.gridSpacing)
                    .background(Color.sh.bgBase)
                    .contentShape(Rectangle())
                    .onTapGesture { model.selected = nil }
                if let live = model.live, let board = model.board {
                    let size = CGSize(width: board.w, height: board.h)
                    let fit = RemoteDesignPresentation.fit(size, in: space)
                    let scale = fit * model.zoom
                    let shown = CGSize(width: size.width * scale, height: size.height * scale)
                    let panning = model.zoom > 1 ? drag : .zero
                    boardLayer(live, size: shown, scale: scale)
                        .scaleEffect(pinch, anchor: .center)
                        .offset(x: model.pan.width + panning.width, y: model.pan.height + panning.height)
                        .padding(.top, MobileDesignLayout.boardTop)
                        .frame(maxWidth: .infinity)
                        .task(id: live.drawn) { await model.measurePins() }
                } else if model.current == nil, model.pageName != nil {
                    SHEmptyState(Text("No boards on this page"), message: "Choose another page from the title.", showsMark: false)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .clipped()
            // Playing, the board takes every touch itself.
            .gesture(gestures(space: proxy.size), isEnabled: !model.playing)
        }
    }

    private func boardLayer(_ live: DesignLiveBoard, size: CGSize, scale: CGFloat) -> some View {
        SHBoardSurface(size: size, selected: false) {
            DesignLiveBoardView(board: live, zoom: scale)
                .frame(width: size.width, height: size.height)
                .overlay {
                    if !live.booted {
                        if live.failure != nil {
                            Text(live.failure ?? "").shText(.caption).foregroundStyle(Color.sh.textTertiary)
                        } else {
                            ProgressView().progressViewStyle(.shSpinner)
                        }
                    }
                }
        }
        .overlay(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                if !model.playing {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(coordinateSpace: .local) { location in
                            Task { await model.tap(at: CGPoint(x: location.x / scale, y: location.y / scale)) }
                        }
                }
                if let pick = model.tweakPick {
                    SHSelectionRing(.selected, tag: pick.tag)
                        .frame(width: pick.rect.width * scale, height: pick.rect.height * scale)
                        .offset(x: pick.rect.minX * scale, y: pick.rect.minY * scale)
                        .allowsHitTesting(false)
                }
                if let draft = model.draft {
                    SHSelectionRing(.selected, tag: draft.tag)
                        .frame(width: draft.rect.width * scale, height: draft.rect.height * scale)
                        .offset(x: draft.rect.minX * scale, y: draft.rect.minY * scale)
                        .allowsHitTesting(false)
                }
                // Playing, the board is the design as it runs: no pins over it.
                ForEach(model.playing ? [] : model.pins) { comment in
                    if let rect = model.pinRects[comment.id] {
                        Button { model.selected = comment.id } label: { SHCommentPin(comment.number) }
                            .buttonStyle(.plain)
                            .frame(width: SHDesignMetrics.pinSize, height: SHDesignMetrics.pinSize)
                            .offset(x: rect.maxX * scale - SHDesignMetrics.pinSize / 2, y: rect.minY * scale - SHDesignMetrics.pinSize / 2)
                            .accessibilityLabel("Comment \(comment.number) on \(RemoteDesignPresentation.target(comment))")
                    }
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
    }

    private func gestures(space: CGSize) -> some Gesture {
        SimultaneousGesture(
            MagnifyGesture()
                .updating($pinch) { value, state, _ in state = value.magnification }
                .onEnded { value in
                    model.zoom = RemoteDesignPresentation.clampZoom(model.zoom * value.magnification)
                    if model.zoom == 1 { model.pan = .zero }
                },
            DragGesture(minimumDistance: SH.Space.l)
                .updating($drag) { value, state, _ in state = value.translation }
                .onEnded { value in
                    if model.zoom > 1 {
                        let next = CGSize(width: model.pan.width + value.translation.width, height: model.pan.height + value.translation.height)
                        let board = model.board.map { CGSize(width: $0.w, height: $0.h) } ?? .zero
                        let fitted = RemoteDesignPresentation.fit(board, in: space) * model.zoom
                        model.pan = RemoteDesignPresentation.clampPan(next, content: CGSize(width: board.width * fitted,
                                                                                            height: board.height * fitted), space: space)
                    } else if abs(value.translation.width) > MobileDesignLayout.swipeDistance,
                              abs(value.translation.width) > abs(value.translation.height) {
                        model.step(value.translation.width < 0 ? 1 : -1)
                    }
                })
    }
}

/// The board's toolbar, as MobileDesignBoard draws it.
enum DesignBoardTools {
    static let comment = "comment"
    static let ask = "ask"
    static let tweak = "tweak"
    static let boards = "boards"
    static let export = "export"

    static let all: [SHBoardToolbar.Tool] = [
        .init(id: comment, title: "Comment", symbol: "text.bubble"),
        .init(id: tweak, title: "Tweak", symbol: "slider.horizontal.3"),
        .init(id: ask, title: "Ask the agent", symbol: "sparkle"),
        .init(id: boards, title: "Boards", symbol: "square.grid.2x2"),
        .init(id: export, title: "Export", symbol: "square.and.arrow.up"),
    ]
}

/// The system's share sheet for an exported board.
struct DesignShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
