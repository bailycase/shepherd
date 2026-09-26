import CoreGraphics
import Foundation
import ShepherdCore
import ShepherdProtocol

// A host's designs as the iPhone draws them (MobileDesigns, MobileDesignBoard, MobileAgents'
// Designs row and Recents, MobileSearch, MobileMore): plain values derived once per change from
// each host's listing and state. Pure, so the phone's views only draw.

/// A design on one host: design ids are only unique within the host that made them.
public struct HostDesignRef: Hashable, Codable, Sendable {
    public var host: UUID
    public var design: DesignID

    public init(host: UUID, design: DesignID) {
        self.host = host
        self.design = design
    }
}

/// A design's tile on the Designs screen (MobileDesigns): its first board for the thumbnail, its
/// name, and "acme-web · 4 boards · 2m", or "drawing · 2 boards" while its agent works.
public struct RemoteDesignTile: Identifiable, Equatable, Sendable {
    public var ref: HostDesignRef
    public var name: String
    public var detail: String
    /// Its system, else its project; and how many boards it has (search's "acme-web · 4 boards").
    public var system: String?
    public var boards: Int
    public var firstBoard: RemoteDesignFirstBoard?
    /// The host's name when designs from several hosts mix; nil with one host.
    public var hostTag: String?
    public var drawing: Bool
    /// The host's revision of its files, so a thumbnail redraws when they change.
    public var revision: UInt64

    public var id: HostDesignRef { ref }
}

/// A design system's row (MobileDesigns, More ▸ Design systems): its name over where it was read
/// from ("dashboard-web · tokens.css").
public struct RemoteDesignSystemRow: Identifiable, Equatable, Sendable {
    public var host: UUID
    public var namespace: String
    public var name: String
    public var source: String?
    public var hostTag: String?

    public var id: String { "\(host.uuidString)/\(namespace)" }
}

/// Every host's designs, as the phone lists them.
public struct RemoteDesignsModel: Equatable, Sendable {
    public var tiles: [RemoteDesignTile] = []
    public var systems: [RemoteDesignSystemRow] = []
    /// Some connected host serves designs (`designs.v1`): the Designs row and search's section show.
    public var available = false

    public init() {}

    /// Home's Designs row count ("4"), nil at none.
    public var count: String? { tiles.isEmpty ? nil : String(tiles.count) }

    /// More's Design systems row: "2 · acme-web, Night Watch".
    public var systemsSummary: String? {
        guard !systems.isEmpty else { return nil }
        let names = systems.map(\.name)
        var seen = Set<String>()
        let unique = names.filter { seen.insert($0).inserted }
        return "\(systems.count) · " + unique.joined(separator: ", ")
    }

    /// One host's listing and state, as the model is derived from them.
    public struct Host: Equatable, Sendable {
        public var id: UUID
        public var name: String
        public var listing: RemoteDesignListing?
        public var state: ShepherdState

        public init(id: UUID, name: String, listing: RemoteDesignListing?, state: ShepherdState) {
            self.id = id
            self.name = name
            self.listing = listing
            self.state = state
        }
    }

    /// Designs most recently changed first across hosts, then each host's systems in order.
    public init(hosts: [Host], now: Date) {
        available = !hosts.isEmpty
        let tags = hosts.count > 1
        var tiles: [(tile: RemoteDesignTile, at: Double, order: Int)] = []
        for host in hosts {
            guard let listing = host.listing else { continue }
            let spaces = Dictionary(host.state.spaces.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            let agents = Dictionary(host.state.agents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for summary in listing.designs where !summary.design.buildsSystem {
                let design = host.state.designs.first { $0.id == summary.id } ?? summary.design
                let working = design.agentID.flatMap { agents[$0] }?.status == .working
                let system = design.systemNamespace ?? spaces[design.spaceID]
                let detail = RemoteDesignPresentation.tileDetail(system: system, boards: summary.boardCount, drawing: working,
                                                                 edited: design.lastActiveAt, now: now)
                tiles.append((RemoteDesignTile(ref: HostDesignRef(host: host.id, design: design.id), name: design.name,
                                               detail: detail, system: system, boards: summary.boardCount,
                                               firstBoard: summary.firstBoard, hostTag: tags ? host.name : nil,
                                               drawing: working, revision: summary.revision),
                              design.lastActiveAt, tiles.count))
            }
            // The host's own systems by name, then the built-in (Night Watch), as the Mac lists them.
            let own = listing.systems.filter { !$0.builtIn }.sorted { $0.info.title.localizedStandardCompare($1.info.title) == .orderedAscending }
            for system in own + listing.systems.filter(\.builtIn) {
                systems.append(RemoteDesignSystemRow(
                    host: host.id, namespace: system.namespace, name: system.info.title,
                    source: RemoteDesignPresentation.systemSource(system, project: system.info.spaceID.flatMap { spaces[$0] }),
                    hostTag: tags ? host.name : nil))
            }
        }
        self.tiles = tiles.sorted { $0.at != $1.at ? $0.at > $1.at : $0.order < $1.order }.map(\.tile)
    }
}

/// The words and measures the phone's design screens use.
public enum RemoteDesignPresentation {
    /// A tile's line: "acme-web · 4 boards · 2m"; "drawing · 2 boards" while its agent works.
    public static func tileDetail(system: String?, boards: Int, drawing: Bool, edited: Double, now: Date) -> String {
        if drawing { return "drawing · " + boardsText(boards) }
        return [system, boardsText(boards), age(edited, now: now)].compactMap { $0 }.joined(separator: " · ")
    }

    /// "1 board", "4 boards".
    public static func boardsText(_ count: Int) -> String {
        "\(count) board\(count == 1 ? "" : "s")"
    }

    /// A design row in Recents: "design · 4 boards" (MobileAgents).
    public static func recentsDetail(boards: Int?) -> String {
        boards.map { "design · " + boardsText($0) } ?? "design"
    }

    /// A search row's line: "acme-web · 4 boards".
    public static func searchDetail(system: String?, boards: Int) -> String {
        [system, boardsText(boards)].compactMap { $0 }.joined(separator: " · ")
    }

    /// How long ago, as a tile says it: "now", "2m", "3h", "yesterday", "Mon", "Sep 12". `edited`
    /// is milliseconds since 1970.
    public static func age(_ edited: Double, now: Date, calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince1970 - edited / 1000
        if seconds < 60 { return "now" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m" }
        let date = Date(timeIntervalSince1970: edited / 1000)
        if calendar.isDate(date, inSameDayAs: now) { return "\(Int(seconds / 3_600))h" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days == 1 { return "yesterday" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = days > 1 && days < 7 ? "EEE" : "MMM d"
        return formatter.string(from: date)
    }

    /// A system's source line: its project and first stylesheet ("dashboard-web · tokens.css");
    /// Night Watch, built in, names Shepherd's own tokens.
    public static func systemSource(_ system: DesignSystemSummary, project: String?) -> String? {
        if system.builtIn { return "shepherd · ShepherdUI Tokens" }
        return DesignSystemPresentation.source(project: project, sources: system.info.sources)
    }

    // MARK: A board

    /// A board's label: its canvas title ("A · phone"), else its file's name.
    public static func label(_ path: DesignPath, in index: DesignIndex) -> String {
        let title = index.boards[path]?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return title?.isEmpty == false ? title! : path.stem
    }

    /// "390 × 844", the board's CSS size.
    public static func size(_ board: DesignIndex.Board) -> String {
        "\(Int(board.w.rounded())) × \(Int(board.h.rounded()))"
    }

    /// The boards one at a time, in the canvas's order: every board it lists, first the ones in
    /// `order`, then any others by path.
    public static func boards(_ index: DesignIndex) -> [DesignPath] {
        var seen = Set<DesignPath>()
        var list = index.order.filter { index.boards[$0] != nil && seen.insert($0).inserted }
        list += index.boards.keys.filter { !seen.contains($0) }.sorted()
        return list
    }

    /// The scale that fits a board of `board` points in `space`, never larger than 1.
    public static func fit(_ board: CGSize, in space: CGSize) -> CGFloat {
        guard board.width > 0, board.height > 0, space.width > 0, space.height > 0 else { return 1 }
        return min(1, space.width / board.width, space.height / board.height)
    }

    /// The scale a tile of `tile` draws a board of `board` at: its width across the tile for a
    /// board wider than tall (top-leading); a phone board shows its top, centered, as wide as
    /// `phoneTileWidth` of the tile's height (MobileDesigns: 90pt in a 110pt tile).
    public static func tileScale(_ board: CGSize, in tile: CGSize) -> CGFloat {
        guard board.width > 0, board.height > 0 else { return 1 }
        return board.height > board.width ? tile.height * phoneTileWidth / board.width : tile.width / board.width
    }

    /// How wide a phone board is drawn in a tile, as a share of the tile's height.
    public static let phoneTileWidth: CGFloat = 90.0 / 110.0

    /// Clamps a zoom the viewer pinched to (a multiple of the fitted scale).
    public static func clampZoom(_ zoom: CGFloat) -> CGFloat {
        guard zoom.isFinite else { return 1 }
        return min(max(zoom, minZoom), maxZoom)
    }

    public static let minZoom: CGFloat = 1
    public static let maxZoom: CGFloat = 4

    /// How far a zoomed board can be panned: half the room it overhangs on each axis.
    public static func clampPan(_ offset: CGSize, content: CGSize, space: CGSize) -> CGSize {
        let x = max(0, (content.width - space.width) / 2)
        let y = max(0, (content.height - space.height) / 2)
        return CGSize(width: min(max(offset.width, -x), x), height: min(max(offset.height, -y), y))
    }

    // MARK: Comments

    /// A board's open comments in their pins' order.
    public static func pins(_ comments: DesignComments?, board: DesignPath) -> [DesignComment] {
        (comments?.comments ?? []).filter { $0.isOpen && $0.board == board }.sorted { $0.number < $1.number }
    }

    /// What a comment's card names: "Steps list", its element's name or words.
    public static func target(_ comment: DesignComment) -> String {
        let name = comment.target ?? comment.label
        return name?.isEmpty == false ? name! : "element \(comment.tid)"
    }

    /// Who wrote it and when: "You · now", "Design agent · 1m".
    public static func meta(_ author: DesignCommentAuthor, at created: Double, now: Date) -> String {
        (author == .user ? "You" : "Design agent") + " · " + age(created, now: now)
    }

    /// While the design agent works on a comment it hasn't answered: "Design agent is updating
    /// A · phone". Nil once it answered, or while it isn't working.
    public static func updating(_ comment: DesignComment, agentWorking: Bool, board: String) -> String? {
        guard agentWorking, !comment.replies.contains(where: { $0.author == .agent }) else { return nil }
        return "Design agent is updating \(board)"
    }

    /// The design agent's latest answer under a comment.
    public static func answer(_ comment: DesignComment) -> DesignCommentReply? {
        comment.replies.last { $0.author == .agent }
    }

    /// What the phone shows of a design to the agent with a message: the board on screen, and
    /// the element a comment is being written on.
    public static func viewRecord(board: DesignPath, picked: DesignElementID?, kind: DesignElementKind?, label: String?) -> DesignViewRecord {
        var record = DesignViewRecord(visibleBoards: [board.viewName])
        if let picked {
            record.selectedBoards = [board.viewName]
            record.selected = [picked]
            record.selection = [DesignViewRecord.Selection(id: picked, kind: kind ?? .other, label: label.flatMap(DesignViewRecord.label))]
        }
        return record.isValid ? record : DesignViewRecord(visibleBoards: [board.viewName])
    }

    // MARK: New design

    /// Search's action line: "“funnel” as the brief", with the query marked.
    public static func briefParts(_ query: String) -> [(text: String, highlighted: Bool)] {
        [("\u{201C}", false), (query, true), ("\u{201D} as the brief", false)]
    }
}
