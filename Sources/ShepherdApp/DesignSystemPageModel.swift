import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

/// What a design system's page shows: a system by its namespace, or a system build ("Build one
/// from a repo") whose agent may not have written its system yet.
enum DesignSystemTarget: Hashable {
    case system(String)
    case build(DesignID)
}

/// A design system's page (DZSystem) as plain values: its header, where it was read from, the
/// section list with its counts, and each section's rows. Pure: derived once per change from the
/// catalog and the workspace, never in a view's body.
struct DesignSystemPageModel: Equatable {
    enum Section: String, CaseIterable {
        case colors, type, steps, components, boards

        var title: String {
            switch self {
            case .colors: "Colors"
            case .type: "Type"
            case .steps: "Spacing & radii"
            case .components: "Components"
            case .boards: "Boards using it"
            }
        }
    }

    /// A run of the source line; paths and names are mono.
    struct Segment: Equatable {
        let text: String
        let mono: Bool
    }

    struct Swatch: Equatable, Identifiable {
        var id: String { name }
        let name: String
        /// "#4f46e5 · tokens.css:8".
        let detail: String
        /// Its value as a hex; nil for a color the page can't draw (`hsl()`, a named color).
        let hex: String?
    }

    struct TypeRow: Equatable, Identifiable {
        var id: String { name }
        let name: String
        let sample: String
        let size: Double
        let weight: Int?
        /// The system's own face for it, when it names one.
        let family: String?
        /// "26/700".
        let spec: String
    }

    struct Step: Equatable, Identifiable {
        var id: String { name }
        let name: String
        /// "16px · tokens.css:20".
        let detail: String
    }

    struct Component: Equatable, Identifiable {
        /// Its place in the system's list: what its specimen is kept by.
        let id: Int
        let name: String
        /// "partials/button.html".
        let template: String?
        /// The system's file holding its specimen.
        let specimen: String?
    }

    struct BoardsRow: Equatable, Identifiable {
        let id: DesignID
        let name: String
        /// "4 boards".
        let detail: String
    }

    /// The system's folder name; nil while a build has written none.
    var namespace: String?
    var title = ""
    var status: NWDesignHeaderStatus?
    var source: [Segment] = []
    var builtIn = false
    var canResync = false
    var syncing = false
    /// A build whose agent hasn't written its system yet.
    var building = false
    /// The chip's colors.
    var chip: [DesignSystemPresentation.Swatch] = []
    /// What its specimens draw on.
    var background: String?
    var sections: [NWSectionRail.Section] = []
    var colors: [Swatch] = []
    var type: [TypeRow] = []
    var steps: [Step] = []
    var components: [Component] = []
    var boards: [BoardsRow] = []
    /// Moves when the system's files change: its specimens are drawn again then.
    var revision = ""

    static func make(summary: DesignSystemSummary?, read: DesignSystemRead?, build: Design?, spaces: [Space],
                     designs: [Design], syncing: Bool, now: Date) -> DesignSystemPageModel {
        var model = DesignSystemPageModel()
        let names = Dictionary(spaces.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        guard let summary else {
            // A build whose agent is still reading the project.
            let project = build?.sourceSpaceID.flatMap { names[$0] }
            model.title = build?.name ?? ""
            model.building = build != nil
            model.source = [Segment(text: "Reading ", mono: false), Segment(text: project ?? model.title, mono: true),
                            Segment(text: "…", mono: false)]
            return model
        }
        let info = summary.info
        let tokens = read?.tokens
        model.namespace = info.namespace
        model.title = info.title
        model.builtIn = summary.builtIn
        model.syncing = syncing
        model.revision = "\(info.revision)"
        let project = info.spaceID.flatMap { names[$0] }
        model.canResync = !summary.builtIn && !info.sources.isEmpty && project != nil
        if syncing {
            model.status = .init(.running, label: "Syncing")
        } else if !summary.builtIn, info.syncedAt != nil {
            model.status = .init(.done, label: "Synced")
        }
        model.source = sourceLine(summary, tokens: tokens, project: project, now: now)
        model.chip = DesignSystemPresentation.swatches(tokens, count: 3)
        // A system that names no background draws on a page's own white, as its boards do.
        model.background = DesignSystemPresentation.background(tokens)?.light ?? "#ffffff"

        if let tokens {
            model.colors = tokens.colors.map { color in
                Swatch(name: color.name, detail: DesignSystemPresentation.detail(color), hex: DesignSystemPresentation.hex(color.value))
            }
            model.type = tokens.type.map { style in
                let family = style.family.map { name in tokens.fonts.first { $0.name == name }?.family ?? name }
                var sample = style.sample?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if sample.isEmpty { sample = style.name }
                if style.transform == "uppercase" { sample = sample.uppercased() }
                return TypeRow(name: style.name, sample: sample, size: style.size, weight: style.weight, family: family,
                               spec: DesignSystemPresentation.detail(style))
            }
            model.steps = (tokens.spacing + tokens.radii).map { Step(name: $0.name, detail: DesignSystemPresentation.detail($0)) }
            model.components = tokens.components.enumerated().map { index, component in
                Component(id: index, name: component.name, template: component.source.map { templateLabel($0.file) },
                          specimen: component.specimen)
            }
        }
        let using = designs.filter { !$0.buildsSystem && $0.systemNamespace == info.namespace }
            .sorted { $0.lastActiveAt > $1.lastActiveAt }
        model.boards = using.map { BoardsRow(id: $0.id, name: $0.name, detail: DesignsPageModel.boardsText($0.boardCount ?? 0)) }
        let counts = tokens?.counts ?? summary.counts
        model.sections = [
            .init(id: Section.colors.rawValue, title: Section.colors.title, count: counts.colors),
            .init(id: Section.type.rawValue, title: Section.type.title, count: counts.type),
            .init(id: Section.steps.rawValue, title: Section.steps.title, count: counts.lengths),
            .init(id: Section.components.rawValue, title: Section.components.title, count: counts.components),
            .init(id: Section.boards.rawValue, title: Section.boards.title, count: using.reduce(0) { $0 + ($1.boardCount ?? 0) }),
        ]
        return model
    }

    /// "Read from `dashboard-web`: `web/static/tokens.css` and 9 templates in
    /// `templates/partials/` · synced 4m ago". A built-in says where Shepherd made it; a system
    /// whose project is gone says what it holds.
    static func sourceLine(_ summary: DesignSystemSummary, tokens: DesignSystemTokens?, project: String?,
                           now: Date) -> [Segment] {
        if summary.builtIn { return [Segment(text: "Generated from ShepherdUI's tokens", mono: false)] }
        let info = summary.info
        var segments: [Segment] = []
        var parts: [[Segment]] = info.sources.map { [Segment(text: $0, mono: true)] }
        let templates = (tokens?.components ?? []).compactMap { $0.source?.file }
        if !templates.isEmpty {
            var part = [Segment(text: templates.count == 1 ? "1 template" : "\(templates.count) templates", mono: false)]
            if let folder = commonFolder(templates) {
                part += [Segment(text: " in ", mono: false), Segment(text: folder + "/", mono: true)]
            }
            parts.append(part)
        }
        if let project {
            segments = [Segment(text: "Read from ", mono: false), Segment(text: project, mono: true)]
            if !parts.isEmpty { segments.append(Segment(text: ": ", mono: false)) }
        } else if parts.isEmpty {
            segments = [Segment(text: DesignSystemPresentation.counts(summary.counts), mono: false)]
        }
        for (index, part) in parts.enumerated() {
            if index > 0 { segments.append(Segment(text: index == parts.count - 1 ? " and " : ", ", mono: false)) }
            segments += part
        }
        if let synced = DesignSystemPresentation.synced(info, now: now) {
            segments.append(Segment(text: " · " + synced, mono: false))
        }
        return merged(segments)
    }

    /// The folder every file is in, when they share one.
    static func commonFolder(_ files: [String]) -> String? {
        let folders = Set(files.map { file -> String in
            let parts = file.split(separator: "/")
            return parts.dropLast().joined(separator: "/")
        })
        guard folders.count == 1, let folder = folders.first, !folder.isEmpty else { return nil }
        return folder
    }

    /// A template as its tile names it: its folder and name ("partials/button.html").
    static func templateLabel(_ file: String) -> String {
        file.split(separator: "/").suffix(2).joined(separator: "/")
    }

    private static func merged(_ segments: [Segment]) -> [Segment] {
        var out: [Segment] = []
        for segment in segments where !segment.text.isEmpty {
            if let last = out.last, last.mono == segment.mono {
                out[out.count - 1] = Segment(text: last.text + segment.text, mono: last.mono)
            } else {
                out.append(segment)
            }
        }
        return out
    }
}

/// What a system's page is derived from.
struct DesignSystemPageInputs: Equatable {
    var summary: DesignSystemSummary?
    var read: DesignSystemRead?
    var build: Design?
    var spaces: [Space]
    var designs: [Design]
    var syncing: Bool
    /// The minute "synced 4m ago" was worded in.
    var minute: Int
}

// MARK: Specimens

/// A component's specimen as a board Shepherd's renderer draws (DZSystem's tiles): the system's
/// specimen file inside a board of the tile's size, on the system's background, with its
/// stylesheet linked. It is written for the renderer alone and never stored.
enum DesignSpecimenBoard {
    /// The board's size: a tile 92pt tall, and room for a row of controls.
    static let size = CGSize(width: 320, height: 92)
    /// A specimen larger than this isn't drawn.
    static let maxSpecimenBytes = 64 * 1024

    /// Where the board for component `index` sits among the system's files.
    static func path(_ index: Int) -> String { "_specimen-\(index).dc.html" }

    static func source(specimen: String, title: String, stylesheet: Bool, background: String?) -> String {
        let fill = background.flatMap(DesignSystemPresentation.hex).map { "background: \($0); " } ?? ""
        return """
            <!doctype html>
            <html lang="en">
            <head>
            <meta charset="utf-8">
            <title>\(escaped(title))</title>
            <script src="./support.js"></script>
            \(stylesheet ? "<link rel=\"stylesheet\" href=\"tokens.css\">\n" : "")</head>
            <body>
            <x-dc>
            <helmet><style>body{margin:0}</style></helmet>
            <div style="width: \(Int(size.width))px; height: \(Int(size.height))px; box-sizing: border-box; display: flex; \
            align-items: center; justify-content: center; gap: 8px; overflow: hidden; \(fill)">
            \(specimen)
            </div>
            </x-dc>
            </body>
            </html>

            """
    }

    /// The boards for a system's specimens, by path, from its files: nil for a component with no
    /// specimen, or one that isn't a file of the system.
    static func boards(_ tokens: DesignSystemTokens?, files: [String: Data], background: String?) -> [Int: (path: String, source: String)] {
        guard let tokens else { return [:] }
        let stylesheet = files[DesignSystemFile.stylesheet] != nil
        var boards: [Int: (path: String, source: String)] = [:]
        for (index, component) in tokens.components.enumerated() {
            guard let file = component.specimen, let data = files[file], data.count <= maxSpecimenBytes,
                  let text = String(data: data, encoding: .utf8) else { continue }
            boards[index] = (path(index), source(specimen: text, title: component.name, stylesheet: stylesheet, background: background))
        }
        return boards
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
