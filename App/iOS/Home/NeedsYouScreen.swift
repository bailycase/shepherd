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
                NWEmptyState(Text("Nothing needs you"), message: "Questions and blocked threads from every host show here.") {
                    EmptyView()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if sizeClass == .regular {
                NeedsYouSplit(items: items, answering: feed.answering, failures: feed.failures)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: MobileLayout.blockSpacing) {
                        Text(Self.waiting(items.count))
                            .font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
                            .padding(.horizontal, NW.Space.xs)
                        ForEach(items) { item in
                            AttentionCard(item: item, busy: feed.answering.contains(item.id), failure: feed.failures[item.id])
                        }
                    }
                    .padding(.horizontal, MobileLayout.gutter)
                    .padding(.bottom, MobileLayout.sectionSpacing)
                    .frame(maxWidth: MobileLayout.homeMaxWidth)
                    .frame(maxWidth: .infinity)
                }
                .refreshable { await feed.refresh() }
            }
        }
        .background(Color.nw.bgWindow)
        .task { await feed.watch() }
        .navigationTitle("Needs you")
        .navigationBarTitleDisplayMode(sizeClass == .regular ? .inline : .large)
    }

    /// "4 things are waiting on you".
    static func waiting(_ count: Int) -> String {
        count == 1 ? "1 thing is waiting on you" : "\(count) things are waiting on you"
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
        HStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: MobileLayout.blockSpacing) {
                    Text(NeedsYouScreen.waiting(items.count))
                        .font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
                        .padding(.horizontal, NW.Space.xs)
                    ForEach(items) { item in
                        Button { chosen = item.id } label: {
                            AttentionCard(item: item, busy: answering.contains(item.id), failure: nil,
                                          selected: item.id == current.id, answers: false)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(item.id == current.id ? .isSelected : [])
                    }
                }
                .padding(MobileLayout.gutter)
            }
            .frame(width: MobileLayout.inboxListWidth)
            NWHairline(.vertical)
            NeedsYouDetail(item: current, busy: answering.contains(current.id), failure: failures[current.id])
                .id(current.id)
        }
    }
}

/// One item on iPad: the question at reading size, where it came from, and its answers.
private struct NeedsYouDetail: View {
    let item: FleetAttention
    let busy: Bool
    let failure: String?
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        let nw = Color.nw
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: MobileLayout.blockSpacing) {
                    HStack(alignment: .firstTextBaseline, spacing: NW.Space.m) {
                        Text(item.title).font(.nw(.headline)).foregroundStyle(nw.textPrimary)
                        NWStatusPill(.attention)
                    }
                    Text(item.question).nwText(.body).foregroundStyle(nw.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if let message = item.message {
                        Text(message).nwText(.code).foregroundStyle(nw.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .padding(NW.Space.l)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .nwCard(radius: NWListMetrics.cardRadius, fill: nw.bgSunken)
                    }
                    if item.reply == .open {
                        Text(item.dialogID == nil && item.runID == nil
                             ? "Open the thread to see what it is waiting for."
                             : "Answer this one in the thread.")
                            .nwText(.caption).foregroundStyle(nw.textTertiary)
                    }
                    VStack(alignment: .leading, spacing: MobileLayout.headerSpacing) {
                        NWSectionHeader("Where it came from")
                        NWListCard {
                            NWListRow(item.thread, subtitle: item.kind, subtitleMono: false, leading: item.leading,
                                      trailing: .host(item.hostName), chevron: false)
                        }
                    }
                    .padding(.top, NW.Space.m)
                }
                .padding(MobileLayout.gutter)
                .frame(maxWidth: MobileLayout.threadMaxWidth, alignment: .leading)
            }
            NWHairline()
            HStack(spacing: NW.Space.m) {
                Button(item.runID == nil ? "Open thread" : "Open subagent") { navigator.open(item.route) }
                    .buttonStyle(.nw(item.reply == .open ? .primary : .ghost, size: .l))
                Spacer(minLength: NW.Space.m)
                if let failure {
                    Text(failure).font(.nw(.caption)).foregroundStyle(nw.failed).lineLimit(2)
                }
                NWWrapStack(spacing: NW.Space.m) {
                    AttentionReplies(item: item, busy: busy, size: .l)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, MobileLayout.gutter)
            .padding(.vertical, NW.Space.m)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
