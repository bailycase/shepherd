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
                Color.nw.bgBase
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
    var commenting = false
    /// The comment whose card is up.
    var selected: UUID?
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
    /// The board screen showing now (the screenshot fixtures reach it here).
    static weak var onScreen: DesignBoardModel?

    init(ref: HostDesignRef, designs: MobileDesigns, initial: DesignPath?) {
        self.ref = ref
        self.designs = designs
        self.initial = initial
    }

    var index: DesignIndex? { designs.indexes[ref]?.snapshot.index }
    var boards: [DesignPath] { index.map(RemoteDesignPresentation.boards) ?? [] }
    var board: DesignIndex.Board? { current.flatMap { index?.boards[$0] } }
    var label: String { current.flatMap { path in index.map { RemoteDesignPresentation.label(path, in: $0) } } ?? "" }
    var pins: [DesignComment] { current.map { RemoteDesignPresentation.pins(designs.comments[ref], board: $0) } ?? [] }

    func load() async {
        async let comments: Void = designs.loadComments(ref)
        let index = await designs.sync(ref)
        _ = await comments
        if current == nil, let index {
            let boards = RemoteDesignPresentation.boards(index.snapshot.index)
            show(initial.flatMap { boards.contains($0) ? $0 : nil } ?? boards.first)
        }
        await measurePins()
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
        pinRects = [:]
        live = DesignLiveBoard(ref: ref, path: path, size: CGSize(width: board.w, height: board.h), source: source)
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

    /// Picks an element as the tap would, for a screen that shows one being commented on.
    func pickForComment(at point: CGPoint) async {
        commenting = true
        await tap(at: point)
    }

    /// What the phone shows, for a message to the design agent.
    var viewRecord: DesignViewRecord? {
        guard let current else { return nil }
        let element = draft.flatMap { DesignElementID(board: current.viewName, tid: $0.tid, path: $0.path) }
        return RemoteDesignPresentation.viewRecord(board: current, picked: element, kind: draft?.kind, label: draft?.label)
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

    var body: some View {
        VStack(spacing: 0) {
            DesignBoardCanvas(model: model)
                // The keyboard never refits the board: the comment being written rises over it.
                .ignoresSafeArea(.keyboard)
                .overlay(alignment: .bottom) { cardLayer }
            NWBoardToolbar(tools: DesignBoardTools.all, active: model.commenting ? DesignBoardTools.comment : nil,
                           disabled: model.designs.agent(model.ref) == nil ? [DesignBoardTools.ask] : []) { id in
                switch id {
                case DesignBoardTools.comment:
                    model.commenting.toggle()
                    if !model.commenting { model.cancelDraft() }
                case DesignBoardTools.ask: ask()
                case DesignBoardTools.boards:
                    navigator.present(.designs(.boards(model.ref, current: model.current?.rawValue ?? "")))
                default: exporting = true
                }
            }
        }
        .background(Color.nw.bgWindow)
        .navigationBarTitleDisplayMode(.inline)
        // The board's own toolbar takes the bottom edge (MobileDesignBoard).
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: NW.Space.xxs) {
                    Text(model.label)
                        .font(.nwSans(NWPhoneDesignMetrics.boardTitleSize, .semibold))
                        .foregroundStyle(Color.nw.textPrimary)
                        .lineLimit(1)
                    if model.boards.count > 1, let current = model.current {
                        NWBoardDots(count: model.boards.count, current: model.boards.firstIndex(of: current) ?? 0)
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Share", systemImage: "square.and.arrow.up") { Task { await model.export(.png) } }
                    .disabled(model.current == nil)
            }
        }
        .confirmationDialog("Export \(model.label)", isPresented: $exporting, titleVisibility: .visible) {
            ForEach(DesignExportFormat.allCases) { format in
                Button(format.title) { Task { await model.export(format) } }
            }
        }
        .sheet(item: $model.shared) { file in
            DesignShareSheet(url: file.url).ignoresSafeArea()
        }
    }

    /// The comment picked, or the one being written, over the board above the toolbar.
    @ViewBuilder private var cardLayer: some View {
        VStack(spacing: NW.Space.m) {
            if let problem = model.problem {
                Button { model.dismissProblem() } label: {
                    Text(problem).nwText(.caption).foregroundStyle(Color.nw.failed)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(NW.Space.l)
                        .nwPopover(radius: NWPhoneDesignMetrics.cardRadius)
                }
                .buttonStyle(.plain)
            }
            if let draft = model.draft {
                DesignCommentDraftCard(model: model, target: draft.name ?? draft.label ?? draft.noun)
            } else if let id = model.selected, let comment = model.pins.first(where: { $0.id == id }) {
                let working = model.designs.agentWorking(model.ref)
                let answer = RemoteDesignPresentation.answer(comment)
                NWPhoneCommentCard(number: comment.number, target: RemoteDesignPresentation.target(comment),
                                   meta: RemoteDesignPresentation.meta(comment.author, at: comment.createdAt, now: .now),
                                   text: comment.text,
                                   status: RemoteDesignPresentation.updating(comment, agentWorking: working, board: model.label),
                                   answer: answer.map { NWCommentEntry(id: $0.id.uuidString, author: "Design agent",
                                                                       age: RemoteDesignPresentation.age($0.createdAt, now: .now), text: $0.text) })
                .equatable()
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
        NWCommentEditor(text: $model.draftText, isFocused: $focused, placeholder: "Comment for the design agent",
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
                NWDotGrid(spacing: NWDesignMetrics.gridSpacing)
                    .background(Color.nw.bgBase)
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
                }
            }
            .clipped()
            .gesture(gestures(space: proxy.size))
        }
    }

    private func boardLayer(_ live: DesignLiveBoard, size: CGSize, scale: CGFloat) -> some View {
        NWBoardSurface(size: size, selected: false) {
            DesignLiveBoardView(board: live, zoom: scale)
                .frame(width: size.width, height: size.height)
                .overlay {
                    if !live.booted {
                        if live.failure != nil {
                            Text(live.failure ?? "").nwText(.caption).foregroundStyle(Color.nw.textTertiary)
                        } else {
                            ProgressView().progressViewStyle(.nwSpinner)
                        }
                    }
                }
        }
        .overlay(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { location in
                        Task { await model.tap(at: CGPoint(x: location.x / scale, y: location.y / scale)) }
                    }
                if let draft = model.draft {
                    NWSelectionRing(.selected, tag: draft.tag)
                        .frame(width: draft.rect.width * scale, height: draft.rect.height * scale)
                        .offset(x: draft.rect.minX * scale, y: draft.rect.minY * scale)
                        .allowsHitTesting(false)
                }
                ForEach(model.pins) { comment in
                    if let rect = model.pinRects[comment.id] {
                        Button { model.selected = comment.id } label: { NWCommentPin(comment.number) }
                            .buttonStyle(.plain)
                            .frame(width: NWDesignMetrics.pinSize, height: NWDesignMetrics.pinSize)
                            .offset(x: rect.maxX * scale - NWDesignMetrics.pinSize / 2, y: rect.minY * scale - NWDesignMetrics.pinSize / 2)
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
            DragGesture(minimumDistance: NW.Space.l)
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
    static let boards = "boards"
    static let export = "export"

    static let all: [NWBoardToolbar.Tool] = [
        .init(id: comment, title: "Comment", symbol: "text.bubble"),
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
