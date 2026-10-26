import SwiftUI
import ShepherdUI
import ShepherdRemote

/// Needs you (MobileInbox, iPadInbox boards; home track): every question and blocked thread on
/// the connected hosts. iPhone lists the cards with their answers; iPad lists them beside the
/// chosen one, answered in its detail.
struct NeedsYouScreen: View {
    @Environment(MobileHosts.self) private var hosts
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let feed = HomeFeed.of(hosts)
        let items = feed.model.needsYou
        Group {
            if items.isEmpty {
                SHEmptyState(Text("Nothing needs you"), message: "Questions and blocked threads from every host show here.") {
                    EmptyView()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if sizeClass == .regular {
                NeedsYouSplit(items: items, answering: feed.answering, failures: feed.failures)
            } else {
                NeedsYouCards(items: items, answering: feed.answering, failures: feed.failures)
            }
        }
        .background(Color.sh.bgWindow)
        .task { await feed.watch() }
        .navigationTitle("Needs you")
        .navigationBarTitleDisplayMode(sizeClass == .regular ? .inline : .large)
        .toolbar {
            // iPadInbox: "Needs you" with "5 waiting" beside it, leading the bar.
            if sizeClass == .regular {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
                        Text("Needs you").font(.sh(.headline)).foregroundStyle(Color.sh.textPrimary)
                        if !items.isEmpty {
                            Text("\(items.count) waiting").font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                        }
                    }
                    .fixedSize()
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
        .toolbar(removing: sizeClass == .regular ? .title : nil)
    }

    /// "4 things are waiting on you".
    static func waiting(_ count: Int) -> String {
        count == 1 ? "1 thing is waiting on you" : "\(count) things are waiting on you"
    }
}

/// iPhone: the cards with their answers.
private struct NeedsYouCards: View {
    let items: [FleetAttention]
    let answering: Set<String>
    let failures: [String: String]
    @Environment(MobileHosts.self) private var hosts

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MobileLayout.blockSpacing) {
                Text(NeedsYouScreen.waiting(items.count))
                    .font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                    .padding(.horizontal, SH.Space.xs)
                ForEach(items) { item in
                    AttentionCard(item: item, busy: answering.contains(item.id), failure: failures[item.id])
                }
            }
            .padding(.horizontal, MobileLayout.gutter)
            .padding(.bottom, MobileLayout.sectionSpacing)
            .frame(maxWidth: MobileLayout.homeMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await HomeFeed.of(hosts).refresh() }
    }
}

/// iPad: the list beside the chosen item's detail.
private struct NeedsYouSplit: View {
    let items: [FleetAttention]
    let answering: Set<String>
    let failures: [String: String]
    @State private var chosen: String?

    var body: some View {
        let current = items.first { $0.id == chosen } ?? items[0]
        PadListDetail(listWidth: MobileLayout.inboxListWidth) {
            ScrollView {
                // Flat items, 2pt apart, the chosen one filled (iPadInbox).
                LazyVStack(alignment: .leading, spacing: SH.Space.xxs) {
                    ForEach(items) { item in
                        Button { chosen = item.id } label: {
                            AttentionCard(item: item, busy: answering.contains(item.id), failure: nil,
                                          selected: item.id == current.id, answers: false)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(item.id == current.id ? .isSelected : [])
                    }
                }
                .padding(SH.Space.m)
            }
        } detail: {
            NeedsYouDetail(item: current, busy: answering.contains(current.id), failure: failures[current.id])
                .id(current.id)
        } single: {
            // Too narrow for both (iPhone Duo): the phone's cards, answered in place.
            NeedsYouCards(items: items, answering: answering, failures: failures)
        }
    }
}

/// One item on iPad: the question at reading size, where it came from, and its answers.
private struct NeedsYouDetail: View {
    let item: FleetAttention
    let busy: Bool
    let failure: String?
    @Environment(MobileNavigator.self) private var navigator
    @Environment(MobileProjects.self) private var projects

    var body: some View {
        let sh = Color.sh
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: MobileLayout.blockSpacing) {
                    HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
                        Text(item.title).font(.sh(.headline)).foregroundStyle(sh.textPrimary)
                        // "Needs you · 2m": how long it has waited.
                        if let since = item.since.map(Date.init(milliseconds:)) {
                            TimelineView(SHElapsedSchedule(start: since)) { context in
                                SHStatusPill(.attention, label: "\(AgentState.attention.label) · \(SHDuration.text(context.date.timeIntervalSince(since)))")
                            }
                        } else {
                            SHStatusPill(.attention)
                        }
                    }
                    Text(item.question).shText(.body).foregroundStyle(sh.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if let message = item.message {
                        Text(message).shText(.code).foregroundStyle(sh.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .padding(SH.Space.l)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .shCard(radius: SHListMetrics.cardRadius, fill: sh.bgSunken)
                    }
                    if item.reply == .open {
                        Text(item.dialogID == nil
                             ? "Open the thread to see what it is waiting for."
                             : "Answer this one in the thread.")
                            .shText(.caption).foregroundStyle(sh.textTertiary)
                    }
                    VStack(alignment: .leading, spacing: MobileLayout.headerSpacing) {
                        SHSectionHeader("Where it came from")
                        SHListCard {
                            SHListRow(item.thread, subtitle: item.kind, subtitleMono: false,
                                      clock: item.since.map { .ago(Date(milliseconds: $0)) }, leading: item.leading,
                                      trailing: .host(item.hostName), chevron: false)
                        }
                    }
                    .padding(.top, SH.Space.m)
                }
                .padding(MobileLayout.gutter)
                .frame(maxWidth: MobileLayout.threadMaxWidth, alignment: .leading)
            }
            SHHairline()
            HStack(spacing: SH.Space.m) {
                Button("Open thread") { navigator.open(projects.route(item)) }
                    .buttonStyle(.sh(item.reply == .open ? .primary : .ghost, size: .l))
                Spacer(minLength: SH.Space.m)
                if let failure {
                    Text(failure).font(.sh(.caption)).foregroundStyle(sh.failed).lineLimit(2)
                }
                SHWrapStack(spacing: SH.Space.m) {
                    AttentionReplies(item: item, busy: busy, size: .l, pickLast: true)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, MobileLayout.gutter)
            .padding(.vertical, SH.Space.m)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
