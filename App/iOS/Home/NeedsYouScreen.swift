import SwiftUI
import ShepherdUI
import ShepherdRemote

/// Needs you (MobileInbox, iPadInbox boards; home track): every question and blocked thread on
/// the connected hosts. iPhone lists the cards with their answers; iPad lists them beside the
/// chosen one, answered in its detail.
struct NeedsYouScreen: View {
    @Environment(MobileHosts.self) private var hosts
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// The list and detail don't fit side by side (iPhone Duo): the cards carry the board's big title instead of the bar.
    @State private var single = false

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
                NeedsYouSplit(items: items, answering: feed.answering, failures: feed.failures, single: $single)
            } else {
                NeedsYouCards(items: items, answering: feed.answering, failures: feed.failures)
            }
        }
        .background(Color.sh.bgWindow)
        .task { await feed.watch() }
        .navigationTitle("Needs you")
        .navigationBarTitleDisplayMode(sizeClass == .regular ? .inline : .large)
        .toolbar {
            // On a wide iPad the trailing corner shares the status bar's space.
            if sizeClass == .regular {
                ToolbarItem(placement: .topBarLeading) {
                    // The board's head: "Needs you" over "2 waiting".
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Needs you").font(.shSans(MobileLayout.barTitleSize, .semibold)).foregroundStyle(Color.sh.textPrimary)
                        if !items.isEmpty {
                            Text("\(items.count) waiting").font(.shSans(MobileLayout.barSubtitleSize)).foregroundStyle(Color.sh.textSecondary)
                        }
                    }
                    .fixedSize()
                    .opacity(single ? 0 : 1)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityHidden(single)
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .topBarLeading) { NextNeedingYouButton(showsScope: true) }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .topBarTrailing) { NextNeedingYouButton(showsScope: true) }
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
    /// The board's big title above the lead, where the bar doesn't carry it.
    var showsTitle = false
    @Environment(MobileHosts.self) private var hosts

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MobileLayout.blockSpacing) {
                if showsTitle {
                    Text("Needs you").font(.sh(.display)).foregroundStyle(Color.sh.textPrimary)
                        .padding(.horizontal, SH.Space.xs)
                        .accessibilityAddTraits(.isHeader)
                }
                Text("Questions and blocked threads from every host show here.")
                    .shText(.caption).foregroundStyle(Color.sh.textSecondary)
                    .padding(.horizontal, SH.Space.xs)
                    .accessibilityLabel(NeedsYouScreen.waiting(items.count))
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
    @Binding var single: Bool
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
            NeedsYouCards(items: items, answering: answering, failures: failures, showsTitle: true)
                .onAppear { single = true }
                .onDisappear { single = false }
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
                    // "Dock review pane" over "Needs you · 13m": how long it has waited.
                    VStack(alignment: .leading, spacing: SH.Space.xxs) {
                        Text(item.title).font(.shSans(MobileLayout.detailTitleSize, .semibold)).foregroundStyle(sh.textPrimary)
                        if let since = item.since.map(Date.init(milliseconds:)) {
                            TimelineView(SHElapsedSchedule(start: since)) { context in
                                Text("\(AgentState.attention.label) · \(SHDuration.text(context.date.timeIntervalSince(since)))")
                                    .font(.sh(.caption)).foregroundStyle(AgentState.attention.textColor)
                            }
                        } else {
                            Text(AgentState.attention.label).font(.sh(.caption)).foregroundStyle(AgentState.attention.textColor)
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
                        Text("Where it came from").font(.sh(.caption)).foregroundStyle(sh.textSecondary)
                            .padding(.horizontal, SH.Space.xs)
                            .accessibilityAddTraits(.isHeader)
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
