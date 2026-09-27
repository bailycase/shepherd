import SwiftUI
import AppKit
import ImageIO
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

extension EnvironmentValues {
    /// A local thread's design references (DesignRefStates): its chips' copies and freshness, the
    /// "Looked at…" lines' details, the @ picker's catalog, and what a chip does. Nil where
    /// references don't reach: a design's own chat, another host's thread, or with the Design
    /// tool off (docs/designs.md › Isolation).
    @Entry var designReferences: DesignReferenceChips? = nil
    /// Previews: sent chips open their preview as they appear.
    @Entry var designReferencesOpen = false
    /// Previews: "Looked at…" lines open as they appear.
    @Entry var designReferencesExpanded = false
}

/// One thread's design references as its chips, its "Looked at…" lines and its composer's @
/// picker draw them: what the host kept of each sent piece (its picture, the version it went at,
/// what it gets), how it stands against its design now, and the catalog of this Mac's designs.
/// Everything is read off the main thread and the server's queue, once per chip, and again when
/// a design changes (`designsChanged`).
@MainActor @Observable
final class DesignReferenceChips {
    /// What the chips ask the host, and what they do. The view model fills it (tests and previews
    /// their own).
    struct IO {
        var payload: (UUID) async -> (payload: DesignReferencePayload, folder: URL)? = { _ in nil }
        var freshness: (UUID) async -> DesignReferenceFreshness = { _ in .current }
        var pinnedFreshness: (DesignReference) async -> DesignReferenceFreshness = { _ in .current }
        var lookedAt: (String, Set<DesignReferenceAspect>) async -> DesignReferenceLookedAt? = { _, _ in nil }
        /// A piece's picture before it is sent: its board as the canvas last drew it, else the
        /// design's first board.
        var picture: (DesignReference) -> CGImage? = { _ in nil }
        var catalog: () async -> DesignMentionCatalog = { DesignMentionCatalog() }
        /// A picker row's picture: a design's first board, a board's own.
        var rowPicture: (DesignMentionItem) -> CGImage? = { _ in nil }
        /// Asks for the pictures of what a picker scope lists (a design's boards).
        var wantPictures: (MentionScope) -> Void = { _ in }
        var open: (DesignReference) -> Void = { _ in }
        var attach: (DesignReference) async throws -> Void = { _ in }
        var sendLatest: (DesignReference) async throws -> Void = { _ in }
        var startDesign: (() -> Void)? = nil
    }

    /// A sent chip once its copy is read.
    struct Sent: Equatable {
        var crumbs: [String]
        var picture: NWReferenceImage?
        var freshness: DesignReferenceFreshness
        /// "pinned Sep 27, 10:42".
        var pinned: String?
        var system: String?
        var gets: [String]
    }

    let agentID: AgentID
    private(set) var sent: [UUID: Sent] = [:]
    /// Composer chips' standing, by their reference's string.
    private(set) var pinned: [String: DesignReferenceFreshness] = [:]
    private(set) var lookedAt: [String: DesignReferenceLookedAt] = [:]
    private(set) var catalog: DesignMentionCatalog?
    /// Moves when a design changes: chips on screen read again.
    private(set) var generation = 0
    /// Moves when a picture a picker row draws lands.
    private(set) var picturesVersion = 0
    @ObservationIgnored let io: IO
    @ObservationIgnored private var loading: Set<String> = []

    init(agentID: AgentID, io: IO) {
        self.agentID = agentID
        self.io = io
    }

    /// A design changed or went: every chip reads how it stands again.
    func designsChanged() {
        generation += 1
    }

    func picturesChanged() {
        picturesVersion += 1
    }

    /// Reads a sent chip's copy and how it stands now.
    func loadSent(_ id: UUID) async {
        let key = "sent/\(id)/\(generation)"
        guard loading.insert(key).inserted else { return }
        defer { loading.remove(key) }
        async let freshness = io.freshness(id)
        let kept = await io.payload(id)
        var next = sent[id] ?? Sent(crumbs: [], picture: nil, freshness: .current, gets: [])
        if let kept {
            let payload = kept.payload
            next.crumbs = Self.crumbs(payload)
            next.pinned = "pinned " + Self.pinnedTime(payload.capturedAt)
            next.system = payload.system
            next.gets = DesignReferencePresentation.gets(payload.outline)
            if next.picture == nil, let file = payload.picture ?? payload.boards?.first?.picture {
                next.picture = await Self.picture(kept.folder.appendingPathComponent(file.name), id: id.uuidString)
            }
        }
        next.freshness = await freshness
        if sent[id] != next { sent[id] = next }
    }

    /// Reads how a composer chip's pinned version stands against its design now.
    func loadPinned(_ reference: DesignReference) async {
        let freshness = await io.pinnedFreshness(reference)
        if pinned[reference.string] != freshness { pinned[reference.string] = freshness }
    }

    static func lookedAtKey(_ ref: String, _ aspects: [DesignReferenceAspect]) -> String {
        ref + "|" + aspects.map(\.rawValue).joined(separator: ",")
    }

    /// Reads what one "Looked at…" line says.
    func loadLookedAt(_ ref: String, aspects: [DesignReferenceAspect]) async {
        let key = Self.lookedAtKey(ref, aspects)
        guard lookedAt[key] == nil, loading.insert(key).inserted else { return }
        defer { loading.remove(key) }
        if let found = await io.lookedAt(ref, Set(aspects)) { lookedAt[key] = found }
    }

    /// Reads this Mac's designs for the @ picker (again each time it opens).
    func loadCatalog() async {
        let next = await io.catalog()
        if catalog != next { catalog = next }
    }

    /// Previews: what the host would answer.
    func seed(sent: [UUID: Sent] = [:], pinned: [String: DesignReferenceFreshness] = [:], lookedAt: [String: DesignReferenceLookedAt] = [:],
              catalog: DesignMentionCatalog? = nil) {
        self.sent.merge(sent) { $1 }
        self.pinned.merge(pinned) { $1 }
        self.lookedAt.merge(lookedAt) { $1 }
        if let catalog { self.catalog = catalog }
    }

    /// A picker row's picture, while one is at hand.
    func rowPicture(_ item: DesignMentionItem) -> NWReferenceImage? {
        io.rowPicture(item).map { NWReferenceImage(id: item.id + "@\(picturesVersion)", image: Image(decorative: $0, scale: 2)) }
    }

    /// A composer chip's picture.
    func picture(_ reference: DesignReference) -> NWReferenceImage? {
        io.picture(reference).map { NWReferenceImage(id: reference.string + "@\(picturesVersion)", image: Image(decorative: $0, scale: 2)) }
    }

    // MARK: Words

    /// design › board › element, from what the host kept.
    static func crumbs(_ payload: DesignReferencePayload) -> [String] {
        var crumbs = [payload.design]
        if let board = payload.reference.board { crumbs.append(payload.boardTitle ?? board.stem) }
        if payload.reference.element != nil {
            crumbs.append(DesignReferenceReading.elementTitle(name: payload.elementName, label: payload.elementLabel))
        }
        return crumbs
    }

    /// design › board › element, from what a message's record says.
    static func crumbs(_ record: DesignReferenceRecord) -> [String] {
        var crumbs = [record.design ?? "Design"]
        if let board = record.board { crumbs.append(record.boardTitle ?? DesignPath(board)?.stem ?? board) }
        if record.element != nil { crumbs.append(record.elementLabel.map { "“\($0)”" } ?? "element") }
        return crumbs
    }

    /// A composer chip's crumbs, from its label ("Checkout › A · Funnel first › button “Pay”").
    static func crumbs(label: String) -> [String] {
        label.components(separatedBy: MentionScope.separator).filter { !$0.isEmpty }
    }

    static func pinnedTime(_ milliseconds: Double) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMdjmm")
        return formatter.string(from: Date(timeIntervalSince1970: milliseconds / 1000))
    }

    /// How a chip draws `freshness`.
    static func state(_ freshness: DesignReferenceFreshness?) -> NWReferenceState {
        guard let freshness, let words = DesignReferencePresentation.state(freshness) else { return .current }
        switch freshness {
        case .current: return .current
        case .updatedSince: return .updated(words)
        case .deleted: return .deleted(words)
        case .hostOffline: return .hostOffline(host: "host", words: words)
        }
    }

    /// The preview's amber box for a piece the design moved on from.
    static func changes(_ freshness: DesignReferenceFreshness?, version: UInt64?) -> NWReferenceChanges? {
        guard case .updatedSince(let latest, let lines)? = freshness else { return nil }
        let since = version.map { "Changed since v\($0) · now v\(latest)" } ?? "Changed since · now v\(latest)"
        return NWReferenceChanges(title: since, lines: lines.isEmpty ? ["the board changed"] : lines)
    }

    /// A kept picture, scaled for a chip and its preview (read off the main thread).
    static func picture(_ url: URL, id: String) async -> NWReferenceImage? {
        let image = await Task.detached(priority: .utility) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceThumbnailMaxPixelSize: AppLayout.referencePicturePixels,
                                            kCGImageSourceCreateThumbnailWithTransform: true]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
        return image.map { NWReferenceImage(id: id, image: Image(decorative: $0, scale: 2)) }
    }
}

// MARK: - Chips

/// How long the pointer rests on a chip before its preview opens, and lingers after leaving it.
private enum ChipHoverTiming {
    static let open: Duration = .milliseconds(450)
    static let close: Duration = .milliseconds(250)
}

/// Whether a chip's preview is open: after a short hover on the chip, kept while the pointer is on
/// the chip or the preview, and closed a moment after it leaves both.
@MainActor @Observable
final class ReferenceChipHover {
    private(set) var shown = false
    @ObservationIgnored private var inside = 0
    @ObservationIgnored private var timer: Task<Void, Never>?

    init(shown: Bool = false) { self.shown = shown }

    func pointer(_ entered: Bool) {
        inside = max(0, inside + (entered ? 1 : -1))
        timer?.cancel()
        let wanted = inside > 0
        guard wanted != shown else { return }
        timer = Task { [weak self] in
            try? await Task.sleep(for: wanted ? ChipHoverTiming.open : ChipHoverTiming.close)
            guard !Task.isCancelled, let self else { return }
            self.shown = wanted
        }
    }

    func close() {
        timer?.cancel()
        inside = 0
        shown = false
    }

    /// Previews: open at once.
    func show() {
        timer?.cancel()
        shown = true
    }
}

/// The chips a sent message carries (DesignReferenceChip · sent): each opens its piece in the
/// design, and after a short hover its preview (RefChipHover) with Open in design, and Send vN
/// when the design moved on (RefChipUpdated). Without the thread's references (another host's
/// thread), each draws from its record alone.
struct SentReferenceChips: View {
    let records: [DesignReferenceRecord]
    @Environment(\.designReferences) private var references

    var body: some View {
        NWFlowLayout(spacing: NW.Space.s, lineSpacing: NW.Space.s) {
            ForEach(Array(records.enumerated()), id: \.offset) { _, record in
                SentReferenceChip(record: record, references: references)
            }
        }
    }
}

private struct SentReferenceChip: View {
    let record: DesignReferenceRecord
    let references: DesignReferenceChips?
    @State private var hover = ReferenceChipHover()
    @Environment(\.designReferencesOpen) private var startsOpen

    var body: some View {
        let id = record.payloadID
        let kept = id.flatMap { references?.sent[$0] }
        let crumbs = kept.map(\.crumbs).flatMap { $0.isEmpty ? nil : $0 } ?? DesignReferenceChips.crumbs(record)
        let state = DesignReferenceChips.state(kept?.freshness)
        let version = DesignReferencePresentation.version(record.revision)
        NWDesignReferenceChip(crumbs: crumbs, version: version, state: state, thumbnail: kept?.picture, highlighted: hover.shown)
            .contentShape(RoundedRectangle(cornerRadius: NWReferenceMetrics.chipRadius))
            .onTapGesture { open() }
            .onHover { hover.pointer($0) }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { open() }
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .bottomLeading) {
                    if hover.shown, references != nil {
                        NWDesignReferencePreview(
                        picture: kept?.picture, crumbs: crumbs, version: version, pinned: kept?.pinned, system: kept?.system,
                        changes: DesignReferenceChips.changes(kept?.freshness, version: record.revision), gets: kept?.gets ?? [],
                        deleted: kept?.freshness == .deleted,
                        openTitle: Self.openTitle(kept?.freshness),
                        open: kept?.freshness == .deleted ? nil : { open() },
                        sendLatestTitle: kept.flatMap { DesignReferencePresentation.sendLatest($0.freshness) },
                        sendLatest: sendLatest)
                        .onHover { hover.pointer($0) }
                        .nwTransition(.overlay, anchor: .bottomLeading)
                    }
                }
                .fixedSize()
                // The preview opens above the chip, 8pt over it (RefChipHover).
                .alignmentGuide(.top) { $0[.bottom] + NW.Space.m }
            }
            .nwAnimation(.overlay, value: hover.shown)
            .onAppear { if startsOpen { hover.show() } }
            .task(id: TaskKey(id: id, generation: references?.generation ?? 0)) {
                guard let id, let references else { return }
                await references.loadSent(id)
            }
            .onChange(of: hover.shown) { _, shown in
                // Opening the preview reads how it stands again.
                guard shown, let id, let references else { return }
                Task { await references.loadSent(id) }
            }
    }

    private struct TaskKey: Equatable {
        var id: UUID?
        var generation: Int
    }

    static func openTitle(_ freshness: DesignReferenceFreshness?) -> String {
        if case .updatedSince(let latest, _)? = freshness { return "Open v\(latest) in design" }
        return "Open in design"
    }

    private var sendLatest: (() -> Void)? {
        guard let references, let reference = record.reference, case .updatedSince? = record.payloadID.flatMap({ references.sent[$0]?.freshness })
        else { return nil }
        return {
            hover.close()
            Task { try? await references.io.sendLatest(reference) }
        }
    }

    private func open() {
        guard let references, let reference = record.reference, record.payloadID.flatMap({ references.sent[$0]?.freshness }) != .deleted
        else { return }
        hover.close()
        references.io.open(reference)
    }
}

/// A chip waiting in the composer (DesignReferenceChip(ref) · in the composer): removable, its
/// version fixed when it was picked; amber when the design moved on, its preview offering the
/// new version.
struct ComposerReferenceChip: View {
    let attached: NativeAttachedReference
    let references: DesignReferenceChips?
    let remove: () -> Void
    @State private var hover = ReferenceChipHover()

    var body: some View {
        let crumbs = DesignReferenceChips.crumbs(label: attached.label)
        let freshness = references?.pinned[attached.reference.string]
        let version = DesignReferencePresentation.version(attached.reference.revision)
        let picture = references?.picture(attached.reference)
        NWDesignReferenceChip(crumbs: crumbs, version: version, state: DesignReferenceChips.state(freshness), thumbnail: picture,
                              highlighted: hover.shown, remove: remove)
            .onHover { hover.pointer($0) }
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .bottomLeading) {
                    if hover.shown, let references {
                        NWDesignReferencePreview(
                        picture: picture, crumbs: crumbs, version: version, pinned: nil, system: attached.outline?.system,
                        changes: DesignReferenceChips.changes(freshness, version: attached.reference.revision),
                        gets: attached.outline.map(DesignReferencePresentation.gets) ?? [],
                        deleted: freshness == .deleted,
                        openTitle: SentReferenceChip.openTitle(freshness),
                        open: freshness == .deleted ? nil : {
                            hover.close()
                            references.io.open(attached.reference)
                        },
                        sendLatestTitle: freshness.flatMap(DesignReferencePresentation.sendLatest),
                        sendLatest: freshness.flatMap(DesignReferencePresentation.sendLatest) == nil ? nil : {
                            hover.close()
                            Task { try? await references.io.sendLatest(attached.reference) }
                        })
                        .onHover { hover.pointer($0) }
                        .nwTransition(.overlay, anchor: .bottomLeading)
                    }
                }
                .fixedSize()
                .alignmentGuide(.top) { $0[.bottom] + NW.Space.m }
            }
            .nwAnimation(.overlay, value: hover.shown)
            .task(id: "\(attached.reference.string)#\(references?.generation ?? 0)") {
                await references?.loadPinned(attached.reference)
            }
    }
}

// MARK: - "Looked at…"

/// The agent reading a piece it was sent (NWActivityLine(.lookedAtDesign)): one quiet line naming
/// the design and board, its meta what it got; open, the picture, the page, the styles and the
/// tokens with the file each lives in. Without the thread's references, the line says what it
/// read and opens to its calls.
struct LookedAtLineView<Fallback: View>: View {
    let burst: NativeActivityBurst
    @ViewBuilder let fallback: () -> Fallback
    @Environment(\.designReferences) private var references
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.designReferencesExpanded) private var startsOpen

    private var ref: String? { burst.calls.first?.designRef }
    private var aspects: [DesignReferenceAspect] { nativeDesignAspects(burst.calls) }

    var body: some View {
        if burst.state == .done, let references, let ref, let found = references.lookedAt[DesignReferenceChips.lookedAtKey(ref, aspects)] {
            let rows = LookedAtWords.rows(found)
            VStack(alignment: .leading, spacing: 0) {
                NWActivityLine(kind: .lookedAtDesign, label: "Looked at " + found.title, meta: found.meta.joined(separator: " · "),
                               isExpanded: expanded, action: rows.isEmpty ? nil : {
                                   withAnimation(NW.Motion.disclosure.animation(reduceMotion: reduceMotion)) { expanded.toggle() }
                               })
                if expanded {
                    NWLookedAtDetails(rows)
                        .nwTransition(.disclosure)
                }
            }
            .onAppear { if startsOpen { expanded = true } }
        } else {
            fallback()
                .task(id: ref.map { DesignReferenceChips.lookedAtKey($0, aspects) }) {
                    guard burst.state == .done, let references, let ref else { return }
                    await references.loadLookedAt(ref, aspects: aspects)
                }
        }
    }
}

/// What a "Looked at…" line says when it opens.
enum LookedAtWords {
    /// "6.2 KB", "812 B", "1.4 MB".
    static func size(_ bytes: Int) -> String {
        if bytes < 1_000 { return "\(bytes) B" }
        let kb = Double(bytes) / 1_000
        if kb < 1_000 { return String(format: kb < 10 ? "%.1f KB" : "%.0f KB", kb) }
        return String(format: "%.1f MB", kb / 1_000)
    }

    /// The expanded rows: pic, html, css, tok, for what the agent read.
    static func rows(_ found: DesignReferenceLookedAt) -> [NWLookedAtDetails.Row] {
        var rows: [NWLookedAtDetails.Row] = []
        if let picture = found.picture {
            let size = picture.pixelWidth.flatMap { w in picture.pixelHeight.map { "\(w) × \($0)" } }
            rows.append(.init(label: "pic", detail: picture.label, trailing: size))
        }
        if let html = found.html {
            rows.append(.init(label: "html", detail: html.name, trailing: size(html.bytes)))
        }
        if let styles = found.styles {
            let names = styles.names.joined(separator: ", ") + (styles.count > styles.names.count ? "…" : "")
            rows.append(.init(label: "css", detail: "\(styles.count) \(styles.count == 1 ? "property" : "properties")" + (names.isEmpty ? "" : " · " + names)))
        }
        if let tokens = found.tokens, !tokens.names.isEmpty {
            let shown = tokens.names.prefix(4).joined(separator: " ") + (tokens.names.count > 4 ? " +\(tokens.names.count - 4)" : "")
            rows.append(.init(label: "tok", detail: shown, trailing: tokens.sources.isEmpty ? nil : tokens.sources.joined(separator: ", ")))
        }
        return rows
    }
}
