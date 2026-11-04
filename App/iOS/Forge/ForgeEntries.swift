import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// Where Issues & PRs is reached from: Home's row on iPhone, and the iPad sidebar's row with its
/// Pinned section (iPadIPReview). Shown while a paired host offers Issues & PRs.
@MainActor
enum ForgeEntry {
    static func available(_ hosts: MobileHosts) -> Bool {
        hosts.hosts.contains { $0.supports(RemoteProtocol.forgeCapability) }
    }

    /// The row's count: what needs you, in lantern.
    static func trailing(_ store: ForgeStore) -> SHListRow.Trailing {
        store.needsYou > 0 ? .reason("\(store.needsYou)") : .none
    }
}

/// Home's Issues & PRs row (iPhone): a sixth tab would put Settings under iOS's More, so the
/// destination is a row here, its count the pull requests and issues waiting on you.
struct HomeForgeSection: View {
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        if ForgeEntry.available(hosts) {
            let store = ForgeStore.of(hosts)
            SHListCard {
                Button { navigator.open(.forge(.list)) } label: {
                    SHListRow("Issues & PRs", leading: .symbol(ForgeGlyph.pullRequest), trailing: ForgeEntry.trailing(store))
                }
                .buttonStyle(.shRow(radius: 0))
                .accessibilityValue(store.needsYou > 0 ? "\(store.needsYou) need you" : "")
            }
            .task(id: store.sessionsKey) { await store.loadSidebars() }
        }
    }
}

/// The iPad sidebar's pinned pull requests and issues (iPadIPReview): each with its word
/// ("changes", "review", "#34"); a tap opens it beside the list.
struct ForgePinnedSection: View {
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        let store = ForgeStore.of(hosts)
        let pins = store.pins
        if !pins.isEmpty {
            SHListHeader("Pinned", count: pins.count, style: .sidebar)
                .padding(.horizontal, SH.Space.m)
                .padding(.bottom, SH.Space.xs)
                .frame(minHeight: SH.Height.touch, alignment: .bottom)
            ForEach(pins) { pin in
                let selected = navigator.padPath.last == .forge(.list) && store.chosen == pin.key
                Button { ForgeHooks.open(pin.key, store: store, navigator: navigator) } label: {
                    SHListRow(pin.title, leading: .symbol(pin.key.ref.kind == .pullRequest ? ForgeGlyph.pullRequest : ForgeGlyph.issue, pin.tone?.state),
                              trailing: Self.trailing(pin), chevron: false, selected: selected, compact: true)
                        .clipShape(RoundedRectangle(cornerRadius: SH.Radius.m))
                }
                .buttonStyle(.shRow(radius: SH.Radius.m))
                .contextMenu {
                    Button("Unpin", systemImage: SHGlyph.pin.symbolName) {
                        Task { await store.setPinned(pin.key, title: pin.title, pinned: false) }
                    }
                }
            }
        }
    }

    static func trailing(_ pin: ForgePinRow) -> SHListRow.Trailing {
        switch pin.tagTone {
        case .failed?: .alert(pin.tag)
        case .attention?: .reason(pin.tag)
        default: .meta(pin.tag)
        }
    }
}
