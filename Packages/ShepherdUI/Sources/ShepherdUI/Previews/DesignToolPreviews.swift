import SwiftUI

/// Stand-ins for boards: a page of bars in the board's own colors, never Shepherd's.
private struct PreviewBoardPage: View {
    let phone: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: phone ? NW.Space.s : NW.Space.m) {
            RoundedRectangle(cornerRadius: NW.Radius.xs).fill(Color.nw.lineStrong)
                .frame(width: phone ? NW.Space.xxxl : NW.Space.xxxl * 3, height: NW.Space.m)
            HStack(spacing: NW.Space.s) {
                ForEach(0..<(phone ? 1 : 3), id: \.self) { _ in
                    RoundedRectangle(cornerRadius: NW.Radius.xs).fill(Color.nw.bgSunken).frame(height: NW.Space.xxxl)
                }
            }
            RoundedRectangle(cornerRadius: NW.Radius.xs).fill(Color.nw.bgSunken)
        }
        .padding(phone ? NW.Space.m : NW.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.nw.bgWindow)
    }
}

private let previewBoards = [
    NWCanvasBoard(id: "A.dc.html", frame: CGRect(x: 0, y: 0, width: 1280, height: 800), title: "A · Funnel first",
                  size: "1280 × 800", isSelected: true),
    NWCanvasBoard(id: "B.dc.html", frame: CGRect(x: 1360, y: 0, width: 1280, height: 800), title: "B · Step table",
                  size: "1280 × 800"),
    NWCanvasBoard(id: "A-phone.dc.html", frame: CGRect(x: 0, y: 920, width: 390, height: 844), title: "A · phone",
                  size: "390 × 844"),
]

#Preview("Design canvas") {
    @Previewable @State var viewport = NWCanvasViewport(offset: CGPoint(x: 44, y: 52), zoom: 0.24)
    @Previewable @State var tool = NWCanvasTool.select
    NWPreviewBoth {
        NWDesignCanvas(boards: previewBoards, viewport: $viewport, tool: $tool, disabledTools: [.comment], select: { _ in }) { board in
            PreviewBoardPage(phone: board.frame.height > board.frame.width)
        }
        .frame(width: 720, height: 520)
    }
}

#Preview("Board frame") {
    NWPreviewBoth {
        HStack(alignment: .top, spacing: NW.Space.xxl) {
            NWBoardFrame(board: previewBoards[0], zoom: 0.2) { PreviewBoardPage(phone: false) }
            NWBoardFrame(board: previewBoards[1], zoom: 0.2) { PreviewBoardPage(phone: false) }
            NWBoardFrame(board: previewBoards[2], zoom: 0.2) { PreviewBoardPage(phone: true) }
        }
        .padding(.top, NW.Space.xl)
    }
}

#Preview("Canvas toolbar") {
    @Previewable @State var tool = NWCanvasTool.select
    NWPreviewBoth {
        NWCanvasToolbar(tool: $tool, zoom: "42%", disabled: [.comment])
    }
}

#Preview("Design cards") {
    NWPreviewBoth {
        VStack(alignment: .leading, spacing: NW.Space.xl) {
            HStack(alignment: .top, spacing: NW.Space.xl) {
                NWDesignCard(name: "Checkout funnel dashboard", system: "acme-web", detail: "4 boards", edited: "edited 2h ago",
                             board: .desktop, selected: true, action: {}) { PreviewBoardPage(phone: false) }
                NWDesignCard(name: "Onboarding", system: "acme-web", detail: "2 boards", edited: "edited yesterday",
                             board: .phone, action: {}) { PreviewBoardPage(phone: true) }
                NWDesignCard(name: "Settings redesign", system: nil, detail: "0 boards", edited: "edited just now",
                             board: .none, action: {}) { EmptyView() }
            }
            .frame(width: 900)
            HStack(spacing: NW.Space.xl) {
                NWDesignSystemCard(name: "acme-web", source: "dashboard-web · tokens.css", count: "3 designs")
                NWDesignSystemCard(name: "shepherd", count: "1 design")
            }
            .frame(width: 600)
            NWDesignSystemChip("acme-web")
        }
    }
}
