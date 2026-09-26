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
    @State private var watchToken = UUID()

    var body: some View {
        let designs = MobileDesigns.of(hosts)
        let index = designs.indexes[ref]
        let name = designs.design(ref)?.name ?? index?.snapshot.index.title ?? "Design"
        ScrollView {
            VStack(alignment: .leading, spacing: MobileLayout.headerSpacing) {
                if let failure = designs.failures[ref], index == nil {
                    NWEmptyState(Text("Couldn't read this design"), message: failure, showsMark: false)
                        .frame(maxWidth: .infinity)
                        .padding(.top, NW.Space.xxxl)
                } else if let index {
                    let boards = RemoteDesignPresentation.boards(index.snapshot.index)
                    if boards.isEmpty {
                        NWEmptyState(Text("No boards yet"), message: "The design agent's boards show here as it draws them.", showsMark: false)
                            .frame(maxWidth: .infinity)
                            .padding(.top, NW.Space.xxxl)
                    } else {
                        NWListHeader(RemoteDesignPresentation.boardsText(boards.count), count: nil)
                        DesignBoardGrid(ref: ref, index: index, source: designs.source(ref), current: nil) { path in
                            navigator.open(.designs(.board(ref, path: path.rawValue)))
                        }
                    }
                } else {
                    ProgressView().progressViewStyle(.nwSpinner)
                        .frame(maxWidth: .infinity)
                        .padding(.top, NW.Space.xxxl)
                }
            }
            .padding(.horizontal, MobileDesignLayout.gutter)
            .padding(.bottom, MobileLayout.sectionSpacing)
            .frame(maxWidth: MobileLayout.homeMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .background(Color.nw.bgWindow)
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
            ToolbarItem(placement: .topBarTrailing) {
                Button("Ask the agent", systemImage: "sparkle") {
                    if let agent = designs.agent(ref) { navigator.open(.thread(agent)) }
                }
                .disabled(designs.agent(ref) == nil)
            }
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
                    DesignBoardGrid(ref: ref, index: index, source: designs.source(ref), current: current) { path in
                        DesignBoardJump.shared.request(ref, path)
                        dismiss()
                    }
                    .padding(.horizontal, MobileDesignLayout.gutter)
                    .padding(.vertical, NW.Space.l)
                }
            }
            .background(Color.nw.bgWindow)
            .navigationTitle("Boards")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
        .task { await designs.sync(ref) }
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
    let source: RemoteDesignSource?
    let current: DesignPath?
    let open: (DesignPath) -> Void

    var body: some View {
        let canvas = index.snapshot.index
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: NWPhoneDesignMetrics.gridColumnSpacing, alignment: .top),
                                 count: 2),
                  spacing: NWPhoneDesignMetrics.gridRowSpacing) {
            ForEach(RemoteDesignPresentation.boards(canvas), id: \.self) { path in
                if let board = canvas.boards[path] {
                    let size = CGSize(width: board.w, height: board.h)
                    NWDesignTile(name: RemoteDesignPresentation.label(path, in: canvas), detail: RemoteDesignPresentation.size(board),
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
                            RoundedRectangle(cornerRadius: NWPhoneDesignMetrics.tileRadius)
                                .strokeBorder(Color.nw.running, lineWidth: NWDesignMetrics.ringWidth)
                                .frame(height: NWPhoneDesignMetrics.tileHeight)
                                .frame(maxHeight: .infinity, alignment: .top)
                                .allowsHitTesting(false)
                        }
                    }
                }
            }
        }
    }
}
