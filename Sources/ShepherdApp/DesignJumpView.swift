import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdUI

/// Jump to a board (JumpInContext) over the window: the sheet's scrim, and the card 15% down,
/// 620pt wide (less 16pt margins in a narrow window). A click on the scrim or Esc closes it.
struct DesignJumpOverlay: View {
    var vm: ShepherdViewModel

    var body: some View {
        GeometryReader { geo in
            let M = NWJumpMetrics.self
            ZStack(alignment: .top) {
                if let model = vm.designJump {
                    Color.nw.sheetScrim
                        .contentShape(Rectangle())
                        .onTapGesture { vm.designJump = nil }
                        .accessibilityHidden(true)
                        .nwTransition(.content)
                    DesignJumpCard(model: model, maxListHeight: Self.maxListHeight(in: geo.size),
                                   picture: { vm.jumpPicture($0, in: model.design) },
                                   run: { vm.runDesignJump($0) }, close: { vm.designJump = nil })
                        .frame(width: max(0, min(M.width, geo.size.width - 2 * NWPaletteMetrics.margin)))
                        .accessibilityAddTraits(.isModal)
                        .nwTransition(.overlay, anchor: .top)
                        .padding(.top, (geo.size.height * M.topFraction).rounded())
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .ignoresSafeArea()
        .allowsHitTesting(vm.designJump != nil)
        .nwAnimation(.overlay, value: vm.designJump != nil)
    }

    /// The list's cap: what the window leaves under the card's top, its search row and footer,
    /// at most `maxVisibleRows` rows, at least one.
    static func maxListHeight(in size: CGSize) -> CGFloat {
        let M = NWJumpMetrics.self
        let room = size.height - (size.height * M.topFraction).rounded() - NWPaletteMetrics.margin
            - M.searchHeight - M.footerHeight - M.listTop - M.listInset
        return max(M.rowHeight, min(M.rowHeight * CGFloat(M.maxVisibleRows), room))
    }
}

/// The card: the search field and scope pills, the sections and rows, the footer's hints.
/// ↑↓ move the highlight, ⏎ jumps, ⇥ switches scope, Esc closes.
struct DesignJumpCard: View {
    @Bindable var model: DesignJumpModel
    let maxListHeight: CGFloat
    let picture: (DesignJumpItem) -> CGImage?
    let run: (DesignJumpItem) -> Void
    let close: () -> Void
    @FocusState private var fieldFocused: Bool

    var body: some View {
        // Read here, in this body, not inside the card's closures: a picture that lands after the
        // card opens redraws its row.
        let rows = model.rows
        let highlight = model.highlight
        let pictures = model.pictures
        NWJumpCard {
            HStack(spacing: NW.Space.m) {
                NWJumpSearchField("Jump to a board or a design…", text: $model.query, focus: $fieldFocused) {
                    if let item = model.highlighted { run(item) }
                }
                NWJumpScopes(DesignJumpScope.allCases.map { ($0, $0.title) }, selection: $model.scope)
                    .nwHelp("Switch scope", shortcut: "⇥")
            }
        } results: {
            list(rows: rows, highlight: highlight, pictures: pictures)
        } footer: {
            HStack(spacing: NWJumpMetrics.footerSpacing) {
                NWJumpHint("↑↓", "move")
                NWJumpHint("⏎", "jump")
                Spacer(minLength: 0)
                NWJumpHint("esc", "close")
            }
        }
        .onAppear { fieldFocused = true }
        .onKeyPress(.upArrow) { model.move(-1); return .handled }
        .onKeyPress(.downArrow) { model.move(1); return .handled }
        .onKeyPress(.tab) { model.cycleScope(); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Jump to a board")
    }

    private func list(rows: [DesignJumpItem], highlight: Int, pictures: Int) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                        if let title = header(before: index, in: rows) {
                            NWJumpSectionHeader(title.text, count: title.count)
                        }
                        NWJumpRow(item.title, meta: item.meta, tag: item.tag,
                                  picture: picture(item).map { NWReferenceImage(id: "\(item.id)@\(pictures)", image: Image(decorative: $0, scale: 2)) },
                                  highlighted: index == highlight) { run(item) }
                            .onHover { if $0 { model.highlight = index } }
                            .id(item.id)
                    }
                    if rows.isEmpty {
                        Text(model.query.isEmpty ? (model.scope == .thisDesign ? "No boards yet" : "No designs yet") : "No matches")
                            .font(Font.nw(.caption))
                            .foregroundStyle(Color.nw.textTertiary)
                            .frame(maxWidth: .infinity, minHeight: NWJumpMetrics.rowHeight)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: maxListHeight)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: highlight) { if rows.indices.contains(highlight) { proxy.scrollTo(rows[highlight].id) } }
        }
    }

    /// A section's caps before the first row of each section: Recent, then Other boards with
    /// their count. A query's matches, and All designs, go under no caps.
    private func header(before index: Int, in rows: [DesignJumpItem]) -> (text: String, count: Int?)? {
        guard model.query.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let section = rows[index].section
        guard index == 0 || rows[index - 1].section != section else { return nil }
        switch section {
        case .recent: return ("Recent", nil)
        case .otherBoards: return ("Other boards", rows.filter { $0.section == .otherBoards }.count)
        case .designs: return nil
        }
    }
}
