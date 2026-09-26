import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdUI

/// The Export sheet's state (DZExport): the design's boards with the ticked ones (from the
/// canvas's selection), the format, the threads its boards can be attached to, and whether an
/// export is running.
@MainActor @Observable
final class DesignExportModel {
    struct Thread: Equatable, Identifiable {
        let id: AgentID
        let name: String
    }

    let designID: DesignID
    let designName: String
    var selection: DesignExportSelection
    var format: DesignExportFormat = .html
    /// Local threads the boards can go to, most recently active first.
    let threads: [Thread]
    /// An export or an attach is being written.
    var working = false

    init(designID: DesignID, designName: String, selection: DesignExportSelection, threads: [Thread]) {
        self.designID = designID
        self.designName = designName
        self.selection = selection
        self.threads = threads
    }

    var canExport: Bool { selection.count > 0 && !working }
    /// The primary button: "Export 2 boards", or what it is doing.
    var exportTitle: String { working ? "Exporting…" : selection.exportTitle }
}

/// The Export sheet over a design (DZExport): its boards, the format, and Attach to a thread,
/// then Cancel and Export. The live link and Attach to a mission are left out: the first is a
/// network listener not built, the second waits for Missions.
struct DesignExportSheet: View {
    var vm: ShepherdViewModel
    @Bindable var model: DesignExportModel

    var body: some View {
        NWExportSheet(exportTitle: model.exportTitle, canExport: model.canExport,
                      close: { vm.closeDesignExport() }, export: { vm.runDesignExport(model) }) {
            NWExportSection("Boards") { boards }
            NWExportSection("Format") { formats }
            NWExportSection("Use it somewhere else", divided: false) { share }
        }
        .disabled(model.working)
    }

    /// One row per board; past eight, they scroll.
    private var boards: some View {
        let rows = model.selection.rows
        let height = NWDesignMetrics.exportRowHeight * min(CGFloat(rows.count), NWDesignMetrics.exportVisibleRows)
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(rows) { row in
                    NWExportBoardRow(title: row.title, size: row.size, isTicked: model.selection.isTicked(row.path)) {
                        model.selection.toggle(row.path)
                    }
                    .equatable()
                }
            }
        }
        .scrollDisabled(CGFloat(rows.count) <= NWDesignMetrics.exportVisibleRows)
        .frame(height: height)
    }

    private var formats: some View {
        let all = DesignExportFormat.allCases
        return Grid(horizontalSpacing: NWDesignMetrics.exportFormatSpacing, verticalSpacing: NWDesignMetrics.exportFormatSpacing) {
            ForEach(0..<(all.count / 2), id: \.self) { row in
                GridRow {
                    ForEach(all[(row * 2)..<(row * 2 + 2)], id: \.self) { format in
                        NWExportFormatCard(format.title, line: format.line, isChosen: model.format == format) { model.format = format }
                    }
                }
            }
        }
        // A row's cards share its height, and the grid takes only what they need.
        .fixedSize(horizontal: false, vertical: true)
    }

    private var share: some View {
        VStack(alignment: .leading, spacing: NW.Space.m) {
            HStack(spacing: NWDesignMetrics.exportShareSpacing) {
                // Which thread is not drawn: the button lists them.
                Menu {
                    ForEach(model.threads) { thread in
                        Button(thread.name) { vm.attachDesignExport(model, to: thread.id) }
                    }
                } label: {
                    Label("Attach to a thread", systemImage: "text.bubble")
                }
                .menuStyle(.button)
                .buttonStyle(.nw(.secondary, size: .s))
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(model.threads.isEmpty || model.selection.count == 0)
            }
            Text("Attached boards arrive as HTML plus a note of the tokens they use.")
                .font(.nwSans(NWDesignMetrics.exportNoteSize))
                .foregroundStyle(Color.nw.textTertiary)
        }
    }
}

/// The Export sheet centered over the window on its scrim. The scrim takes clicks and does
/// nothing with them: Cancel, the close button or Escape put the sheet away.
struct DesignExportOverlay: View {
    var vm: ShepherdViewModel

    var body: some View {
        ZStack {
            if let model = vm.designExport {
                Color.nw.sheetScrim
                    .contentShape(Rectangle())
                    .onTapGesture {}
                    .accessibilityHidden(true)
                    .nwTransition(.content)
                DesignExportSheet(vm: vm, model: model)
                    .nwTransition(.overlay, anchor: .center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .allowsHitTesting(vm.designExport != nil)
        .nwAnimation(.overlay, value: vm.designExport != nil)
    }
}
