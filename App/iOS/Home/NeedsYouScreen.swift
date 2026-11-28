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
                NeedsYouCards(items: items, answering: feed.answering, failures: feed.failures, showsTitle: true)
            }
        }
        .background(Color.sh.bgWindow)
        .task { await feed.watch() }
        .navigationTitle("Needs you")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
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
                    SettingsHeading("Needs you")
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
    @State private var chosen: String?

    var body: some View {
        let current = items.first { $0.id == chosen } ?? items[0]
        PadListDetail(listWidth: MobileLayout.inboxListWidth) {
            VStack(spacing: 0) {
                // "Needs you" over "2 waiting", each column under its own bar (iPadInbox).
                PadColumnBar("Needs you", subtitle: "\(items.count) waiting", inset: SH.Space.xl)
                ScrollView {
                    // Flat items, 2pt apart, the chosen one filled.
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
                    // The board's list sits flush under its bar, 16pt from each edge.
                    .padding(.horizontal, SH.Space.xl)
                    .padding(.bottom, SH.Space.m)
                }
            }
        } detail: {
            NeedsYouDetail(item: current, busy: answering.contains(current.id), failure: failures[current.id])
                .id(current.id)
        } single: {
            // Too narrow for both (iPhone Duo): the phone's cards, answered in place.
            NeedsYouCards(items: items, answering: answering, failures: failures, showsTitle: true)
        }
    }
}

/// One item on iPad (iPadInbox): its bar, the question as a card of radio answers with Open thread and Answer, and where it came from.
private struct NeedsYouDetail: View {
    let item: FleetAttention
    let busy: Bool
    let failure: String?
    @Environment(MobileNavigator.self) private var navigator
    @Environment(MobileProjects.self) private var projects
    @Environment(MobileHosts.self) private var hosts
    /// The asker's pick (the first) is chosen until another is; nothing is answered until Answer.
    @State private var picked = 1

    var body: some View {
        let sh = Color.sh
        VStack(spacing: 0) {
            bar
            ScrollView {
                VStack(alignment: .leading, spacing: MobileLayout.blockSpacing) {
                    switch item.reply {
                    case .choose, .confirm:
                        card
                    case .open:
                        Text(item.question).shText(.body).foregroundStyle(sh.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        if let message = item.message { messageBox(message) }
                        Text(item.dialogID == nil
                             ? "Open the thread to see what it is waiting for."
                             : "Answer this one in the thread.")
                            .shText(.caption).foregroundStyle(sh.textTertiary)
                        Button("Open thread") { open() }
                            .buttonStyle(.sh(.primary, size: .l))
                    }
                    if let failure {
                        Text(failure).font(.sh(.caption)).foregroundStyle(sh.failed).lineLimit(2)
                    }
                    VStack(alignment: .leading, spacing: MobileLayout.headerSpacing) {
                        Text("Where it came from").font(.sh(.caption)).foregroundStyle(sh.textSecondary)
                            .padding(.horizontal, SH.Space.xs)
                            .accessibilityAddTraits(.isHeader)
                        SHListCard {
                            Button { open() } label: {
                                SHListRow(item.thread, subtitle: origin, subtitleMono: false)
                            }
                            .buttonStyle(.shRow(radius: 0))
                        }
                    }
                    .padding(.top, SH.Space.xs)
                }
                .padding(.horizontal, MobileLayout.forgePadInset)
                // The board's card sits 10pt under its bar (iPadInbox, measured).
                .padding(.top, SH.Space.m + SH.Space.xxs)
                .padding(.bottom, MobileLayout.gutter)
                .frame(maxWidth: MobileLayout.forgeDetailMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// "Dock review pane" over "Needs you · 13m": how long it has waited.
    @ViewBuilder private var bar: some View {
        if let since = item.since.map(Date.init(milliseconds:)) {
            TimelineView(SHElapsedSchedule(start: since)) { context in
                PadColumnBar(title: item.title, subtitle: "\(AgentState.attention.label) · \(SHDuration.text(context.date.timeIntervalSince(since)))",
                             subtitleColor: AgentState.attention.textColor, inset: MobileLayout.forgePadInset) { EmptyView() }
            }
        } else {
            PadColumnBar(title: item.title, subtitle: AgentState.attention.label, subtitleColor: AgentState.attention.textColor,
                         inset: MobileLayout.forgePadInset) { EmptyView() }
        }
    }

    /// "A thread · 13m ago · Studio".
    private var origin: String {
        let ago = item.since.map { SHDuration.text(Date().timeIntervalSince(Date(milliseconds: $0))) + " ago" }
        return [item.kind, ago, item.hostName].compactMap { $0 }.joined(separator: " · ")
    }

    private var options: [String] {
        switch item.reply {
        case .choose(let options): options
        case .confirm: ["Yes", "No"]
        case .open: []
        }
    }

    private var card: some View {
        let sh = Color.sh
        return SHQuestionCard(question: item.question) {
            VStack(alignment: .leading, spacing: SH.Space.xs) {
                if let message = item.message { messageBox(message).padding(.horizontal, SHTouchQuestionMetrics.headInset) }
                VStack(spacing: SH.Space.xxs) {
                    ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                        SHQuestionRadioRow(SHQuestionDockOption(number: index + 1, title: option, detail: nil, recommended: false),
                                           picked: picked == index + 1, showsNumber: false) { picked = index + 1 }
                    }
                }
            }
            .disabled(busy)
            HStack(spacing: SHTouchQuestionMetrics.footerSpacing) {
                Spacer(minLength: 0)
                Button("Open thread") { open() }
                    .font(.sh(.ui)).foregroundStyle(sh.textSecondary).buttonStyle(.plain)
                Button("Answer") { Task { await answer() } }
                    .buttonStyle(.sh(.primary, size: .m))
                    .disabled(busy)
            }
            .padding(.horizontal, SHTouchQuestionMetrics.headInset)
            .padding(.top, SHTouchQuestionMetrics.footerTop - SH.Space.l)
        }
    }

    private func messageBox(_ message: String) -> some View {
        Text(message).shText(.code).foregroundStyle(Color.sh.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .padding(SH.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .shCard(radius: SHListMetrics.cardRadius, fill: Color.sh.bgSunken)
    }

    private func open() { navigator.open(projects.route(item)) }

    private func answer() async {
        let feed = HomeFeed.of(hosts)
        switch item.reply {
        case .choose(let options): if options.indices.contains(picked - 1) { await feed.choose(item, options[picked - 1]) }
        case .confirm: await feed.answer(item, .confirm(value: picked == 1))
        case .open: break
        }
    }
}
