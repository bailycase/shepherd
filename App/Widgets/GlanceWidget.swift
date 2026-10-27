import AppIntents
import SwiftUI
import ShepherdUI
import WidgetKit

// The Home Screen and Lock Screen widget (GlanceHome, GlanceiPad, GlanceLock, GlanceControls):
// one widget in every size, scoped to all work, a host, or one thread.

/// What a widget shows (GlanceControls' edit sheet).
enum GlanceShow: String, AppEnum {
    case all, host, thread

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Show"
    static let caseDisplayRepresentations: [GlanceShow: DisplayRepresentation] = [
        .all: "All work",
        .host: "A host",
        .thread: "One thread",
    ]
}

struct GlanceConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Shepherd"
    static let description = IntentDescription("Needs you and running work, grouped like the sidebar.")

    @Parameter(title: "Show", default: .all) var show: GlanceShow
    @Parameter(title: "Host") var host: GlanceHostEntity?
    @Parameter(title: "Thread") var thread: GlanceThreadEntity?

    static var parameterSummary: some ParameterSummary {
        Switch(\.$show) {
            Case(.host) { Summary { \.$show; \.$host } }
            Case(.thread) { Summary { \.$show; \.$thread } }
            DefaultCase { Summary { \.$show } }
        }
    }
}

/// A host the app last published, by name.
struct GlanceHostEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Host"
    static let defaultQuery = HostQuery()

    var id: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(id)") }

    struct HostQuery: EntityQuery {
        func entities(for identifiers: [String]) async throws -> [GlanceHostEntity] {
            identifiers.map(GlanceHostEntity.init)
        }

        func suggestedEntities() async throws -> [GlanceHostEntity] {
            (GlanceStore.read()?.hosts ?? []).map { GlanceHostEntity(id: $0.name) }
        }
    }
}

/// A thread the app last published.
struct GlanceThreadEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Thread"
    static let defaultQuery = ThreadQuery()

    /// `SHGlance.Item.id`.
    var id: String
    var title: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }

    struct ThreadQuery: EntityQuery {
        func entities(for identifiers: [String]) async throws -> [GlanceThreadEntity] {
            let items = GlanceStore.read()?.items ?? []
            return identifiers.map { id in GlanceThreadEntity(id: id, title: items.first { $0.id == id }?.title ?? "Thread") }
        }

        func suggestedEntities() async throws -> [GlanceThreadEntity] {
            (GlanceStore.read()?.items ?? []).map { GlanceThreadEntity(id: $0.id, title: $0.title) }
        }
    }
}

struct GlanceEntry: TimelineEntry {
    let date: Date
    let glance: SHGlance
    let configuration: GlanceConfiguration

    /// The glance this widget's scope keeps.
    var scoped: SHGlance {
        switch configuration.show {
        case .all: return glance
        case .host:
            guard let name = configuration.host?.id else { return glance }
            var copy = glance
            copy.items = glance.items.filter { $0.hostName == name }
            copy.hosts = glance.hosts.filter { $0.name == name }
            return copy
        case .thread: return glance
        }
    }

    var pinned: SHGlance.Item? {
        configuration.show == .thread ? configuration.thread.flatMap { glance.item($0.id) } : nil
    }

    var stale: Bool { glance.isStale(at: date) }

    var scopeName: String {
        switch configuration.show {
        case .all: "All work"
        case .host: configuration.host?.id ?? "All work"
        case .thread: configuration.thread?.title ?? "All work"
        }
    }
}

struct GlanceProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> GlanceEntry {
        GlanceEntry(date: .now, glance: SHGlance(items: [], hosts: [], updated: .now), configuration: GlanceConfiguration())
    }

    func snapshot(for configuration: GlanceConfiguration, in context: Context) async -> GlanceEntry {
        GlanceEntry(date: .now, glance: GlanceStore.read() ?? placeholder(in: context).glance, configuration: configuration)
    }

    /// Now, and the moment it goes stale: the app reloads the timeline whenever it publishes.
    func timeline(for configuration: GlanceConfiguration, in context: Context) async -> Timeline<GlanceEntry> {
        let glance = GlanceStore.read() ?? placeholder(in: context).glance
        let stale = glance.updated.addingTimeInterval(SHGlance.staleAfter + 1)
        let dates = stale > .now ? [Date.now, stale] : [Date.now]
        return Timeline(entries: dates.map { GlanceEntry(date: $0, glance: glance, configuration: configuration) }, policy: .never)
    }
}

struct GlanceWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "com.bailycase.shepherd.ios.glance", intent: GlanceConfiguration.self,
                               provider: GlanceProvider()) { entry in
            GlanceWidgetView(entry: entry)
                .containerBackground(Color.sh.bgRaised, for: .widget)
        }
        .configurationDisplayName("Shepherd")
        .description("Needs you and running work, grouped like the sidebar.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge,
                            .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct GlanceWidgetView: View {
    let entry: GlanceEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let glance = entry.scoped
        switch family {
        case .systemSmall:
            let item = entry.pinned ?? glance.lead
            SHGlanceSmall(item, in: glance, stale: entry.stale, now: entry.date)
                .widgetURL(item.flatMap(GlanceLink.thread) ?? GlanceLink.newThread.url)
        case .systemMedium:
            SHGlanceList(glance, rows: SHGlanceMetrics.mediumRows, stale: entry.stale, now: entry.date, link: GlanceLink.thread)
                .widgetURL(GlanceLink.needsYou.url)
        case .systemLarge:
            SHGlanceList(glance, rows: SHGlanceMetrics.largeRows, done: true, header: entry.scopeName, stale: entry.stale,
                         now: entry.date, link: GlanceLink.thread)
                .widgetURL(GlanceLink.needsYou.url)
        case .systemExtraLarge:
            SHGlanceColumns(glance, stale: entry.stale, now: entry.date, link: GlanceLink.thread)
                .widgetURL(GlanceLink.needsYou.url)
        case .accessoryCircular:
            SHGlanceCircular(glance).widgetURL(GlanceLink.needsYou.url)
        case .accessoryRectangular:
            SHGlanceRectangular(glance, stale: entry.stale, now: entry.date)
                .widgetURL(glance.lead.flatMap(GlanceLink.thread) ?? GlanceLink.needsYou.url)
        case .accessoryInline:
            Text(glance.inline)
        default:
            EmptyView()
        }
    }
}
