import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdRemote

/// Every host's missions (MobileMissions; iPadMissions beside the chosen one): each with its pill,
/// host, repositories and route. `+` plans a new one on a host that offers missions.
struct MissionsScreen: View {
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let rows = MissionsScreen.rows(hosts)
        let serving = hosts.hosts.contains { $0.servesMissions }
        Group {
            if rows.isEmpty {
                SHEmptyState(Text(serving ? "No missions yet" : "No missions"),
                             message: serving ? "Describe an end state across a host's repositories. Its planner drafts a map you approve, validation checks the work, and you publish the pull requests."
                                 : "Turn on Settings ▸ Experiments ▸ Missions on a Mac to plan and run its missions from here.") {
                    if serving {
                        Button("New mission", systemImage: "plus") { MissionsHooks.create(navigator: navigator) }.buttonStyle(.sh(.primary))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if sizeClass == .regular {
                MissionsSplit(rows: rows)
            } else {
                ScrollView {
                    MissionsList(rows: rows, chosen: nil) { MissionsHooks.open(host: $0.host, mission: $0.mission, navigator: navigator) }
                        .padding(.horizontal, MobileLayout.gutter)
                        .padding(.bottom, MobileLayout.sectionSpacing)
                }
                .refreshable { await MissionsScreen.refresh(hosts) }
            }
        }
        .background(Color.sh.bgWindow)
        .navigationTitle("Missions")
        .navigationBarTitleDisplayMode(sizeClass == .regular ? .inline : .large)
        .toolbar {
            if serving {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New mission", systemImage: "plus") { MissionsHooks.create(navigator: navigator) }
                        .buttonStyle(.glassProminent)
                        .tint(Color.sh.lantern)
                }
            }
        }
    }

    /// Every host's missions, newest first, those waiting on you first.
    static func rows(_ hosts: MobileHosts) -> [MissionRowModel] {
        let rows = hosts.hosts.flatMap { host in host.missions.records.reversed().map { MissionRowModel($0, host: host) } }
        return rows.enumerated().sorted { a, b in
            let rank = { (row: MissionRowModel) in row.state == .attention ? 0 : row.state == .running ? 1 : 2 }
            return (rank(a.element), a.offset) < (rank(b.element), b.offset)
        }.map(\.element)
    }

    static func refresh(_ hosts: MobileHosts) async {
        for host in hosts.hosts where host.servesMissions { await host.missions.refresh() }
    }
}

/// The list's rows in one card.
struct MissionsList: View {
    let rows: [MissionRowModel]
    let chosen: MissionKey?
    let open: (MissionKey) -> Void

    var body: some View {
        SHListCard {
            ForEach(rows) { row in
                Button { open(row.key) } label: { MissionRow(row: row, selected: row.key == chosen).equatable() }
                    .buttonStyle(.shRow(radius: 0))
            }
        }
    }
}

/// A mission's row: name and pill, then its question or host and repositories, then its route.
struct MissionRow: View, Equatable {
    let row: MissionRowModel
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
                SHGlyph.mission.image.font(.sh(.caption)).foregroundStyle(row.state == .attention ? Color.sh.lanternText : Color.sh.textSecondary)
                Text(row.title).font(.sh(.ui, weight: .semibold)).foregroundStyle(Color.sh.textPrimary).lineLimit(2)
                Spacer(minLength: SH.Space.s)
                SHStatusPill(row.state, label: row.label).fixedSize()
            }
            Text(row.detail).shText(.caption).lineLimit(2)
                .foregroundStyle(row.state == .attention ? Color.sh.lanternText : Color.sh.textTertiary)
            if !row.route.isEmpty { SHStepStrip(row.route) }
        }
        .padding(SH.Space.l)
        .frame(maxWidth: .infinity, minHeight: MobileLayout.twoLineRowHeight, alignment: .leading)
        .background(selected ? Color.sh.bgSelected : Color.clear)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// iPad: the list beside the chosen mission (iPadMissions).
private struct MissionsSplit: View {
    let rows: [MissionRowModel]
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        let choice = MissionsChoice.shared
        let current = rows.first { $0.key == choice.chosen }?.key ?? rows[0].key
        PadListDetail(listWidth: MobileLayout.missionsListWidth) {
            ScrollView {
                MissionsList(rows: rows, chosen: current) { choice.chosen = $0 }.padding(SH.Space.m)
            }
        } detail: {
            MissionScreen(host: current.host, id: current.mission, embedded: true).id(current)
        } single: {
            ScrollView {
                MissionsList(rows: rows, chosen: nil) { navigator.open(.missions(.mission(host: $0.host, mission: $0.mission))) }
                    .padding(.horizontal, MobileLayout.gutter)
            }
        }
    }
}

/// Home's Missions (iPhone): the first few, those waiting on you first, and All missions. Shown
/// while a host offers missions.
struct HomeMissionsSection: View {
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        if hosts.hosts.contains(where: { $0.servesMissions }) {
            let rows = MissionsScreen.rows(hosts)
            VStack(alignment: .leading, spacing: MobileLayout.headerSpacing) {
                SHListHeader("Missions", attention: rows.contains { $0.state == .attention }, count: rows.count)
                SHListCard {
                    ForEach(rows.prefix(MobileLayout.homeMissions)) { row in
                        Button { MissionsHooks.open(host: row.key.host, mission: row.key.mission, navigator: navigator) } label: {
                            MissionRow(row: row, selected: false).equatable()
                        }
                        .buttonStyle(.shRow(radius: 0))
                    }
                    Button { navigator.open(.missions(.list)) } label: {
                        Text(rows.isEmpty ? "New mission" : "All missions")
                            .font(.sh(.caption, weight: .medium))
                            .foregroundStyle(Color.sh.textSecondary)
                            .frame(maxWidth: .infinity, minHeight: SH.Height.touch)
                    }
                    .buttonStyle(.shRow(radius: 0))
                }
            }
        }
    }
}
