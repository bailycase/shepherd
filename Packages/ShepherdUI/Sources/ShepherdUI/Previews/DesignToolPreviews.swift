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
        NWDesignCanvas(boards: previewBoards, viewport: $viewport, tool: $tool,
                       selection: [NWCanvasElement(id: "B.dc.html#12:1/0/1", board: "B.dc.html", rect: CGRect(x: 48, y: 280, width: 760, height: 320),
                                                   tag: "card · Checkout funnel")],
                       hover: NWCanvasElement(id: "B.dc.html#30:1/0/2", board: "B.dc.html", rect: CGRect(x: 832, y: 280, width: 400, height: 320)),
                       pins: [NWCanvasPin(id: "c1", board: "B.dc.html", rect: CGRect(x: 48, y: 280, width: 760, height: 320), number: 1),
                              NWCanvasPin(id: "c2", board: "A-phone.dc.html", rect: CGRect(x: 24, y: 120, width: 342, height: 200), number: 2)],
                       pick: { _ in }) { board in
            PreviewBoardPage(phone: board.frame.height > board.frame.width)
        }
        .frame(width: 720, height: 520)
    }
}

#Preview("Selection ring") {
    NWPreviewBoth {
        HStack(alignment: .top, spacing: NW.Space.xxl) {
            PreviewBoardPage(phone: false)
                .frame(width: 260, height: 140)
                .overlay { NWSelectionRing(.selected, tag: "card · Checkout funnel").padding(NW.Space.xl) }
            PreviewBoardPage(phone: false)
                .frame(width: 260, height: 140)
                .overlay { NWSelectionRing(.hover).padding(NW.Space.xl) }
        }
        .padding(.top, NW.Space.xxl)
        .padding(NW.Space.m)
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
        NWCanvasToolbar(tool: $tool, zoom: "42%")
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

#Preview("Design system page") {
    let accent = Color(light: "#4f46e5", dark: "#4f46e5")
    let surface = Color(light: "#f8fafc", dark: "#f8fafc")
    NWPreviewBoth {
        VStack(alignment: .leading, spacing: NW.Space.xl) {
            NWDesignHeader("acme-web", style: .page, section: "Design systems", status: .init(.done, label: "Synced"), designs: {}) {
                NWDesignSystemChip("acme-web", colors: [accent, Color(light: "#0f172a", dark: "#0f172a")], action: {})
            }
            HStack(alignment: .top, spacing: 0) {
                NWSectionRail([.init(id: "colors", title: "Colors", count: 11), .init(id: "type", title: "Type", count: 4),
                               .init(id: "components", title: "Components", count: 9)], selection: "colors")
                    .frame(height: 220)
                VStack(alignment: .leading, spacing: NW.Space.xl) {
                    HStack(spacing: 14) {
                        NWTokenSwatch("--accent", detail: "#4f46e5 · tokens.css:8", color: accent)
                        NWTokenSwatch("--bg", detail: "#f8fafc · tokens.css:4", color: surface)
                    }
                    NWTypeSpecimen("display", spec: "26/700") { Text("Checkout funnel").font(.nwSans(26, .bold)) }
                    NWComponentSpecimen("Button", template: "partials/button.html", background: surface) {
                        Text("Export CSV").foregroundStyle(Color.nw.textOnLantern).padding(NW.Space.m).background(accent, in: RoundedRectangle(cornerRadius: NW.Radius.m))
                    }
                    .frame(width: 280)
                }
                .padding(NW.Space.xl)
            }
            HStack(spacing: NW.Space.xl) {
                NWDesignSystemCard(name: "acme-web", source: "dashboard-web · tokens.css", count: "3 designs", colors: [accent, surface])
                NWDesignSystemBuildTile()
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 600)
        }
        .frame(width: 900)
    }
}

#Preview("Design header and chat tabs") {
    NWPreviewBoth {
        VStack(spacing: NW.Space.xl) {
            NWDesignHeader("New design", style: .page, designs: {})
            NWDesignHeader("Checkout funnel dashboard", style: .toolbar, sidebar: {}, designs: {}) {
                NWDesignSystemChip("acme-web")
                Button {} label: { Image(systemName: "play.fill") }
                    .buttonStyle(.nwIcon)
                    .disabled(true)
                Button("Export", systemImage: "square.and.arrow.up") {}
                    .buttonStyle(.nw(.secondary))
                    .disabled(true)
            }
            NWDesignPaneTabs([NWDesignPaneTabs.Tab(id: "chat", title: "Chat")], selection: "chat")
                .frame(width: 420)
        }
        .frame(width: 900)
    }
}

#Preview("Starting points") {
    NWPreviewBoth {
        HStack(spacing: NW.Space.m) {
            NWDesignStartCard(symbol: "pencil.tip", title: "acme-web", line: "design system · dashboard-web",
                              note: "~/Developer/dashboard-web", chosen: true)
            NWDesignStartCard(symbol: "pencil.tip", title: "shepherd", line: "design system · shepherd",
                              note: "~/Developer/shepherd", chosen: false)
        }
        .frame(width: 520)
    }
}

#Preview("Comment pins, thread and card") {
    @Previewable @State var reply = ""
    NWPreviewBoth {
        HStack(alignment: .top, spacing: NW.Space.xxl) {
            VStack(spacing: NW.Space.l) {
                HStack(spacing: NW.Space.xl) {
                    NWCommentPin(1)
                    NWCommentPin(2)
                    NWCommentPin(12)
                }
                NWCommentPin(3, size: .card)
            }
            NWCommentThread(author: "You", age: "2m", text: "Show the absolute counts next to the percentages.",
                            entries: [NWCommentEntry(id: "r1", author: "Design agent", age: "1m",
                                                     text: "Done on A and A · phone. Want the drop-off line in counts too?")],
                            reply: $reply, onResolve: {}, onReply: {})
            VStack(spacing: 0) {
                NWCommentCard(number: 1, target: "A · Checkout funnel", meta: "You · 2m",
                              text: "Show the absolute counts next to the percentages.", continues: true)
                Text("Done. Counts sit next to each percentage on both boards.")
                    .font(.nwSans(13))
                    .nwCommentAnswer(bridge: 0)
                NWCommentCard(number: 2, target: "A · phone", meta: "You · now", text: "Bigger total.")
                    .padding(.top, NW.Space.l)
            }
            .frame(width: 380)
        }
        .padding(NW.Space.l)
    }
}

#Preview("Tweak") {
    @Previewable @State var padding = 24.0
    @Previewable @State var radius = 12
    @Previewable @State var rounded = true
    @Previewable @State var scope = NWTweakScope.Scope.every
    NWPreviewBoth {
        VStack(spacing: 0) {
            NWTweakHeader(board: "A · Funnel first", element: "card · Checkout funnel", note: "Changes show on the canvas as you drag.")
            NWTweakGroup("Layout") {
                NWTweakRow("Padding", layout: .slider) {
                    NWValueSlider("Padding", value: $padding, in: 0...48, step: 4) { "\(Int($0))" }
                }
                NWTweakRow("Radius") {
                    NWSegmentedPicker("Radius", selection: $radius, options: [(8, "8"), (12, "12"), (16, "16")], size: .s)
                }
            }
            NWTweakGroup("Bars") {
                NWTweakRow("Color") {
                    NWTokenChipFlow {
                        NWTokenChip("accent", swatch: Color(light: "#4f46e5", dark: "#4f46e5"), isSelected: true) {}
                        NWTokenChip("slate", swatch: Color(light: "#475569", dark: "#475569"), isSelected: false) {}
                        NWTokenChip("success", swatch: Color(light: "#059669", dark: "#059669"), isSelected: false) {}
                    }
                }
                NWTweakRow("Rounded") { Toggle("Rounded", isOn: $rounded).toggleStyle(.nwSwitch).labelsHidden() }
            }
            NWTweakGroup("Apply to", divided: false) {
                NWTweakRow("Scope") { NWTweakScope(selection: $scope, every: "Every funnel card") }
                NWTweakNote("Every funnel card: A and A · phone. Values snap to acme-web tokens.")
            }
            Spacer(minLength: 0)
            NWTweakFooter(canReset: true, reset: {}, ask: {})
        }
        .frame(width: 420, height: 560)
        .background(Color.nw.bgWindow)
    }
}

private let previewActions = NWBoardActions.Actions(comment: {}, tweak: {}, variations: {}, duplicate: {}, play: {})

#Preview("Board actions and another direction") {
    @Previewable @State var viewport = NWCanvasViewport(offset: CGPoint(x: 44, y: 96), zoom: 0.24)
    @Previewable @State var tool = NWCanvasTool.select
    NWPreviewBoth {
        VStack(alignment: .leading, spacing: NW.Space.xl) {
            NWBoardActions(actions: previewActions)
            NWBoardActions(size: .compact, actions: NWBoardActions.Actions(comment: {}, tweak: {}, variations: {}, duplicate: {}))
            NWDesignCanvas(boards: previewBoards, viewport: $viewport, tool: $tool,
                           notes: [NWCanvasNote(id: "t1", kind: .title, origin: CGPoint(x: 0, y: -300), width: 2600, text: "Checkout"),
                                   NWCanvasNote(id: "s1", kind: .sticky, origin: CGPoint(x: 1360, y: 1000), text: "Keep the phone's total above the fold.")],
                           actions: NWCanvasActions(board: "A.dc.html", actions: previewActions), anotherDirection: {},
                           pick: { _ in }) { board in
                PreviewBoardPage(phone: board.frame.height > board.frame.width)
            }
            .frame(width: 720, height: 520)
        }
    }
}

#Preview("Board presentation") {
    NWPreviewBoth {
        NWBoardPresentation(title: "A · Funnel first", boardSize: CGSize(width: 1280, height: 800), close: {}) { _ in
            PreviewBoardPage(phone: false)
        }
        .frame(width: 720, height: 520)
        .background(Color.nw.bgBase)
    }
}
