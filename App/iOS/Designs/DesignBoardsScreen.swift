import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

// A design's boards on the phone. No board draws this screen: it is the least that lets a design
// open onto one board at a time (MobileDesignBoard's back button names the design), a grid of its
// boards in the Designs tiles' anatomy, and the same grid as the board's Boards sheet.

/// One design: its boards in canvas order, each opening full screen, and Ask the agent.
struct DesignBoardsScreen: View {
    let ref: HostDesignRef
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator
    @Environment(\.dismiss) private var dismiss
    @State private var watchToken = UUID()
    @State private var prompt: DesignActionPrompt?
    @State private var starting = false

    var body: some View {
        let designs = MobileDesigns.of(hosts)
        let index = designs.indexes[ref]
        let name = designs.design(ref)?.name ?? index?.snapshot.index.title ?? "Design"
        ScrollView {
            VStack(alignment: .leading, spacing: MobileLayout.headerSpacing) {
                if let failure = designs.failures[ref], index == nil {
                    SHEmptyState(Text("Couldn't read this design"), message: failure, showsMark: false)
                        .frame(maxWidth: .infinity)
                        .padding(.top, SH.Space.xxxl)
                } else if let index {
                    let page = designs.page(ref)
                    let boards = RemoteDesignPresentation.boards(index.snapshot.index, page: page)
                    if boards.isEmpty, !index.snapshot.index.boards.isEmpty {
                        SHEmptyState(Text("No boards on this page"), message: "Choose another page from the title.", showsMark: false)
                            .frame(maxWidth: .infinity)
                            .padding(.top, SH.Space.xxxl)
                    } else if boards.isEmpty {
                        SHEmptyState(Text("No boards yet"), message: "The design agent's boards show here as it draws them.", showsMark: false)
                            .frame(maxWidth: .infinity)
                            .padding(.top, SH.Space.xxxl)
                    } else {
                        SHListHeader(RemoteDesignPresentation.boardsText(boards.count), count: nil)
                        DesignBoardGrid(ref: ref, index: index, page: page, source: designs.source(ref), current: nil) { path in
                            navigator.open(.designs(.board(ref, path: path.rawValue)))
                        }
                    }
                } else {
                    ProgressView().progressViewStyle(.shSpinner)
                        .frame(maxWidth: .infinity)
                        .padding(.top, SH.Space.xxxl)
                }
            }
            .padding(.horizontal, MobileDesignLayout.gutter)
            .padding(.bottom, MobileLayout.sectionSpacing)
            .frame(maxWidth: MobileLayout.homeMaxWidth)
            .frame(maxWidth: .infinity)
            .modifier(DesignPageMenu(ref: ref))
        }
        .background(Color.sh.bgWindow)
        .refreshable { await designs.sync(ref) }
        .task { await designs.sync(ref) }
        // Boards the agent draws while this is on screen show as they land.
        .onAppear {
            designs.watch(ref, on: true, token: watchToken) { changed, files, _ in
                guard files, changed == ref else { return }
                Task { await designs.sync(ref) }
            }
        }
        .onDisappear { designs.watch(ref, on: false, token: watchToken) }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // With pages, the title's menu leaves no room for both: Ask is pinned so it stays in
            // the bar (`visibilityPriority(.high)` still overflowed it).
            ToolbarItem(placement: designs.hasPages(ref) ? .topBarPinnedTrailing : .topBarTrailing) {
                // A design with no agent on its host gets one there (`design.agent.v1`).
                Button("Ask the agent", systemImage: "sparkle") {
                    starting = true
                    Task {
                        defer { starting = false }
                        do { navigator.open(.thread(try await designs.ensureAgent(ref))) } catch {
                            designs.report("Couldn't start its agent: \(MobileDesignsError.words(error))")
                        }
                    }
                }
                .disabled(starting || designs.agent(ref) == nil && !designs.supports(ref.host, RemoteProtocol.designAgentCapability))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu("More", systemImage: "ellipsis") { DesignActionItems(ref: ref, prompt: $prompt) }
            }
        }
        .modifier(DesignActionPrompts(prompt: $prompt, deleted: { dismiss() }))
        .safeAreaInset(edge: .top) {
            if designs.problem != nil { DesignActionBanners().padding(.horizontal, MobileDesignLayout.gutter) }
        }
    }
}

/// Every board of a design, to jump to one (the board's Boards), presented over it.
struct DesignBoardsSheet: View {
    let ref: HostDesignRef
    let current: DesignPath?
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let designs = MobileDesigns.of(hosts)
        NavigationStack {
            ScrollView {
                if let index = designs.indexes[ref] {
                    if RemoteDesignPresentation.boards(index.snapshot.index, page: designs.page(ref)).isEmpty {
                        SHEmptyState(Text("No boards on this page"), message: "Choose another page from the title.", showsMark: false)
                            .frame(maxWidth: .infinity)
                            .padding(.top, SH.Space.xxxl)
                    }
                    DesignBoardGrid(ref: ref, index: index, page: designs.page(ref), source: designs.source(ref), current: current) { path in
                        DesignBoardJump.shared.request(ref, path)
                        dismiss()
                    }
                    .padding(.horizontal, MobileDesignLayout.gutter)
                    .padding(.vertical, SH.Space.l)
                    .modifier(DesignPageMenu(ref: ref))
                }
            }
            .background(Color.sh.bgWindow)
            .navigationTitle("Boards")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
        .task { await designs.sync(ref) }
    }
}

/// The design's pages, the Mac's page popup as the title's menu: the page shown under the title,
/// and a tap on the title lists every page, checked on the one shown. A canvas with one page or
/// none has no menu.
struct DesignPageMenu: ViewModifier {
    let ref: HostDesignRef
    @Environment(MobileHosts.self) private var hosts

    func body(content: Content) -> some View {
        let designs = MobileDesigns.of(hosts)
        let pages = designs.indexes[ref].map { RemoteDesignPresentation.pages($0.snapshot.index) } ?? []
        let page = designs.page(ref)
        // An empty title menu still draws its chevron, so one page or none gets no menu. Put on
        // the screen's content, not the screen, so the screen's own tasks don't restart as the
        // pages arrive.
        if pages.count > 1 {
            content
                .navigationSubtitle(pages.first { $0.id == page }?.name ?? "")
                .toolbarTitleMenu { DesignPagePicker(ref: ref) }
        } else {
            content
        }
    }
}

/// The design's pages as a menu's checked choices: the title menus' content.
struct DesignPagePicker: View {
    let ref: HostDesignRef
    @Environment(MobileHosts.self) private var hosts

    var body: some View {
        let designs = MobileDesigns.of(hosts)
        let pages = designs.indexes[ref].map { RemoteDesignPresentation.pages($0.snapshot.index) } ?? []
        Picker("Page", selection: Binding(get: { designs.page(ref) ?? "" }, set: { designs.showPage(ref, $0) })) {
            ForEach(pages, id: \.id) { page in Text(page.name).tag(page.id) }
        }
    }
}

/// A board chosen in the Boards sheet, for the board screen under it to show.
@MainActor
@Observable
final class DesignBoardJump {
    struct Target: Equatable {
        var ref: HostDesignRef
        var path: DesignPath
        var id = UUID()
    }

    static let shared = DesignBoardJump()
    private(set) var target: Target?

    func request(_ ref: HostDesignRef, _ path: DesignPath) {
        target = Target(ref: ref, path: path)
    }
}

/// The grid of a design's boards: each drawn on the phone, its label and size under it.
struct DesignBoardGrid: View {
    let ref: HostDesignRef
    let index: RemoteDesignIndex
    /// The page whose boards show (nil: a canvas without pages).
    let page: String?
    let source: RemoteDesignSource?
    let current: DesignPath?
    let open: (DesignPath) -> Void

    var body: some View {
        let canvas = index.snapshot.index
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: SHPhoneDesignMetrics.gridColumnSpacing, alignment: .top),
                                 count: 2),
                  spacing: SHPhoneDesignMetrics.gridRowSpacing) {
            ForEach(RemoteDesignPresentation.boards(canvas, page: page), id: \.self) { path in
                if let board = canvas.boards[path] {
                    let size = CGSize(width: board.w, height: board.h)
                    SHDesignTile(name: RemoteDesignPresentation.label(path, in: canvas), detail: RemoteDesignPresentation.size(board),
                                 action: { open(path) }) {
                        GeometryReader { proxy in
                            let scale = RemoteDesignPresentation.tileScale(size, in: proxy.size)
                            DesignBoardImage(ref: ref, source: source, path: path, sha256: index.snapshot.boards[path] ?? "",
                                             size: size, shown: CGSize(width: size.width * scale, height: size.height * scale),
                                             alignment: size.height > size.width ? .top : .topLeading)
                                .frame(width: proxy.size.width, height: proxy.size.height)
                        }
                    }
                    .overlay {
                        if path == current {
                            RoundedRectangle(cornerRadius: SHPhoneDesignMetrics.tileRadius)
                                .strokeBorder(Color.sh.running, lineWidth: SHDesignMetrics.ringWidth)
                                .frame(height: SHPhoneDesignMetrics.tileHeight)
                                .frame(maxHeight: .infinity, alignment: .top)
                                .allowsHitTesting(false)
                        }
                    }
                }
            }
        }
    }
}
