import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// Design references in a thread (RefPasted, RefAtDesigns, RefAtElements, RefAtSearch,
/// RefSentThread, RefChipHover, RefChipUpdated, RefAgentRead): the composer's chip and @ picker,
/// the chip in a sent message with its preview, and the agent's "Looked at…" line. The thread's
/// references answer from fixtures, as the host would.
extension ThreadPreviewTests {
    static let referenceSize = CGSize(width: 1180, height: 900)
    static let referenceDesign = DesignID(rawValue: "checkout-funnel")
    static let referenceBoard = DesignPath("A.dc.html")!
    static let referenceElement = DesignElementID(board: "A.dc.html", tid: 7, path: [1, 1, 0])!
    static let referencePayload = UUID(uuidString: "5E2C3B1A-8B6F-4E55-9C0B-1F7C2D4A9E01")!

    /// The piece every thread preview sends: card “Checkout funnel” on A · Funnel first, at v23.
    static var sentReference: DesignReference {
        DesignReference(designID: referenceDesign, board: referenceBoard, element: referenceElement, revision: 23)!
    }

    /// A board's picture, drawn in its own colors (a white page of indigo bars).
    static func referencePicture(width: Int = 632, height: Int = 380) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.973, green: 0.98, blue: 0.988, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let unit = CGFloat(width) / 40
        for index in 0..<5 {
            context.setFillColor(CGColor(red: 0.31, green: 0.275, blue: 0.898, alpha: 1 - CGFloat(index) * 0.12))
            let y = CGFloat(height) - unit * 3 - CGFloat(index) * unit * 3
            context.fill(CGRect(x: unit * 2, y: y, width: CGFloat(width) * (0.85 - CGFloat(index) * 0.15), height: unit * 1.6))
        }
        return context.makeImage()!
    }

    /// An element's own picture, as the rasterizer would cut it from board A (drawn in the
    /// board's colors at the row's 80×52 pixels): the funnel's bars, the exit reasons' rows, a
    /// tile's figure, the filters' chips.
    static func elementPicture(_ detail: String) -> CGImage {
        let size = AppLayout.referenceCropPixels
        let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let w = size.width, h = size.height
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let indigo = CGColor(red: 0.31, green: 0.275, blue: 0.898, alpha: 1)
        let ink = CGColor(red: 0.11, green: 0.11, blue: 0.16, alpha: 1)
        let muted = CGColor(red: 0.8, green: 0.8, blue: 0.85, alpha: 1)
        // Top-down, as the thumbnail shows it (CoreGraphics counts from the bottom).
        func box(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ color: CGColor) {
            context.setFillColor(color)
            context.fill(CGRect(x: x, y: h - y - height, width: width, height: height))
        }
        if detail.hasPrefix("funnel") {
            box(6, 5, 26, 3, ink)
            for (index, share) in [1.0, 0.27, 0.2, 0.14, 0.09].enumerated() {
                box(6, 13 + CGFloat(index) * 8, 12, 3, muted)
                box(22, 12 + CGFloat(index) * 8, (w - 30) * share, 5, indigo)
            }
        } else if detail.hasPrefix("list") {
            box(6, 5, 30, 3, ink)
            for index in 0..<5 {
                box(6, 13 + CGFloat(index) * 8, 34, 3, muted)
                box(w - 16, 13 + CGFloat(index) * 8, 10, 3, ink)
            }
        } else if detail.contains("tile") {
            box(6, 6, 34, 3, muted)
            box(6, 16, 30, 10, ink)
            box(40, 19, 14, 5, CGColor(red: 0.13, green: 0.6, blue: 0.35, alpha: 1))
            box(6, 32, 38, 3, muted)
        } else {
            for (index, width) in [30.0, 14, 14, 20].enumerated() {
                let x = 4 + [0.0, 34, 50, 66][index]
                box(x, 20, width, 11, index == 0 ? CGColor(red: 0.91, green: 0.91, blue: 0.99, alpha: 1) : muted)
            }
        }
        return context.makeImage()!
    }

    /// The thread's references, answering from fixtures: the sent copy as `freshness` has it, what
    /// the agent looked at, and this Mac's designs for the @ picker.
    static func referenceChips(freshness: DesignReferenceFreshness = .current) -> DesignReferenceChips {
        let picture = referencePicture()
        let lookedAt = DesignReferenceLookedAt(
            ref: sentReference.string, title: "Checkout funnel dashboard › A · Funnel first", aspects: [.image, .html, .element, .tokens],
            picture: .init(label: "A · Funnel first › card “Checkout funnel” @2x", pixelWidth: 756, pixelHeight: 612),
            html: .init(name: "card.html", bytes: 6_349),
            styles: .init(count: 11, names: ["padding", "gap", "border-radius", "background"]),
            tokens: .init(names: ["--accent", "--text", "--muted", "--border", "--radius-m", "--space-4", "--space-6", "--surface"],
                          sources: ["web/static/tokens.css:4–16"]))
        let chips = DesignReferenceChips(agentID: AgentID(rawValue: "preview"), io: DesignReferenceChips.IO(
            freshness: { _ in freshness },
            pinnedFreshness: { _ in .current },
            lookedAt: { _, _ in lookedAt },
            picture: { _ in picture },
            catalog: { mentionCatalog },
            rowPicture: { item in item.kind == .element ? elementPicture(item.detail ?? "") : picture }))
        chips.seed(sent: [referencePayload: DesignReferenceChips.Sent(
            crumbs: ["Checkout funnel dashboard", "A · Funnel first", "card “Checkout funnel”"],
            picture: NWReferenceImage(id: "sent", image: Image(decorative: picture, scale: 2)), freshness: freshness,
            pinned: "pinned Sep 27, 10:42", system: "acme-web", gets: ["picture", "html", "11 styles", "8 tokens"])],
                   catalog: mentionCatalog)
        return chips
    }

    /// This Mac's designs as the @ picker lists them: four designs, the checkout's boards, and A's
    /// elements.
    static var mentionCatalog: DesignMentionCatalog {
        let now = Date().timeIntervalSince1970 * 1000
        func design(_ id: String, _ name: String, boards: Int, hoursAgo: Double) -> DesignMentionItem {
            DesignMentionItem(kind: .design, reference: DesignReference(designID: DesignID(rawValue: id), board: nil)!, title: name,
                              breadcrumb: [], system: "acme-web", boardCount: boards, activeAt: now - hoursAgo * 3_600_000)
        }
        let checkout = design("checkout-funnel", "Checkout funnel dashboard", boards: 4, hoursAgo: 2)
        let designs = [checkout, design("events", "Events explorer", boards: 3, hoursAgo: 26),
                       design("onboarding", "Onboarding flow", boards: 9, hoursAgo: 72), design("pricing", "Pricing page", boards: 5, hoursAgo: 120)]
        func board(_ path: String, _ title: String, elements: Int) -> DesignMentionItem {
            DesignMentionItem(kind: .board, reference: DesignReference(designID: referenceDesign, board: DesignPath(path)!)!, title: title,
                              breadcrumb: ["Checkout funnel dashboard"], width: 1280, height: 800, elementCount: elements)
        }
        let a = board("A.dc.html", "A · Funnel first", elements: 14)
        let boards = [a, board("B.dc.html", "B · Step table", elements: 18), board("C.dc.html", "C · Trend first", elements: 12)]
        func element(_ tid: Int, _ path: [Int], _ title: String, _ detail: String) -> DesignMentionItem {
            DesignMentionItem(kind: .element,
                              reference: DesignReference(designID: referenceDesign, board: referenceBoard,
                                                         element: DesignElementID(board: "A.dc.html", tid: tid, path: path)!)!,
                              title: title, breadcrumb: ["Checkout funnel dashboard", "A · Funnel first"], detail: detail)
        }
        // Board A's fourteen elements, in the order the board lists them (as DesignElementSummary
        // says them for a board drawn like A: DesignElementSummaryTests).
        let elements = [element(7, [1, 1, 0], "card “Checkout funnel”", "funnel bars · 5 steps"),
                        element(24, [1, 1, 1], "card “Top exit reasons”", "list · 5 rows"),
                        element(3, [1, 0, 0], "tile “Sessions with cart”", "KPI tile · 1 of 4"),
                        element(12, [1, 0, 2], "bar “Filters”", "chips · All platforms, Web, iOS, Android"),
                        element(4, [1, 0, 1], "tile “Reached checkout”", "KPI tile · 2 of 4"),
                        element(5, [1, 0, 3], "tile “Placed order”", "KPI tile · 3 of 4"),
                        element(6, [1, 0, 4], "tile “Overall conversion”", "KPI tile · 4 of 4"),
                        element(2, [1, 0], "KPI “Sessions with cart”", "grid · 4 tiles"),
                        element(8, [1, 1, 0, 0], "text “Where people drop off between cart and order.”", "paragraph"),
                        element(9, [1, 1, 0, 1], "button “Last 30 days”", "button"),
                        element(10, [1, 1, 0, 1, 0], "step “Cart viewed”", "funnel bars step · 1 of 5"),
                        element(11, [1, 1, 0, 1, 1], "step “Checkout started”", "funnel bars step · 2 of 5"),
                        element(25, [1, 1, 1, 1], "group “Shipping cost shown”", "list · 5 rows"),
                        element(13, [1, 0, 2, 0], "button “All platforms”", "bar button · 1 of 4")]
        var boardsByDesign: [DesignID: [DesignMentionItem]] = [referenceDesign: boards]
        boardsByDesign[DesignID(rawValue: "onboarding")] = [
            DesignMentionItem(kind: .board, reference: DesignReference(designID: DesignID(rawValue: "onboarding"), board: DesignPath("Intro.dc.html")!)!,
                              title: "Funnel intro", breadcrumb: ["Onboarding flow"], width: 390, height: 844, elementCount: 6),
        ]
        return DesignMentionCatalog(designs: designs, boards: boardsByDesign, elements: [a.id: elements])
    }

    /// A thread that asked for the checkout page, and the reply; `sent` adds the message that
    /// carried the reference and what the agent did with it. `brief` ends the turn as
    /// RefChipUpdated does: the look, one edit and the reply, without the read.
    static func referenceSnapshot(sent: Bool, read: Bool = false, running: Bool = false, brief: Bool = false) -> NativeThreadSnapshot {
        var snapshot = Threads.empty
        snapshot.supportedActions += ["designReferences"]
        snapshot.running = running
        // Now, less the half hour since the first message: the running call's clock reads a moment.
        let start = Date().timeIntervalSince1970 * 1000 - 1_834_000
        var messages = [
            NativeThreadMessage(entryID: "u0", role: "user", blocks: [.init(kind: .text,
                                text: "Check why the checkout header jumps on narrow windows.")], timestamp: start - 600_000),
            NativeThreadMessage(entryID: "a0", role: "assistant", blocks: [.init(kind: .text,
                                text: "The header's padding comes from the old layout, and the shared one sets its own. Moving the page onto the shared layout fixes both.")],
                                timestamp: start - 540_000),
            NativeThreadMessage(entryID: "u1", role: "user", blocks: [.init(kind: .text,
                                text: "Move the checkout page onto the shared layout and fix the header spacing.")], timestamp: start),
            NativeThreadMessage(entryID: "a1", role: "assistant", blocks: [.init(kind: .text,
                                text: "Moved the checkout page onto the shared layout and fixed the header spacing. The funnel section is still the old table.")],
                                timestamp: start + 60_000),
        ]
        if sent {
            let record = DesignReferenceRecord(ref: sentReference.string, design: "Checkout funnel dashboard", board: "A",
                                               boardTitle: "A · Funnel first", element: referenceElement.description,
                                               elementLabel: "Checkout funnel", revision: 23, payload: referencePayload.uuidString)
            messages.append(NativeThreadMessage(entryID: "u2", role: "user", blocks: [.init(kind: .text,
                text: "Build this in the checkout page. Keep our existing table component for the steps.\n\n1 design reference attached.")],
                timestamp: start + 1_800_000, designReferences: [record]))
        }
        if read {
            func get(_ id: String, _ what: String, at: Double) -> NativeThreadMessage {
                NativeThreadMessage(entryID: id, role: "toolResult", blocks: [.init(kind: .text, text: "fenced design data")], toolName: "design_get",
                                    toolCallID: id, argumentsText: #"{"ref":"\#(sentReference.string)","what":"\#(what)"}"#, status: "complete",
                                    timestamp: at, startedAt: at - 400)
            }
            let t = start + 1_830_000
            messages += [get("g1", "image", at: t), get("g2", "html", at: t + 1_000), get("g3", "element", at: t + 2_000),
                         get("g4", "tokens", at: t + 3_000)]
            if brief {
                messages += [
                    NativeThreadMessage(entryID: "e1", role: "toolResult", blocks: [.init(kind: .text, text: "ok")], toolName: "edit",
                                        toolCallID: "e1",
                                        argumentsText: #"{"path":"templates/checkout/funnel.html","oldText":"<table>","newText":"<section class=\"funnel\">\n<div>"}"#,
                                        status: "complete", timestamp: t + 9_000),
                    NativeThreadMessage(entryID: "a2", role: "assistant", blocks: [.init(kind: .text,
                        text: "The funnel card is in `templates/checkout/funnel.html`, using `--accent` for the bars and the existing table cell for counts.")],
                        timestamp: t + 12_000),
                ]
            } else if !running {
                messages += [
                    NativeThreadMessage(entryID: "r1", role: "toolResult", blocks: [.init(kind: .text, text: "<main>…</main>")], toolName: "read",
                                        toolCallID: "r1", argumentsText: #"{"path":"templates/checkout/funnel.html"}"#, status: "complete",
                                        timestamp: t + 5_000),
                    NativeThreadMessage(entryID: "e1", role: "toolResult", blocks: [.init(kind: .text, text: "ok")], toolName: "edit",
                                        toolCallID: "e1",
                                        argumentsText: #"{"path":"templates/checkout/funnel.html","oldText":"<table>","newText":"<section class=\"funnel\">\n<div>"}"#,
                                        status: "complete", timestamp: t + 9_000),
                    NativeThreadMessage(entryID: "a2", role: "assistant", blocks: [.init(kind: .text,
                        text: "The funnel card is in the checkout page now. Bars use `--accent` and the step counts reuse the existing table cell, so it matches the design without new styles.")],
                        timestamp: t + 12_000),
                ]
            } else {
                messages.append(NativeThreadMessage(entryID: "r1", role: "toolResult", blocks: [], toolName: "read", toolCallID: "r1",
                                                    argumentsText: #"{"path":"templates/checkout/funnel.html"}"#, status: "running",
                                                    startedAt: t + 4_000))
            }
        }
        snapshot.messages = messages
        return snapshot
    }

    private func renderReferences(_ surface: String, _ snapshot: NativeThreadSnapshot, chips: DesignReferenceChips, draft: String = "",
                                  attached: [NativeAttachedReference] = [], open: Bool = false, expanded: Bool = false,
                                  ready: @escaping @MainActor () -> Bool = { true }) async throws {
        let fixture = ThreadFixture(snapshot)
        defer { fixture.store.stop() }
        let store = fixture.store
        try await Preview.render(surface, size: Self.referenceSize, ready: {
            guard store.ready, !store.rows.isEmpty || snapshot.messages.isEmpty else { return false }
            if store.attachedReferences.isEmpty, !attached.isEmpty { for reference in attached { _ = store.attach(reference: reference) } }
            if store.draft != draft, !draft.isEmpty { store.draft = draft }
            return ready()
        }) {
            fixture.thread(title: "Checkout page polish", workingDirectory: "~/Developer/dashboard-web")
                .environment(\.designReferences, chips)
                .environment(\.designReferencesOpen, open)
                .environment(\.designReferencesExpanded, expanded)
        }
    }

    static var attachedReference: NativeAttachedReference {
        NativeAttachedReference(reference: sentReference, label: "Checkout funnel dashboard › A · Funnel first › card “Checkout funnel”",
                                outline: DesignReferenceOutline(kind: .element, styles: 11, tokens: 8, system: "acme-web"))
    }

    /// RefPasted: a pasted reference became a chip above the words in the composer.
    @Test func referencePasted() async throws {
        try await renderReferences("thread-reference-pasted", Self.referenceSnapshot(sent: false), chips: Self.referenceChips(),
                                   draft: "Build this in the checkout page. Keep our existing table", attached: [Self.attachedReference])
    }

    /// RefAtDesigns: "@" opens the picker on this Mac's designs, with their pictures.
    @Test func referenceAtDesigns() async throws {
        try await renderReferences("thread-reference-at-designs", Self.referenceSnapshot(sent: false), chips: Self.referenceChips(),
                                   draft: "Match the funnel in @", ready: { true })
    }

    /// RefAtElements: inside a board, "Whole board" then its elements, the breadcrumb over them.
    @Test func referenceAtElements() async throws {
        try await renderReferences("thread-reference-at-elements", Self.referenceSnapshot(sent: false), chips: Self.referenceChips(),
                                   draft: "Match the funnel in @Checkout funnel dashboard › A · Funnel first › ")
    }

    /// RefAtSearch: "@funnel" matches designs, boards and elements, each with its path.
    @Test func referenceAtSearch() async throws {
        try await renderReferences("thread-reference-at-search", Self.referenceSnapshot(sent: false), chips: Self.referenceChips(),
                                   draft: "Match the funnel in @funnel")
    }

    /// RefSentThread: the message carries the chip; the agent looks at it (one quiet line) and
    /// goes on reading.
    @Test func referenceSentThread() async throws {
        try await renderReferences("thread-reference-sent", Self.referenceSnapshot(sent: true, read: true, running: true),
                                   chips: Self.referenceChips())
    }

    /// RefChipHover: the chip's bigger preview with Open in design.
    @Test func referenceChipHover() async throws {
        try await renderReferences("thread-reference-chip-hover", Self.referenceSnapshot(sent: true), chips: Self.referenceChips(), open: true)
    }

    /// RefChipHover with the chip at the thread's top: no room above it, so the preview opens
    /// under it.
    @Test func referenceChipHoverAtTheTop() async throws {
        var snapshot = Self.referenceSnapshot(sent: true)
        snapshot.messages = snapshot.messages.filter { $0.entryID == "u2" }
        try await renderReferences("thread-reference-chip-hover-top", snapshot, chips: Self.referenceChips(), open: true)
    }

    /// RefChipUpdated: the design moved on; the chip is amber and its preview lists what changed,
    /// with Send v26.
    @Test func referenceChipUpdated() async throws {
        let changes = ["padding 24 → 20", "bar color --accent → --slate", "+ counts under each bar"]
        try await renderReferences("thread-reference-chip-updated", Self.referenceSnapshot(sent: true, read: true, brief: true),
                                   chips: Self.referenceChips(freshness: .updatedSince(latest: 26, changes: changes)), open: true)
    }

    /// RefAgentRead: the "Looked at…" line open, with the picture, page, styles and tokens it got.
    @Test func referenceAgentRead() async throws {
        try await renderReferences("thread-reference-agent-read", Self.referenceSnapshot(sent: true, read: true),
                                   chips: Self.referenceChips(), expanded: true)
    }
}
