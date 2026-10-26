import SwiftUI

// DesignRefStates as a page of specimens: every state of the chip, its preview, the @ picker's
// stages (the other hosts' tags and an offline host's dimmed rows among them, which the app
// reaches once remote references come), the board actions, the sheet, the toasts, the agent's
// line and the thread's pin. The #Previews, the component gallery and the preview renders draw it.

/// A stand-in picture of a board: a page of bars, never a real board's.
struct SHSpecimenBoard: View {
    var body: some View {
        GeometryReader { proxy in
            let unit = proxy.size.width / 40
            VStack(alignment: .leading, spacing: unit) {
                ForEach(0..<5, id: \.self) { index in
                    RoundedRectangle(cornerRadius: unit / 2).fill(Color.sh.running)
                        .frame(width: proxy.size.width * (0.9 - CGFloat(index) * 0.17), height: unit * 1.6)
                }
            }
            .padding(unit * 2)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .background(Color.sh.bgRaised)
        }
    }
}

@MainActor
private func specimenPicture(_ id: String, size: CGSize) -> SHReferenceImage {
    let renderer = ImageRenderer(content: SHSpecimenBoard().frame(width: size.width, height: size.height))
    renderer.scale = 2
    #if os(macOS)
    let image = renderer.nsImage.map { Image(nsImage: $0) } ?? Image(systemName: "photo")
    #else
    let image = renderer.uiImage.map { Image(uiImage: $0) } ?? Image(systemName: "photo")
    #endif
    return SHReferenceImage(id: id, image: image)
}

/// Every state DesignRefStates draws, one labelled specimen each.
public struct SHDesignReferenceSpecimens: View {
    public init() {}

    private static let crumbs = ["Checkout funnel dashboard", "A · Funnel first", "card “Checkout funnel”"]

    public var body: some View {
        let picture = specimenPicture("specimen", size: CGSize(width: 316, height: 180))
        VStack(alignment: .leading, spacing: SH.Space.xxl) {
            section("The reference chip") {
                VStack(alignment: .leading, spacing: SH.Space.m) {
                    specimen("in the composer") { SHDesignReferenceChip(crumbs: Self.crumbs, version: "v23", thumbnail: picture, remove: {}) }
                    specimen("sent") { SHDesignReferenceChip(crumbs: Self.crumbs, version: "v23", thumbnail: picture) }
                    specimen("updatedSince") {
                        SHDesignReferenceChip(crumbs: Self.crumbs, version: "v23", state: .updated("updated since · now v26"), thumbnail: picture)
                    }
                    specimen("deleted") {
                        SHDesignReferenceChip(crumbs: Self.crumbs, version: "v23",
                                              state: .deleted("design deleted · the copy sent here is kept"), thumbnail: picture)
                    }
                    specimen("on another host") {
                        SHDesignReferenceChip(crumbs: Self.crumbs, version: "v23", state: .anotherHost("demo-mac"), thumbnail: picture)
                    }
                    specimen("host offline") {
                        SHDesignReferenceChip(crumbs: Self.crumbs, version: "v23",
                                              state: .hostOffline(host: "horizon", words: "offline · uses the copy from Sep 26"),
                                              thumbnail: picture, remove: {})
                    }
                    specimen("hovered") { SHDesignReferenceChip(crumbs: Self.crumbs, version: "v23", thumbnail: picture, highlighted: true) }
                    HStack(alignment: .top, spacing: SH.Space.l) {
                        specimen("board") { SHDesignReferenceChip(crumbs: Array(Self.crumbs.prefix(2)), version: "v23", thumbnail: picture, remove: {}) }
                        specimen("whole design") { SHDesignReferenceChip(crumbs: [Self.crumbs[0]], version: "v23", thumbnail: picture, remove: {}) }
                    }
                }
            }
            section("The preview") {
                HStack(alignment: .top, spacing: SH.Space.xl) {
                    SHDesignReferencePreview(picture: picture, crumbs: Self.crumbs, version: "v23", pinned: "pinned Sep 27, 10:42",
                                             system: "acme-web", gets: ["picture", "html", "11 styles", "8 tokens"], open: {})
                    SHDesignReferencePreview(picture: picture, crumbs: Self.crumbs, version: "v23", pinned: "pinned Sep 27, 10:42",
                                             system: "acme-web",
                                             changes: SHReferenceChanges(title: "Changed since v23 · now v26",
                                                                         lines: ["padding 24 → 20", "bar color --accent → --slate",
                                                                                 "+ counts under each bar"]),
                                             gets: ["picture", "html", "11 styles", "8 tokens"], openTitle: "Open v26 in design", open: {},
                                             sendLatestTitle: "Send v26", sendLatest: {})
                }
            }
            section("The @ picker") {
                VStack(alignment: .leading, spacing: SH.Space.l) {
                    HStack(alignment: .top, spacing: SH.Space.xl) {
                        picker(designs(picture))
                        picker([SHMentionSection(id: "whole", title: "", rows: [
                            SHMentionRow(id: "w", kind: .board, title: "Whole board", subtitle: "1280 × 800 · 14 elements", trailing: .pick, thumbnail: picture),
                        ]), SHMentionSection(id: "elements", title: "Elements", trailing: "14", rows: [
                            SHMentionRow(id: "e1", kind: .element, title: "card “Checkout funnel”", subtitle: "div · 12 inside", trailing: .pick, thumbnail: picture),
                            SHMentionRow(id: "e2", kind: .element, title: "card “Top exit reasons”", subtitle: "div · 10 inside", trailing: .pick, thumbnail: picture),
                        ])], crumbs: ["Checkout funnel dashboard", "A · Funnel first"], highlighted: "e1")
                    }
                    HStack(alignment: .top, spacing: SH.Space.xl) {
                        picker([SHMentionSection(id: "matches", title: "Designs, boards and elements", trailing: "3 matches", rows: [
                            SHMentionRow(id: "s1", kind: .design, title: "Checkout funnel dashboard", subtitle: "4 boards", lead: "acme-web",
                                         trailing: .drill, thumbnail: picture, matched: ["funnel"]),
                            SHMentionRow(id: "s2", kind: .board, title: "A · Funnel first", crumbs: ["Checkout funnel dashboard"],
                                         subtitle: "board · 1280 × 800", trailing: .drill, thumbnail: picture, matched: ["funnel"]),
                            SHMentionRow(id: "s3", kind: .element, title: "card “Checkout funnel”", crumbs: ["Checkout funnel dashboard", "A · Funnel first"],
                                         subtitle: "element", trailing: .pick, thumbnail: picture, matched: ["funnel"]),
                        ]), SHMentionSection(id: "files", title: "Files", trailing: "1", rows: [
                            SHMentionRow(id: "f1", kind: .file, title: "templates/checkout/funnel.html", subtitle: "dashboard-web", trailing: .pick,
                                         matched: ["funnel"]),
                        ])], highlighted: "s1")
                        VStack(alignment: .leading, spacing: SH.Space.l) {
                            picker([], empty: .nothingMatches(query: "pricng", searched: "Searches this Mac’s designs, boards and elements."))
                            picker([], empty: .noDesigns, startDesign: {})
                        }
                    }
                    // Before and instead of the rows: the read under way, one that failed, and a target with no designs.
                    HStack(alignment: .top, spacing: SH.Space.xl) {
                        VStack(alignment: .leading, spacing: SH.Space.l) {
                            picker([], empty: .loading)
                            picker([], empty: .unavailable("Design references go to spaces on this Mac."))
                        }
                        picker([], empty: .failed(reason: "Reading this Mac’s designs took too long."), retry: {})
                    }
                }
            }
            section("From the canvas") {
                VStack(alignment: .leading, spacing: SH.Space.l) {
                    SHBoardActions(size: .compact, actions: SHBoardActions.Actions(comment: {}, tweak: {}, variations: {}, duplicate: {},
                                                                                  implement: {}))
                        .fixedSize()
                    HStack(alignment: .top, spacing: SH.Space.xl) {
                        SHImplementSheet(picture: picture, title: "Implement card “Checkout funnel”",
                                         crumbs: ["Checkout funnel dashboard", "A · Funnel first"], version: "v23", mode: .constant(.existing),
                                         sends: SHImplementSheet<EmptyView>.sends("Sends a picture, its HTML, 11 styles and 8 tokens from ",
                                                                                   mono: "acme-web", after: "."),
                                         canSend: true, close: {}, send: {}) {
                            SHImplementThreadList(threads: [
                                SHImplementThread(id: "1", name: "Checkout page polish", project: "dashboard-web", age: "4m"),
                                SHImplementThread(id: "2", name: "Funnel events backfill", project: "analytics-ingest", host: "demo-mac", age: "1h"),
                                SHImplementThread(id: "3", name: "Fix CSV export encoding", project: "dashboard-web", age: "yesterday"),
                            ], selection: .constant("1"))
                            SHImplementField("Message") { SHImplementMessageField(text: .constant("Build this in the checkout page.")) }
                            Toggle("Open the thread after sending", isOn: .constant(true)).toggleStyle(.shCheckbox)
                        }
                        SHImplementSheet(picture: picture, title: "Implement A · Funnel first", crumbs: ["Checkout funnel dashboard"],
                                         version: "v23", mode: .constant(.new),
                                         sends: SHImplementSheet<EmptyView>.sends("Sends a picture, the board’s HTML, 42 styles and 14 tokens from ",
                                                                                   mono: "acme-web", after: "."),
                                         canSend: true, close: {}, send: {}) {
                            SHImplementField("Space") {
                                SHImplementProjectLabel(project: "dashboard-web", host: "This Mac")
                                SHImplementBranchLine("Starts on a new worktree,", branch: "agent/implement-a-funnel-first")
                            }
                            SHImplementField("Message") { SHImplementMessageField(text: .constant("")) }
                            Toggle("Open the thread after sending", isOn: .constant(false)).toggleStyle(.shCheckbox)
                        }
                    }
                    HStack(alignment: .top, spacing: SH.Space.xl) {
                        SHReferenceToast(.sent, message: Text("Sent card “Checkout funnel” to \(Text("Checkout page polish").fontWeight(.semibold))."),
                                         actionTitle: "Open thread", actionSymbol: "text.bubble", action: {}, dismiss: {})
                        SHReferenceToast(.copied, message: Text("Copied a reference to card “Checkout funnel”. Paste it into any thread’s composer."),
                                         dismiss: {})
                    }
                }
            }
            section("In the thread") {
                HStack(alignment: .top, spacing: SH.Space.xl) {
                    VStack(alignment: .leading, spacing: 0) {
                        SHActivityLine(kind: .lookedAtDesign, label: "Looked at Checkout funnel dashboard › A · Funnel first",
                                       meta: "picture · html · 11 styles · 8 tokens", isExpanded: true, action: {})
                        SHLookedAtDetails([
                            .init(label: "pic", detail: "A · Funnel first › card “Checkout funnel” @2x", trailing: "756 × 612"),
                            .init(label: "html", detail: "card.html", trailing: "6.2 KB"),
                            .init(label: "css", detail: "11 properties · padding, gap, border-radius, background…"),
                            .init(label: "tok", detail: "--accent --text --muted --border +4", trailing: "web/static/tokens.css:4–16"),
                        ])
                    }
                    .frame(width: 560)
                    HStack(alignment: .top, spacing: SH.Space.m) {
                        SHThreadNotePin()
                        SHThreadNoteCard(thread: "Checkout page polish", age: "12m",
                                         text: "Implemented in #142 on `agent/checkout-funnel`. Bars use `--accent`; counts use the existing table cell.",
                                         from: "from v23", openThread: {}, resolve: {})
                    }
                }
            }
        }
    }

    private func designs(_ picture: SHReferenceImage) -> [SHMentionSection] {
        [SHMentionSection(id: "designs", title: "Designs", trailing: "4 on this Mac · 2 on other hosts", rows: [
            SHMentionRow(id: "d1", kind: .design, title: "Checkout funnel dashboard", subtitle: "4 boards · edited 2h ago", lead: "acme-web",
                         trailing: .drill, thumbnail: picture),
            SHMentionRow(id: "d2", kind: .design, title: "Events explorer", subtitle: "3 boards · yesterday", lead: "acme-web", trailing: .drill,
                         thumbnail: picture),
            SHMentionRow(id: "d3", kind: .design, title: "Pricing page", subtitle: "5 boards · on demo-mac", lead: "acme-web", host: "demo-mac",
                         trailing: .drill, thumbnail: picture),
            SHMentionRow(id: "d4", kind: .design, title: "Refund flow", subtitle: "horizon is offline · last seen 3h ago", host: "horizon",
                         hostOffline: true, trailing: .drill, thumbnail: picture),
        ]), SHMentionSection(id: "files", title: "Files", trailing: "dashboard-web", rows: [
            SHMentionRow(id: "f1", kind: .file, title: "templates/checkout/funnel.html", subtitle: "edited in this thread", trailing: .pick),
        ])]
    }

    private func picker(_ sections: [SHMentionSection], crumbs: [String]? = nil, empty: SHMentionEmpty? = nil, highlighted: String? = "d1",
                        startDesign: (() -> Void)? = nil, retry: (() -> Void)? = nil) -> some View {
        SHMentionPicker(sections: sections, crumbs: crumbs, empty: empty, highlighted: highlighted, choose: { _ in }, drill: { _ in },
                        startDesign: startDesign, retry: retry)
            .frame(width: 528)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: SH.Space.l) {
            Text(title).shSectionLabel()
            content()
        }
    }

    private func specimen<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: SH.Space.xl) {
            content()
            Text(label).font(.shMono(11)).foregroundStyle(Color.sh.textSecondary)
        }
    }
}
