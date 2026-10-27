import ActivityKit
import AppIntents
import SwiftUI
import ShepherdUI
import WidgetKit

// The widget extension (docs/design/notifications.md › Glance): the Watch and Follow Live
// Activities with their Dynamic Island, the Home and Lock Screen widget, and two Control Center
// controls. It draws what the app published and runs nothing itself: buttons are the app's
// intents or links into it.

@main
struct ShepherdWidgets: WidgetBundle {
    init() { SHFonts.register() }

    var body: some Widget {
        WatchActivityWidget()
        FollowActivityWidget()
        GlanceWidget()
        NewThreadControl()
        NeedsYouControl()
    }
}

/// A card's buttons: answers and Stop run the app's intents; the rest open the app.
struct GlanceButtonRow: View {
    let item: SHGlance.Item
    let stale: Bool
    var island = false

    var body: some View {
        SHGlanceButtons(item.actions(stale: stale)) { action in
            switch action {
            case .answer(let option, _):
                Button(intent: AnswerQuestionIntent(item: item, option: option)) { SHGlanceButtonLabel(action, island: island) }
                    .buttonStyle(.plain)
            case .stop:
                Button(intent: StopTurnIntent(item: item)) { SHGlanceButtonLabel(action, island: island) }
                    .buttonStyle(.plain)
            case .review:
                link(GlanceLink.review(item), action)
            case .reply, .steer, .open:
                link(GlanceLink.thread(item), action)
            }
        }
    }

    @ViewBuilder private func link(_ url: URL?, _ action: SHGlanceAction) -> some View {
        if let url {
            Link(destination: url) { SHGlanceButtonLabel(action, island: island) }
        }
    }
}

// MARK: Live Activities

struct WatchActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WatchActivity.self) { context in
            SHGlanceWatchCard(context.state, stale: context.isStale, now: .now) { GlanceButtonRow(item: $0, stale: context.isStale) }
                .glanceCard()
                .widgetURL(context.state.lead.flatMap(GlanceLink.thread) ?? GlanceLink.needsYou.url)
        } dynamicIsland: { context in
            let glance = context.state
            let stale = context.isStale
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { SHGlanceIslandLeading(glance.lead, stale: stale) }
                DynamicIslandExpandedRegion(.trailing) {
                    SHGlanceIslandTrailing(glance, follow: glance.lead, expanded: true, stale: stale, now: .now)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let lead = glance.lead {
                        SHGlanceIslandBody(lead, in: glance, stale: stale, now: .now) { GlanceButtonRow(item: $0, stale: stale, island: true) }
                    }
                }
            } compactLeading: {
                SHGlanceIslandMark(glance.urgent, stale: stale)
            } compactTrailing: {
                SHGlanceIslandTrailing(glance, stale: stale, now: .now)
            } minimal: {
                SHGlanceIslandMinimal(glance.urgent, stale: stale)
            }
            .widgetURL(glance.lead.flatMap(GlanceLink.thread) ?? GlanceLink.needsYou.url)
            .keylineTint(Color.sh.lantern)
        }
    }
}

struct FollowActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FollowActivity.self) { context in
            Group {
                if let item = context.state.item(context.attributes.item) {
                    SHGlanceFollowCard(item, in: context.state, stale: context.isStale, now: .now) {
                        GlanceButtonRow(item: $0, stale: context.isStale)
                    }
                }
            }
            .glanceCard()
            .widgetURL(context.state.item(context.attributes.item).flatMap(GlanceLink.thread))
        } dynamicIsland: { context in
            let glance = context.state
            let item = glance.item(context.attributes.item)
            let stale = context.isStale
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { SHGlanceIslandLeading(item, stale: stale) }
                DynamicIslandExpandedRegion(.trailing) {
                    SHGlanceIslandTrailing(glance, follow: item, expanded: true, stale: stale, now: .now)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let item {
                        SHGlanceIslandBody(item, in: glance, stale: stale, now: .now) { GlanceButtonRow(item: $0, stale: stale, island: true) }
                    }
                }
            } compactLeading: {
                SHGlanceIslandMark(item?.state, stale: stale)
            } compactTrailing: {
                SHGlanceIslandTrailing(glance, follow: item, stale: stale, now: .now)
            } minimal: {
                SHGlanceIslandMinimal(item?.state, stale: stale)
            }
            .widgetURL(item.flatMap(GlanceLink.thread))
            .keylineTint(Color.sh.lantern)
        }
    }
}

extension View {
    /// The Lock Screen card's padding and fill (GlanceWatch: `bgRaised`, 12 × 16).
    func glanceCard() -> some View {
        padding(.vertical, SH.Space.l)
            .padding(.horizontal, SH.Space.xl)
            .activityBackgroundTint(Color.sh.bgRaised)
            .activitySystemActionForegroundColor(Color.sh.textPrimary)
    }
}

// MARK: Control Center

struct NewThreadControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.bailycase.shepherd.ios.new-thread") {
            ControlWidgetButton(action: OpenShepherdIntent(.newThread)) {
                Label("New thread", systemImage: "plus")
            }
        }
        .displayName("New thread")
        .description("Start a thread on one of your hosts.")
    }
}

struct NeedsYouControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.bailycase.shepherd.ios.needs-you", provider: NeedsYouCount()) { count in
            ControlWidgetButton(action: OpenShepherdIntent(.needsYou)) {
                Label {
                    Text("Needs you")
                    Text(count == 0 ? "Nothing waiting" : "\(count) waiting")
                } icon: {
                    Image(systemName: count == 0 ? SHGlyph.resolved.symbolName : "exclamationmark.circle")
                }
            }
            .tint(Color.sh.lantern)
        }
        .displayName("Needs you")
        .description("What waits on you, across hosts.")
    }
}

/// How many threads wait on you, as the app last published.
struct NeedsYouCount: ControlValueProvider {
    var previewValue: Int { 0 }

    func currentValue() async throws -> Int { GlanceStore.read()?.needsYou.count ?? 0 }
}
