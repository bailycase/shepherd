import SwiftUI
import UIKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

/// One design on iPad (iPadDesign): the canvas under its header ("‹ Designs", the name, the
/// design system's chip, Export) beside the 360pt chat pane with its Chat · Tweak · Comments tabs.
/// The boards render on this iPad from the files the host serves; every change goes to the host.
///
/// In a narrow window (Split View beside a thread, iPadSplitView) the canvas takes the window, the
/// header's chat button opens the pane, and the design agent's latest reply floats over the
/// canvas with "Send to the thread" when another window shows a thread.
///
/// On screen, the design takes its live views and its host pushes its changes; hidden, it gives
/// them up (`PadDesigns.setVisible`). The sidebar stays out while a design shows, as the board
/// draws it.
struct PadDesignScreen: View {
    let ref: PadDesignRef
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator
    @Environment(ThreadStores.self) private var threads
    @Environment(\.dismiss) private var dismiss
    @State private var showingChat = false
    @State private var exporting: [URL]?

    var body: some View {
        let designs = PadDesigns.of(hosts)
        let canvas = designs.canvas(ref)
        let design = designs.design(ref)
        let agent = design?.agentID.map { AgentRef(host: ref.host, agent: $0) }
        let name = design?.name ?? canvas.snapshot?.index.title ?? "Design"
        GeometryReader { proxy in
            let wide = proxy.size.width >= MobileLayout.padDesignSideBySideMinWidth
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    PadDesignHeader(title: name, wide: wide, system: wide ? canvas.systemName(design) : nil,
                                    swatches: canvas.systemSwatches,
                                    back: back,
                                    chat: wide ? nil : { showingChat = true },
                                    export: canvas.canPresent ? { exporting = canvas.exportPNGs(name: name) } : nil)
                    PadDesignCanvasView(canvas: canvas, reply: wide ? nil : agent)
                        .onChange(of: wide, initial: true) { _, wide in canvas.column = !wide }
                }
                .background { PadDesignCanvasBackground(wide: wide) }
                if wide {
                    PadDesignChatPane(canvas: canvas, agent: agent, hostName: hosts.host(ref.host)?.name)
                        .frame(width: MobileLayout.padDesignChatWidth)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .sheet(isPresented: $showingChat) {
            PadDesignChatPane(canvas: canvas, agent: agent, hostName: hosts.host(ref.host)?.name)
                .presentationDetents([.large])
        }
        .sheet(item: Binding(get: { exporting.map(PadDesignExport.init) }, set: { if $0 == nil { exporting = nil } })) { export in
            PadDesignShareSheet(items: export.urls)
        }
        .alert("Design", isPresented: Binding(get: { canvas.problem != nil }, set: { if !$0 { canvas.problem = nil } })) {
            Button("OK", role: .cancel) { canvas.problem = nil }
        } message: {
            Text(canvas.problem ?? "")
        }
        .onAppear {
            designs.setVisible(ref, true)
            // The chat's messages carry what the canvas shows as they leave.
            if let agent {
                let store = threads.store(for: agent)
                store.designContext = Self.viewRecord(of: canvas)
                canvas.ask = { [weak store] text, record in
                    guard let store else { return false }
                    await store.send(text: text, designContext: record)
                    return true
                }
            }
        }
        .onDisappear {
            designs.setVisible(ref, false)
        }
        .task(id: hosts.host(ref.host)?.session) { await canvas.loadSystem(design?.systemNamespace) }
    }

    /// "‹ Designs": back to the list under the design, or to it when the design opened on its own
    /// (a new window).
    private func back() {
        if navigator.layout == .pad, !navigator.padPath.contains(.padDesign(.list)) {
            PadDesignHooks.openList(navigator: navigator)
        } else {
            dismiss()
        }
    }

    /// The canvas's view record as the chat's sends read it, holding the canvas weakly.
    private static func viewRecord(of canvas: PadDesignCanvas) -> () -> DesignViewRecord? {
        { [weak canvas] in canvas?.viewRecord }
    }
}

/// The header over the canvas. Wide (iPadDesign): "‹ Designs" in the link blue, the name, then
/// the system's chip and Export, on the canvas's dots. Narrow (iPadSplitView): the chevron, the
/// name in 17, the chat button and Export, on the window's color over a hairline.
private struct PadDesignHeader: View {
    let title: String
    let wide: Bool
    let system: String?
    let swatches: [DesignSystemPresentation.Swatch]
    let back: () -> Void
    let chat: (() -> Void)?
    let export: (() -> Void)?

    var body: some View {
        let nw = Color.nw
        HStack(spacing: NW.Space.m) {
            Button(action: back) {
                HStack(spacing: NW.Space.xs) {
                    Image(systemName: "chevron.left")
                        .font(.nwSans(MobileLayout.padDesignHeaderText, .semibold))
                    if wide { Text("Designs").font(.nwSans(MobileLayout.padDesignHeaderText)) }
                }
                .foregroundStyle(nw.running)
                .frame(minHeight: NW.Height.touch)
                .contentShape(Rectangle().inset(by: -NW.Space.m))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Designs")
            Text(title)
                .font(wide ? .nw(.title) : .nw(.headline))
                .foregroundStyle(nw.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: NW.Space.m)
            if let system {
                NWDesignSystemChip(system, colors: swatches.map { Color(light: $0.light, dark: $0.dark) })
            }
            if let chat {
                Button(action: chat) {
                    Image(systemName: "text.bubble")
                        .font(.nw(.headline, weight: .regular))
                        .foregroundStyle(nw.textSecondary)
                        .frame(width: MobileLayout.padDesignHeaderButton, height: MobileLayout.padDesignHeaderButton)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .nwTouchTarget(height: MobileLayout.padDesignHeaderButton, width: MobileLayout.padDesignHeaderButton)
                .accessibilityLabel("Chat")
            }
            Button("Export", systemImage: "square.and.arrow.up") { export?() }
                .buttonStyle(.nw(.secondary, size: .l))
                .disabled(export == nil)
        }
        .padding(.horizontal, MobileLayout.padDesignHeaderInset)
        .frame(height: MobileLayout.padDesignHeaderHeight)
        .background {
            if !wide { nw.bgWindow.ignoresSafeArea(edges: .top) }
        }
        .overlay(alignment: .bottom) { if !wide { NWHairline() } }
    }
}

/// Behind the header and canvas: the canvas's color, and in a wide window its dots under the
/// header too (iPadDesign draws the header on the canvas).
private struct PadDesignCanvasBackground: View {
    let wide: Bool

    var body: some View {
        ZStack {
            Color.nw.bgBase
            if wide { NWDotGrid(spacing: NWDesignMetrics.gridSpacing) }
        }
        .ignoresSafeArea()
    }
}

/// The canvas: the design's boards and notes, the tool and zoom, the selection ringed over the
/// boards, and the comments' pins. The Comment tool's tap on an element opens the editor beside
/// it; a pin opens its thread. The board actions float over the board picked whole. A presented
/// board (Play) covers it all. Over it sits the Pencil markup seam (`PadDesignMarkupLayer`), and
/// in a narrow window the design agent's latest reply.
struct PadDesignCanvasView: View {
    @Bindable var canvas: PadDesignCanvas
    /// The design agent, whose latest reply floats over a narrow window's canvas; nil for none.
    let reply: AgentRef?

    var body: some View {
        let host = canvas.host
        let zoom = canvas.viewport.zoom
        let boards = canvas.boards
        NWDesignCanvas(boards: boards, viewport: $canvas.viewport, tool: $canvas.tool,
                       selection: canvas.selectionRings,
                       pins: canvas.pins, openPin: { canvas.openThread($0) }, popoverAnchor: canvas.popoverAnchor,
                       notes: canvas.column ? [] : canvas.notes, actions: canvas.column ? nil : actions,
                       move: nil,
                       pick: { canvas.pick($0) },
                       resized: { canvas.resized($0) }, zooming: { canvas.setZooming($0) }) { board in
            if let path = DesignPath(board.id) {
                PadDesignBoardSlot(host: host, path: path, zoom: zoom, content: board.content)
            }
        } popover: {
            PadDesignCommentPopover(canvas: canvas)
        }
        .overlay {
            PadDesignMarkupLayer(context: PadDesignMarkupContext(
                design: canvas.ref, viewport: canvas.viewport,
                boards: Dictionary(boards.compactMap { board in DesignPath(board.id).map { ($0, board.frame) } }, uniquingKeysWith: { a, _ in a }),
                presented: canvas.presented))
        }
        .overlay(alignment: .bottomTrailing) {
            if let reply {
                PadDesignReplyCard(canvas: canvas, agent: reply)
                    .padding(NW.Space.xxl)
            }
        }
        .overlay {
            if let path = canvas.presented, let board = canvas.snapshot?.index.boards[path] {
                NWBoardPresentation(title: canvas.title(path), boardSize: CGSize(width: board.w, height: board.h),
                                    close: { canvas.present(nil) }) { zoom in
                    PadDesignPresentedSlot(host: host, path: path, zoom: zoom, content: host.tokens[path] ?? 0)
                }
            }
        }
        // The reply card reads the design agent's latest word while the chat is folded away.
        .designAgentThread(reply)
        .overlay(alignment: .top) {
            if let error = canvas.loadError, canvas.snapshot == nil {
                Text(error)
                    .font(.nw(.caption))
                    .foregroundStyle(Color.nw.textTertiary)
                    .padding(MobileLayout.gutter)
            }
        }
    }

    /// The board actions over the board picked whole: Comment takes the Comment tool, Tweak opens
    /// its tab, Variations asks the design agent, Duplicate copies the board on the host, and •••
    /// plays an interactive one.
    private var actions: NWCanvasActions? {
        guard let path = canvas.actionsBoard else { return nil }
        let canvas = canvas
        return NWCanvasActions(board: path.rawValue, actions: NWBoardActions.Actions(
            comment: { canvas.tool = .comment },
            tweak: { canvas.paneTab = .tweak },
            variations: { canvas.askForVariations(of: path) },
            duplicate: { canvas.duplicate(path) },
            play: canvas.isInteractive(path) ? { canvas.present(path) } : nil))
    }
}

/// What opens beside a pin: the editor for a new comment, or a comment's thread with its
/// answers, Resolve and Reply….
private struct PadDesignCommentPopover: View {
    @Bindable var canvas: PadDesignCanvas
    @FocusState private var editorFocused: Bool

    var body: some View {
        if let element = canvas.draftElement {
            NWCommentEditor(text: $canvas.draftText, isFocused: $editorFocused, placeholder: "Comment for the design agent",
                            context: "on \(nativeBoardName(element.board.rawValue))\(element.words.map { " · \($0)" } ?? "")",
                            onSave: { canvas.submitComment() }, onCancel: { canvas.closeComment() })
                .disabled(canvas.sendingComment)
                .onAppear { editorFocused = true }
        } else if let comment = canvas.openThread {
            let now = Date()
            NWCommentThread(
                author: "You", age: nwCommentAge(since: comment.createdAt, now: now),
                note: comment.detached ? "element changed" : nil, text: comment.text,
                entries: comment.replies.map { reply in
                    NWCommentEntry(id: reply.id.uuidString, author: reply.author == .agent ? "Design agent" : "You",
                                   age: nwCommentAge(since: reply.createdAt, now: now), text: reply.text)
                },
                reply: $canvas.replyText,
                onResolve: { canvas.resolve(comment.id) },
                onReply: { canvas.sendReply() },
                onClose: { canvas.closeComment() })
        }
    }
}

/// The design agent's latest reply over a narrow window's canvas (iPadSplitView): "Design agent ·
/// now", its words, and "Send to the thread", which puts the boards (as this iPad drew them) and a
/// line naming the design in the composer of the thread another window shows, then brings that
/// window forward. With several such threads it asks which.
private struct PadDesignReplyCard: View {
    let canvas: PadDesignCanvas
    let agent: AgentRef
    @Environment(ThreadStores.self) private var threads
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileWindows.self) private var windows
    @Environment(\.mobileWindow) private var window
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let store = threads.store(for: agent)
        if let reply = PadDesignReply(store: store) {
            let targets = windows.targets(from: window.id, excluding: agent)
            VStack(alignment: .leading, spacing: NW.Space.m) {
                Text("Design agent · \(reply.age)")
                    .font(.nw(.caption))
                    .foregroundStyle(Color.nw.textTertiary)
                Text(reply.text)
                    .font(.nw(.ui, weight: .regular))
                    .foregroundStyle(Color.nw.textPrimary)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
                if targets.count == 1, let target = targets.first {
                    Button("Send to the thread") { send(to: target) }
                        .buttonStyle(.nw(.primary, size: .l))
                } else if targets.count > 1 {
                    Menu {
                        ForEach(targets, id: \.self) { target in
                            let host = hosts.host(target.thread.host)
                            Button {
                                send(to: target)
                            } label: {
                                Text(host?.agent(target.thread.agent)?.name ?? "Thread")
                                if let host { Text(host.name) }
                            }
                        }
                    } label: {
                        Text("Send to the thread")
                    }
                    .buttonStyle(.nw(.primary, size: .l))
                }
            }
            .padding(.vertical, MobileLayout.padDesignReplyCardPaddingVertical)
            .padding(.horizontal, MobileLayout.padDesignReplyCardPaddingHorizontal)
            .frame(width: MobileLayout.padDesignReplyCardWidth, alignment: .leading)
            .nwPopover(radius: NW.Radius.l)
            .accessibilityElement(children: .contain)
        }
    }

    private func send(to target: WindowTarget<AgentRef>) {
        let boards = PadDesignCanvas.canvasOrder(canvas.snapshot?.index ?? DesignIndex(title: nil))
        let images = canvas.host.pngs(boards)
        let name = canvas.snapshot?.index.title ?? "the design"
        let line = "Use these boards from \u{201C}\(name)\u{201D} as the spec."
        Task {
            await ComposerStates.shared.state(for: target.thread).attach(images)
            WindowHooks.send(line, to: target, threads: threads, windows: windows, openWindow: openWindow)
        }
    }
}

/// The design agent's latest reply: its words and how long ago.
private struct PadDesignReply {
    let text: String
    let age: String

    @MainActor init?(store: NativeThreadStore) {
        guard let row = store.rows.last(where: { !$0.isUser }), let text = row.presentation?.copyText,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.text = text
        let at = row.turn.messages.last?.timestamp
        age = at.map { nwCommentAge(since: $0) } ?? "now"
    }
}

// MARK: Export

/// Export on iPad: the boards as this iPad drew them, as PNGs, through the system's share sheet.
private struct PadDesignExport: Identifiable {
    let urls: [URL]
    var id: String { urls.map(\.path).joined(separator: "|") }
}

private struct PadDesignShareSheet: UIViewControllerRepresentable {
    let items: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
