import SwiftUI
import ShepherdUI

/// Settings (MobileSettings, iPadSettingsInstructions boards; home track): the Settings tab's root
/// on iPhone, a list of rows each pushing its page; on iPad, pushed over the detail, the list
/// beside the page it opens. Defaults, Worktrees and Extensions are a host's own settings,
/// Instructions, Skills and Experiments span every host, and Appearance is this device's.
struct SettingsScreen: View {
    @Environment(MobileHosts.self) private var hosts
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let store = SettingsStore.of(hosts)
        Group {
            if sizeClass == .regular {
                SettingsSplit(store: store)
            } else {
                SettingsList(store: store)
            }
        }
        .task { await store.watch() }
    }
}

/// The phone's list: Appearance, then Agents, Machines, Experiments and About.
private struct SettingsList: View {
    let store: SettingsStore
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileAppearance.self) private var appearance
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        let model = HomeFeed.of(hosts).model
        ScrollView {
            VStack(alignment: .leading, spacing: MobileLayout.sectionSpacing) {
                NWListCard {
                    row(.appearance, trailing: .value(appearance.mode.title))
                }
                SettingsSection("Agents") {
                    NWListCard {
                        row(.defaults, trailing: value(store.defaultsValue))
                        row(.instructions, trailing: value(store.instructionsValue))
                        row(.skills, trailing: value(store.skillsValue))
                        row(.pi, trailing: value(store.extensionsValue))
                    }
                }
                SettingsSection("Machines") {
                    NWListCard {
                        row(.hosts, trailing: model.offlineCount > 0 ? .alert("\(model.offlineCount) offline")
                            : .value(model.hosts.isEmpty ? "None" : String(model.hosts.count)))
                        row(.worktrees, trailing: NWListRow.Trailing.none)
                    }
                }
                NWListCard {
                    row(.experiments, trailing: value(store.experimentsValue))
                }
                SettingsSection("About") {
                    NWListCard { AboutRow(agent: store.agentVersion) }
                }
            }
            .padding(.horizontal, MobileLayout.gutter)
            .padding(.bottom, MobileLayout.sectionSpacing)
            .frame(maxWidth: MobileLayout.homeMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await store.refresh() }
        .background(Color.nw.bgWindow)
        .navigationTitle("Settings")
    }

    private func row(_ page: SettingsPage, trailing: NWListRow.Trailing) -> some View {
        Button { navigator.open(.settings(page.route)) } label: {
            NWListRow(page.title, leading: .symbol(page.symbol), trailing: trailing)
        }
        .buttonStyle(.nwRow(radius: 0))
    }

    private func value(_ text: String?) -> NWListRow.Trailing {
        text.map(NWListRow.Trailing.value) ?? NWListRow.Trailing.none
    }
}

/// The iPad's Settings (iPadSettingsInstructions): a 300pt list of its pages, the open one on
/// `bgSelected`, beside that page. The page names the bar and puts its actions there.
private struct SettingsSplit: View {
    let store: SettingsStore

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: MobileLayout.settingsListRowSpacing) {
                    ForEach(SettingsPage.allCases, id: \.self) { page in
                        SettingsListItem(page: page, selected: store.page == page) { store.page = page }
                    }
                }
                .padding(MobileLayout.settingsListInset)
                AboutLine(agent: store.listFootVersion)
                    .padding(.horizontal, MobileLayout.settingsListInset + NW.Space.l)
                    .padding(.vertical, NW.Space.l)
            }
            .refreshable { await store.refresh() }
            .frame(width: MobileLayout.settingsListWidth)
            .background(Color.nw.bgWindow)
            NWHairline(.vertical)
            SettingsPageView(page: store.page)
                .environment(\.settingsColumn, true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(store.page)
        }
        .background(Color.nw.bgWindow)
    }
}

/// One page in the iPad's list: its glyph and name; the open one on `bgSelected`, its glyph in
/// `textPrimary` and its name semibold.
private struct SettingsListItem: View {
    let page: SettingsPage
    let selected: Bool
    let open: () -> Void

    var body: some View {
        let nw = Color.nw
        Button(action: open) {
            HStack(spacing: NW.Space.l) {
                Image(systemName: page.symbol)
                    .font(.nw(.ui, weight: .medium))
                    .foregroundStyle(selected ? nw.textPrimary : nw.textSecondary)
                    .frame(width: NWListMetrics.leadingWidth)
                    .accessibilityHidden(true)
                Text(page.listTitle)
                    .font(.nw(.ui, weight: selected ? .semibold : .medium))
                    .foregroundStyle(nw.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, NW.Space.l)
            .frame(minHeight: MobileLayout.rowHeight)
            .background(selected ? nw.bgSelected : .clear, in: RoundedRectangle(cornerRadius: MobileLayout.settingsListRowRadius))
            .contentShape(RoundedRectangle(cornerRadius: MobileLayout.settingsListRowRadius))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A Settings page by itself, as the iPad shows it beside the list.
struct SettingsPageView: View {
    let page: SettingsPage

    var body: some View {
        switch page {
        case .appearance: AppearanceScreen()
        case .defaults: DefaultsScreen()
        case .worktrees: WorktreesScreen()
        case .pi: PiExtensionsScreen()
        case .instructions: InstructionsScreen()
        case .skills: SkillsScreen()
        case .hosts: HostsScreen()
        case .experiments: ExperimentsScreen()
        }
    }
}

extension SettingsStore {
    /// Opens another page: in place beside the iPad's list, else on its own.
    func open(_ page: SettingsPage, inColumn: Bool, navigator: MobileNavigator) {
        if inColumn { self.page = page } else { navigator.open(.settings(page.route)) }
    }
}

/// A titled group of Settings cards.
struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MobileLayout.headerSpacing) {
            NWListHeader(title)
            content()
        }
    }
}

/// Shepherd's version beside the agent the host runs ("agent 0.87.1"), or this build while no
/// host has said: the crook on its dark tile.
private struct AboutRow: View {
    let agent: String?

    var body: some View {
        HStack(spacing: NW.Space.l) {
            ShepherdTile()
                .frame(width: NWListMetrics.leadingWidth)
            Text("Shepherd \(AboutLine.version)").font(.nw(.ui, weight: .medium)).foregroundStyle(Color.nw.textPrimary)
            Spacer(minLength: NW.Space.m)
            Text(agent ?? "build \(AboutLine.build)").font(.nw(.mono)).foregroundStyle(Color.nw.textTertiary)
        }
        .padding(.horizontal, NW.Space.l)
        .frame(minHeight: NWListMetrics.rowHeight)
        .accessibilityElement(children: .combine)
    }
}

/// The iPad list's foot: "Shepherd 0.1.0 · agent 0.87.1" ("pi 0.87.1" beside the Pi page).
private struct AboutLine: View {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""

    let agent: String?

    var body: some View {
        Text(["Shepherd \(Self.version)", agent ?? "build \(Self.build)"].joined(separator: " · "))
            .nwText(.caption)
            .foregroundStyle(Color.nw.textTertiary)
    }
}

/// Shepherd's icon at list size: the crook in `lantern` on its dark tile.
private struct ShepherdTile: View {
    var body: some View {
        NWCrook()
            .frame(width: MobileLayout.settingsAboutCrook, height: MobileLayout.settingsAboutCrook)
            .frame(width: MobileLayout.settingsAboutTile, height: MobileLayout.settingsAboutTile)
            .background(Color.nw.textOnLantern, in: RoundedRectangle(cornerRadius: NW.Radius.s))
            .accessibilityHidden(true)
    }
}

/// Settings ▸ Appearance: System, Light or Dark, for this device.
struct AppearanceScreen: View {
    @Environment(MobileAppearance.self) private var appearance
    @Environment(\.settingsColumn) private var inColumn

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MobileLayout.headerSpacing) {
                NWListCard {
                    ForEach(MobileAppearance.Mode.allCases) { mode in
                        Button { appearance.mode = mode } label: {
                            HStack(spacing: NW.Space.l) {
                                Text(mode.title).font(.nw(.ui, weight: .medium)).foregroundStyle(Color.nw.textPrimary)
                                Spacer(minLength: NW.Space.m)
                                if appearance.mode == mode {
                                    Image(systemName: "checkmark")
                                        .font(.nw(.ui, weight: .semibold))
                                        .foregroundStyle(Color.nw.lantern)
                                }
                            }
                            .padding(.horizontal, NW.Space.l)
                            .frame(minHeight: NWListMetrics.rowHeight)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.nwRow(radius: 0))
                        .accessibilityAddTraits(appearance.mode == mode ? .isSelected : [])
                    }
                }
                Text("System follows this device's appearance. Shepherd on a Mac keeps its own.")
                    .nwText(.caption).foregroundStyle(Color.nw.textTertiary)
                    .padding(.horizontal, NW.Space.xs)
            }
            .padding(.horizontal, MobileLayout.gutter)
            .padding(.top, inColumn ? MobileLayout.settingsColumnTop : 0)
            .frame(maxWidth: MobileLayout.homeMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .background(Color.nw.bgWindow)
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }
}
