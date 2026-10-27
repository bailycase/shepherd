import SwiftUI

/// Stand-ins for boards: a page of bars in the board's own colors, never Shepherd's.
private struct PreviewBoardPage: View {
    let phone: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: phone ? SH.Space.s : SH.Space.m) {
            RoundedRectangle(cornerRadius: SH.Radius.xs).fill(Color.sh.lineStrong)
                .frame(width: phone ? SH.Space.xxxl : SH.Space.xxxl * 3, height: SH.Space.m)
            HStack(spacing: SH.Space.s) {
                ForEach(0..<(phone ? 1 : 3), id: \.self) { _ in
                    RoundedRectangle(cornerRadius: SH.Radius.xs).fill(Color.sh.bgSunken).frame(height: SH.Space.xxxl)
                }
            }
            RoundedRectangle(cornerRadius: SH.Radius.xs).fill(Color.sh.bgSunken)
        }
        .padding(phone ? SH.Space.m : SH.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.sh.bgWindow)
    }
}

private let previewBoards = [
    SHCanvasBoard(id: "A.dc.html", frame: CGRect(x: 0, y: 0, width: 1280, height: 800), title: "A · Funnel first",
                  size: "1280 × 800", isSelected: true),
    SHCanvasBoard(id: "B.dc.html", frame: CGRect(x: 1360, y: 0, width: 1280, height: 800), title: "B · Step table",
                  size: "1280 × 800"),
    SHCanvasBoard(id: "A-phone.dc.html", frame: CGRect(x: 0, y: 920, width: 390, height: 844), title: "A · phone",
                  size: "390 × 844"),
]

#Preview("Design canvas") {
    @Previewable @State var viewport = SHCanvasViewport(offset: CGPoint(x: 44, y: 52), zoom: 0.24)
    @Previewable @State var tool = SHCanvasTool.select
    SHPreviewBoth {
        SHDesignCanvas(boards: previewBoards, viewport: $viewport, tool: $tool,
                       selection: [SHCanvasElement(id: "B.dc.html#12:1/0/1", board: "B.dc.html", rect: CGRect(x: 48, y: 280, width: 760, height: 320),
                                                   tag: "card · Checkout funnel")],
                       hover: SHCanvasElement(id: "B.dc.html#30:1/0/2", board: "B.dc.html", rect: CGRect(x: 832, y: 280, width: 400, height: 320)),
                       pins: [SHCanvasPin(id: "c1", board: "B.dc.html", rect: CGRect(x: 48, y: 280, width: 760, height: 320), number: 1),
                              SHCanvasPin(id: "c2", board: "A-phone.dc.html", rect: CGRect(x: 24, y: 120, width: 342, height: 200), number: 2)],
                       pick: { _ in }) { board in
            PreviewBoardPage(phone: board.frame.height > board.frame.width)
        }
        .frame(width: 720, height: 520)
    }
}

#Preview("Selection ring") {
    SHPreviewBoth {
        HStack(alignment: .top, spacing: SH.Space.xxl) {
            PreviewBoardPage(phone: false)
                .frame(width: 260, height: 140)
                .overlay { SHSelectionRing(.selected, tag: "card · Checkout funnel").padding(SH.Space.xl) }
            PreviewBoardPage(phone: false)
                .frame(width: 260, height: 140)
                .overlay { SHSelectionRing(.hover).padding(SH.Space.xl) }
        }
        .padding(.top, SH.Space.xxl)
        .padding(SH.Space.m)
    }
}

#Preview("Board frame") {
    SHPreviewBoth {
        HStack(alignment: .top, spacing: SH.Space.xxl) {
            SHBoardFrame(board: previewBoards[0], zoom: 0.2) { PreviewBoardPage(phone: false) }
            SHBoardFrame(board: previewBoards[1], zoom: 0.2) { PreviewBoardPage(phone: false) }
            SHBoardFrame(board: previewBoards[2], zoom: 0.2) { PreviewBoardPage(phone: true) }
        }
        .padding(.top, SH.Space.xl)
    }
}

#Preview("Shared piece") {
    SHPreviewBoth {
        VStack(alignment: .leading, spacing: SH.Space.l) {
            HStack(alignment: .top, spacing: SH.Space.xxl) {
                SHBoardFrame(board: SHCanvasBoard(id: "Card.dc.html", frame: CGRect(x: 0, y: 0, width: 1200, height: 480), title: "Card",
                                                  size: "1200 × 480", usage: "used in 3 boards"), zoom: 0.2) { PreviewBoardPage(phone: false) }
                SHBoardFrame(board: SHCanvasBoard(id: "Chip.dc.html", frame: CGRect(x: 0, y: 0, width: 240, height: 96), title: "Chip",
                                                  size: "240 × 96", usage: "used in 1 board"), zoom: 0.2) { PreviewBoardPage(phone: true) }
            }
            SHTweakPieceNote(piece: "Card", boards: "3 boards", goToSource: {})
            SHTweakPieceNote(piece: "Card", goToSource: nil)
        }
        .frame(width: 420)
        .padding(.top, SH.Space.xl)
    }
}

#Preview("Canvas toolbar") {
    @Previewable @State var tool = SHCanvasTool.select
    SHPreviewBoth {
        SHCanvasToolbar(tool: $tool, zoom: "42%")
    }
}

#Preview("Design cards") {
    SHPreviewBoth {
        VStack(alignment: .leading, spacing: SH.Space.xl) {
            HStack(alignment: .top, spacing: SH.Space.xl) {
                SHDesignCard(name: "Checkout funnel dashboard", system: "acme-web", detail: "4 boards", edited: "edited 2h ago",
                             board: .desktop, selected: true, action: {}) { PreviewBoardPage(phone: false) }
                SHDesignCard(name: "Onboarding", system: "acme-web", detail: "2 boards", edited: "edited yesterday",
                             board: .phone, action: {}) { PreviewBoardPage(phone: true) }
                SHDesignCard(name: "Settings redesign", system: nil, detail: "0 boards", edited: "edited just now",
                             board: .none, action: {}) { EmptyView() }
            }
            .frame(width: 900)
            HStack(spacing: SH.Space.xl) {
                SHDesignSystemCard(name: "acme-web", source: "dashboard-web · tokens.css", count: "3 designs")
                SHDesignSystemCard(name: "shepherd", count: "1 design")
            }
            .frame(width: 600)
            SHDesignSystemChip("acme-web")
        }
    }
}

#Preview("Design system page") {
    let accent = Color(light: "#4f46e5", dark: "#4f46e5")
    let surface = Color(light: "#f8fafc", dark: "#f8fafc")
    SHPreviewBoth {
        VStack(alignment: .leading, spacing: SH.Space.xl) {
            SHDesignHeader("acme-web", style: .page, section: "Design systems", status: .init(.done, label: "Synced"), designs: {}) {
                SHDesignSystemChip("acme-web", colors: [accent, Color(light: "#0f172a", dark: "#0f172a")], action: {})
            }
            HStack(alignment: .top, spacing: 0) {
                SHSectionRail([.init(id: "colors", title: "Colors", count: 11), .init(id: "type", title: "Type", count: 4),
                               .init(id: "components", title: "Components", count: 9)], selection: "colors")
                    .frame(height: 220)
                VStack(alignment: .leading, spacing: SH.Space.xl) {
                    HStack(spacing: 14) {
                        SHTokenSwatch("--accent", detail: "#4f46e5 · tokens.css:8", color: accent)
                        SHTokenSwatch("--bg", detail: "#f8fafc · tokens.css:4", color: surface)
                    }
                    SHTypeSpecimen("display", spec: "26/700") { Text("Checkout funnel").font(.shSans(26, .bold)) }
                    SHComponentSpecimen("Button", template: "partials/button.html", background: surface) {
                        Text("Export CSV").foregroundStyle(Color.sh.textOnLantern).padding(SH.Space.m).background(accent, in: RoundedRectangle(cornerRadius: SH.Radius.m))
                    }
                    .frame(width: 280)
                }
                .padding(SH.Space.xl)
            }
            HStack(spacing: SH.Space.xl) {
                SHDesignSystemCard(name: "acme-web", source: "dashboard-web · tokens.css", count: "3 designs", colors: [accent, surface])
                SHDesignSystemBuildTile()
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 600)
        }
        .frame(width: 900)
    }
}

#Preview("Design header and chat tabs") {
    SHPreviewBoth {
        VStack(spacing: SH.Space.xl) {
            SHDesignHeader("New design", style: .page, designs: {})
            SHDesignHeader("Checkout funnel dashboard", style: .toolbar, sidebar: {}, designs: {}) {
                SHDesignSystemChip("acme-web")
                Button {} label: { Image(systemName: "play.fill") }
                    .buttonStyle(.shIcon)
                    .disabled(true)
                Button("Export", systemImage: "square.and.arrow.up") {}
                    .buttonStyle(.sh(.secondary))
                    .disabled(true)
            }
            SHDesignPaneTabs([SHDesignPaneTabs.Tab(id: "chat", title: "Chat")], selection: "chat")
                .frame(width: 420)
        }
        .frame(width: 900)
    }
}

#Preview("Starting points") {
    SHPreviewBoth {
        HStack(spacing: SH.Space.m) {
            SHDesignStartCard(symbol: "pencil.tip", title: "acme-web", line: "design system · dashboard-web",
                              note: "~/Developer/dashboard-web", chosen: true)
            SHDesignStartCard(symbol: "pencil.tip", title: "shepherd", line: "design system · shepherd",
                              note: "~/Developer/shepherd", chosen: false)
        }
        .frame(width: 520)
    }
}

#Preview("Comment pins, thread and card") {
    @Previewable @State var reply = ""
    SHPreviewBoth {
        HStack(alignment: .top, spacing: SH.Space.xxl) {
            VStack(spacing: SH.Space.l) {
                HStack(spacing: SH.Space.xl) {
                    SHCommentPin(1)
                    SHCommentPin(2)
                    SHCommentPin(12)
                }
                SHCommentPin(3, size: .card)
            }
            SHCommentThread(author: "You", age: "2m", text: "Show the absolute counts next to the percentages.",
                            entries: [SHCommentEntry(id: "r1", author: "Design agent", age: "1m",
                                                     text: "Done on A and A · phone. Want the drop-off line in counts too?")],
                            reply: $reply, onResolve: {}, onReply: {})
            VStack(spacing: 0) {
                SHCommentCard(number: 1, target: "A · Checkout funnel", meta: "You · 2m",
                              text: "Show the absolute counts next to the percentages.", continues: true)
                Text("Done. Counts sit next to each percentage on both boards.")
                    .font(.shSans(13))
                    .shCommentAnswer(bridge: 0)
                SHCommentCard(number: 2, target: "A · phone", meta: "You · now", text: "Bigger total.")
                    .padding(.top, SH.Space.l)
            }
            .frame(width: 380)
        }
        .padding(SH.Space.l)
    }
}

#Preview("Tweak") {
    @Previewable @State var padding = 24.0
    @Previewable @State var radius = 12
    @Previewable @State var rounded = true
    @Previewable @State var scope = SHTweakScope.Scope.every
    SHPreviewBoth {
        VStack(spacing: 0) {
            SHTweakHeader(board: "A · Funnel first", element: "card · Checkout funnel", note: "Changes show on the canvas as you drag.")
            SHTweakGroup("Layout") {
                SHTweakRow("Padding", layout: .slider) {
                    SHValueSlider("Padding", value: $padding, in: 0...48, step: 4) { "\(Int($0))" }
                }
                SHTweakRow("Radius") {
                    SHSegmentedPicker("Radius", selection: $radius, options: [(8, "8"), (12, "12"), (16, "16")], size: .s)
                }
            }
            SHTweakGroup("Bars") {
                SHTweakRow("Color") {
                    SHTokenChipFlow {
                        SHTokenChip("accent", swatch: Color(light: "#4f46e5", dark: "#4f46e5"), isSelected: true) {}
                        SHTokenChip("slate", swatch: Color(light: "#475569", dark: "#475569"), isSelected: false) {}
                        SHTokenChip("success", swatch: Color(light: "#059669", dark: "#059669"), isSelected: false) {}
                    }
                }
                SHTweakRow("Rounded") { Toggle("Rounded", isOn: $rounded).toggleStyle(.shSwitch).labelsHidden() }
            }
            SHTweakGroup("Apply to", divided: false) {
                SHTweakRow("Scope") { SHTweakScope(selection: $scope, every: "Every funnel card") }
                SHTweakNote("Every funnel card: A and A · phone. Values snap to acme-web tokens.")
            }
            Spacer(minLength: 0)
            SHTweakFooter(canReset: true, reset: {}, ask: {})
        }
        .frame(width: 420, height: 560)
        .background(Color.sh.bgWindow)
    }
}

private let previewActions = SHBoardActions.Actions(comment: {}, tweak: {}, variations: {}, duplicate: {}, play: {})

#Preview("Board actions and another direction") {
    @Previewable @State var viewport = SHCanvasViewport(offset: CGPoint(x: 44, y: 96), zoom: 0.24)
    @Previewable @State var tool = SHCanvasTool.select
    SHPreviewBoth {
        VStack(alignment: .leading, spacing: SH.Space.xl) {
            SHBoardActions(actions: previewActions)
            SHBoardActions(size: .compact, actions: SHBoardActions.Actions(comment: {}, tweak: {}, variations: {}, duplicate: {}))
            SHDesignCanvas(boards: previewBoards, viewport: $viewport, tool: $tool,
                           notes: [SHCanvasNote(id: "t1", kind: .title, origin: CGPoint(x: 0, y: -300), width: 2600, text: "Checkout"),
                                   SHCanvasNote(id: "s1", kind: .sticky, origin: CGPoint(x: 1360, y: 1000), text: "Keep the phone's total above the fold.")],
                           actions: SHCanvasActions(board: "A.dc.html", actions: previewActions), anotherDirection: {},
                           pick: { _ in }) { board in
                PreviewBoardPage(phone: board.frame.height > board.frame.width)
            }
            .frame(width: 720, height: 520)
        }
    }
}

#Preview("Board presentation") {
    SHPreviewBoth {
        SHBoardPresentation(title: "A · Funnel first", boardSize: CGSize(width: 1280, height: 800), close: {}) { _ in
            PreviewBoardPage(phone: false)
        }
        .frame(width: 720, height: 520)
        .background(Color.sh.bgBase)
    }
}

#Preview("Export sheet") {
    @Previewable @State var ticked: Set<String> = ["A · Funnel first", "A · phone"]
    @Previewable @State var format = "HTML"
    let boards = [("A · Funnel first", "1280 × 800"), ("A · phone", "390 × 844"), ("B · Step table", "1280 × 800"),
                  ("C · Trend first", "1280 × 800")]
    let formats = [("HTML", "One standalone file per board. Opens anywhere."), ("ZIP", "HTML, tokens.css and assets."),
                   ("PDF", "One page per board."), ("PNG", "@2x, one image per board.")]
    SHPreviewBoth {
        SHExportSheet(exportTitle: "Export \(ticked.count) boards", canExport: !ticked.isEmpty, close: {}, export: {}) {
            SHExportSection("Boards") {
                VStack(spacing: 0) {
                    ForEach(boards, id: \.0) { board in
                        SHExportBoardRow(title: board.0, size: board.1, isTicked: ticked.contains(board.0)) {
                            if ticked.contains(board.0) { ticked.remove(board.0) } else { ticked.insert(board.0) }
                        }
                    }
                }
            }
            SHExportSection("Format") {
                Grid(horizontalSpacing: SHDesignMetrics.exportFormatSpacing, verticalSpacing: SHDesignMetrics.exportFormatSpacing) {
                    ForEach(0..<2, id: \.self) { row in
                        GridRow {
                            ForEach(formats[(row * 2)..<(row * 2 + 2)], id: \.0) { item in
                                SHExportFormatCard(item.0, line: item.1, isChosen: format == item.0) { format = item.0 }
                            }
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            SHExportSection("Use it somewhere else", divided: false) {
                Button("Attach to a thread", systemImage: "text.bubble") {}
                    .buttonStyle(.sh(.secondary, size: .s))
            }
        }
        .padding(SH.Space.xxl)
        .background(Color.sh.sheetScrim)
    }
}

#Preview("Designs on iPhone") {
    SHPreviewBoth {
        VStack(alignment: .leading, spacing: SH.Space.xl) {
            HStack(alignment: .top, spacing: SHPhoneDesignMetrics.gridColumnSpacing) {
                SHDesignTile(name: "Checkout funnel dashboard", detail: "acme-web · 4 boards · 2m", action: {}) {
                    PreviewBoardPage(phone: false)
                }
                SHDesignTile(name: "Onboarding flow", detail: "drawing · 2 boards", action: {}) {
                    PreviewBoardPage(phone: true).frame(width: 51)
                }
            }
            SHListCard {
                SHDesignSystemRow(name: "acme-web", source: "dashboard-web · tokens.css",
                                  colors: [Color.sh.running, Color.sh.textPrimary, Color.sh.lineSubtle])
                SHDesignSystemRow(name: "Shepherd Design", source: "shepherd · ShepherdUI Tokens",
                                  colors: [Color.sh.lantern, Color.sh.bgBase, Color.sh.textPrimary])
            }
        }
        .padding(SH.Space.l)
        .frame(width: 390)
    }
}

#Preview("A board on iPhone") {
    SHPreviewBoth {
        VStack(spacing: SH.Space.xl) {
            VStack(spacing: SH.Space.xxs) {
                Text("A · phone").font(.shSans(SHPhoneDesignMetrics.boardTitleSize, .semibold))
                SHBoardDots(count: 4, current: 3)
            }
            SHPhoneCommentCard(number: 2, target: "Steps list", meta: "You · now",
                               text: "Make the bars thicker on phones. Hard to read at a glance.",
                               status: "Design agent is updating A · phone")
            SHPhoneCommentCard(number: 1, target: "Cart viewed", meta: "You · 5m", text: "Round the bar ends.",
                               answer: SHCommentEntry(id: "r1", author: "Design agent", age: "1m",
                                                      text: "Done on A and A · phone."))
            SHBoardToolbar(tools: [
                .init(id: "comment", title: "Comment", symbol: "text.bubble"),
                .init(id: "ask", title: "Ask the agent", symbol: "sparkle"),
                .init(id: "boards", title: "Boards", symbol: "square.grid.2x2"),
                .init(id: "export", title: "Export", symbol: "square.and.arrow.up"),
            ], active: "comment") { _ in }
        }
        .padding(SH.Space.l)
        .frame(width: 390)
    }
}

#Preview("Pencil markup") {
    @Previewable @State var tool = SHMarkupPalette.Tool.pen
    @Previewable @State var ink = SHMarkupPalette.Ink.lantern
    SHPreviewBoth {
        VStack(alignment: .leading, spacing: SH.Space.xxl) {
            SHMarkupPalette(tool: $tool, ink: $ink, done: {})
            SHMarkupPalette(tool: .constant(.eraser), ink: .constant(.running), reading: true, done: {})
            SHMarkupProposals(cards: [
                .init(id: "c#0", number: 2, target: "A · phone › Steps list", text: "Thicker bars on phone."),
                .init(id: "c#1", number: 3, target: "A › KPI row", text: "Show counts next to the percentages here too."),
            ], state: .open, footnote: "Handwriting in the chat box works too: Scribble turns it into text.", apply: {}, keep: {})
            .frame(width: 328)
            SHMarkupProposals(cards: [.init(id: "c#0", number: 2, target: "A · phone › Steps list", text: "Thicker bars on phone.")],
                              state: .settled("On the canvas as comment 2."), apply: {}, keep: {})
            .frame(width: 328)
        }
        .padding(SH.Space.l)
    }
}
