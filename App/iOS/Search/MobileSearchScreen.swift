import SwiftUI
import ShepherdUI

/// Search on iPhone (MobileSearch board): a field and Cancel across the top, then the threads
/// whose title matches and the conversations that mention the query, each on its own card, with
/// snippets and host tags. Opening a result pushes its thread over search, so Back returns to
/// the results. Missions and designs don't exist yet, so neither do their sections.
struct MobileSearchScreen: View {
    let initialQuery: String
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator
    @Environment(\.dismiss) private var dismiss
    @State private var store = MobileSearchStore()
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            HStack(spacing: NW.Space.l) {
                NWTouchSearchField("Search threads", text: $store.query, focus: $focused)
                Button("Cancel") { dismiss() }
                    .font(.nw(.body))
                    .foregroundStyle(Color.nw.running)
                    .frame(minHeight: NW.Height.touch)
            }
            .padding(.horizontal, MobileLayout.searchGutter)
            .padding(.vertical, NW.Space.m)
            .frame(maxWidth: MobileLayout.threadMaxWidth)
            SearchResultsList(sections: store.sections, status: store.status, idle: store.isIdle, query: store.query) { entry in
                if case .open(let ref) = entry.action { navigator.open(.thread(ref)) }
            }
        }
        .background(Color.nw.bgWindow)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .task {
            if store.query.isEmpty, !initialQuery.isEmpty { store.query = initialQuery }
            store.attach(hosts)
            focused = initialQuery.isEmpty
        }
        .onDisappear { store.detach() }
    }
}

/// The phone's results: a card per section, the search's progress and notices under them, and
/// what to try when nothing matched.
private struct SearchResultsList: View {
    let sections: [SearchEntrySection]
    let status: SearchStatusLine
    let idle: Bool
    let query: String
    let open: (SearchEntry) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MobileLayout.blockSpacing) {
                if idle {
                    NWEmptyState(Text("Search every host"),
                                 message: "Find a thread by its title, or by a line from its conversation (three letters or more).",
                                 showsMark: false)
                        .frame(maxWidth: .infinity)
                        .padding(.top, NW.Space.xxxl)
                } else if sections.isEmpty && status.searching == nil {
                    NWEmptyState(Text("No results"), message: "Nothing on your hosts matches “\(query)”.", showsMark: false)
                        .frame(maxWidth: .infinity)
                        .padding(.top, NW.Space.xxxl)
                }
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: NW.Space.s) {
                        Text(section.title)
                            .font(.nw(.caption, weight: .semibold))
                            .foregroundStyle(Color.nw.textSecondary)
                            .padding(.horizontal, NW.Space.xs)
                            .accessibilityAddTraits(.isHeader)
                        LazyVStack(spacing: 0) {
                            ForEach(section.entries) { entry in
                                SearchEntryButton(entry: entry, first: entry.id == section.entries.first?.id, open: open).equatable()
                            }
                        }
                        .nwCard(radius: MobileLayout.cardRadius)
                    }
                }
                SearchStatusView(status: status)
            }
            .padding(.horizontal, MobileLayout.searchGutter)
            .padding(.vertical, NW.Space.s)
            // A readable measure when an iPad shows it.
            .frame(maxWidth: MobileLayout.threadMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }
}

/// One row on a card: a rule above all but the first, the whole row a button.
private struct SearchEntryButton: View, Equatable {
    let entry: SearchEntry
    let first: Bool
    let open: (SearchEntry) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.entry == rhs.entry && lhs.first == rhs.first }

    var body: some View {
        VStack(spacing: 0) {
            if !first { NWHairline() }
            Button { open(entry) } label: {
                NWSearchResultRow(leading: entry.leading, title: entry.title, detail: entry.detail, tag: entry.host,
                                  chevron: true, dimmed: entry.dimmed)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(entry.spoken)
            .accessibilityHint("Opens the thread")
        }
    }
}

/// "Searching conversations · 3 of 12", then why any host was left out.
struct SearchStatusView: View {
    let status: SearchStatusLine

    var body: some View {
        VStack(alignment: .leading, spacing: NW.Space.xs) {
            if let searching = status.searching {
                HStack(spacing: NW.Space.s) {
                    ProgressView().progressViewStyle(NWSpinnerStyle())
                    Text(searching)
                }
                .accessibilityElement(children: .combine)
            }
            ForEach(status.notices, id: \.self) { notice in
                Text(notice).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.nw(.caption))
        .foregroundStyle(Color.nw.textTertiary)
        .padding(.horizontal, NW.Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
