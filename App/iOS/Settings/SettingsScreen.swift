import SwiftUI
import ShepherdUI

/// Settings (MobileSettings, iPadSettingsInstructions boards; home track): the Settings tab's root
/// on iPhone, a list of rows each pushing its page; on iPad, pushed over the detail, the list
/// beside the page it opens. Models, Agents, Tools and Git are a host's own settings,
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
                    .navigationTitle("Settings")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar(removing: .title)
            }
        }
        .task { await store.watch() }
    }
}

extension SettingsStore {
    /// A page's value on the phone's list ("claude-opus", "8 · 2 updates"), once a host says.
    func listValue(_ page: SettingsPage, appearance: MobileAppearance) -> String? {
        switch page {
        case .appearance: appearance.mode.title
        case .models: defaultsValue
        case .instructions: instructionsValue
        case .skills: skillsValue
        case .tools: extensionsValue.map { "\($0) on" }
        case .hooks: hooksValue
        case .experiments: experimentsValue
        case .fleet: if case .value(let text) = fleetValue { text } else { nil }
        case .general, .agents, .spaces, .git, .apps, .advanced: nil
        }
    }

    /// The pages the list shows: Hooks only where a host serves them.
    func listPages(_ pages: [SettingsPage]) -> [SettingsPage] {
        pages.filter { $0 != .hooks || showsHooks }
    }
}

/// The Settings list (MobileSettings; iPadSettingsInstructions's middle column): grouped as the Mac's is,
/// General and Appearance, Agents (with Design systems while a host serves designs), Work, then
/// Advanced and Experiments; About last. On the phone a row pushes its page; beside the iPad's page
/// the open one is filled and no row draws a chevron.
private struct SettingsList: View {
    let store: SettingsStore
    var pad = false
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileAppearance.self) private var appearance
    @Environment(MobileNavigator.self) private var navigator
    @FocusState private var searching: Bool

    var body: some View {
        let designs = MobileDesigns.of(hosts).model
        @Bindable var selection = navigator.settingsSelection
        let query = selection.searchQuery
        let hits = SettingsSearch.hits(for: query, showsHooks: store.showsHooks)
        VStack(spacing: 0) {
        if pad { PadColumnBar("Settings", inset: MobileLayout.settingsPadBarInset) }
        ScrollView {
            VStack(alignment: .leading, spacing: MobileLayout.settingsSectionSpacing) {
                if !pad { SettingsHeading("Settings") }
                SettingsSearchCapsule(placeholder: "Search settings", text: $selection.searchQuery, focus: $searching)
                if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    SettingsSearchResults(hits: hits, pad: pad, selection: selection) { page, row in
                        if pad { selection.select(page, row: row) } else { navigator.open(.settings(page.route)) }
                    }
                } else {
                    ForEach(Array(SettingsPage.groups.enumerated()), id: \.offset) { _, group in
                        SettingsSection(group.title) {
                            SettingsCard {
                                ForEach(store.listPages(group.pages), id: \.self) { page in
                                    Button { if pad { selection.page = page } else { navigator.open(.settings(page.route)) } } label: {
                                        SettingsRow(page.title, trailing: store.listValue(page, appearance: appearance).map { .value($0) } ?? .none,
                                                    chevron: !pad, selected: pad && selection.page == page)
                                    }
                                    .buttonStyle(.shRow(radius: 0))
                                }
                                // While a host serves designs (More's row, before the phone had five tabs).
                                if group.title == "Agents", designs.available {
                                    Button { navigator.open(.designs(.systems)) } label: {
                                        SettingsRow("Design systems", trailing: designs.systems.isEmpty ? .none : .value(String(designs.systems.count)),
                                                    chevron: !pad)
                                    }
                                    .buttonStyle(.shRow(radius: 0))
                                }
                            }
                        }
                    }
                    if pad {
                        AboutLine(agent: store.listFootVersion(page: selection.page))
                            .padding(.horizontal, SH.Space.xs)
                    } else {
                        SettingsSection("About") {
                            SettingsCard { AboutRow(agent: store.agentVersion) }
                        }
                    }
                }
            }
            .padding(.horizontal, MobileLayout.gutter)
            .padding(.bottom, MobileLayout.sectionSpacing)
            .frame(maxWidth: MobileLayout.homeMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await store.refresh() }
        }
        .background(Color.sh.bgWindow)
    }
}

/// A row of a page's drill-in: its title (over a note), a value, and a chevron. No leading icon (the
/// boards draw none).
struct SettingsNavRow: View {
    let title: String
    let note: String?
    let value: String?

    init(_ title: String, note: String? = nil, value: String? = nil) {
        self.title = title
        self.note = note
        self.value = value
    }

    var body: some View {
        SettingsRow(title, subtitle: note, trailing: value.map { .value($0) } ?? .none)
    }
}

/// The iPad's Settings (iPadSettingsInstructions): the list of its pages in the Mac's groups beside the
/// page it opens. The page names the bar and puts its actions there. Too narrow for both (iPhone
/// Duo), the phone's list.
private struct SettingsSplit: View {
    let store: SettingsStore
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        let selection = navigator.settingsSelection
        PadListDetail(listWidth: MobileLayout.settingsListWidth) {
            SettingsList(store: store, pad: true)
        } detail: {
            SettingsPageView(page: selection.page)
                .environment(\.settingsColumn, true)
                .id(selection.page)
        } single: {
            SettingsList(store: store)
        }
        .background(Color.sh.bgWindow)
    }
}

/// A Settings page by itself, as the iPad shows it beside the list.
struct SettingsPageView: View {
    let page: SettingsPage

    var body: some View { SettingsDestination(route: page.route) }
}

extension SettingsStore {
    /// Opens another page: in place beside the iPad's list, else on its own.
    func open(_ page: SettingsPage, inColumn: Bool, navigator: MobileNavigator) {
        if inColumn { navigator.settingsSelection.page = page } else { navigator.open(.settings(page.route)) }
    }
}

/// A titled group of Settings cards.
struct SettingsSection<Content: View>: View {
    let title: String?
    let count: Int?
    @ViewBuilder let content: () -> Content

    /// A group with no title is its card alone (the list's General and Appearance).
    init(_ title: String?, count: Int? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.count = count
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MobileLayout.headerSpacing) {
            if let title { SettingsCaption(title, count: count) }
            content()
        }
    }
}

/// Shepherd's version beside the agent the host runs ("agent 0.87.1"), or this build while no
/// host has said.
private struct AboutRow: View {
    let agent: String?

    var body: some View {
        SettingsRow("Shepherd \(AboutLine.version)", trailing: .value(agent ?? "build \(AboutLine.build)"), chevron: false)
    }
}

/// The iPad list's foot: "Shepherd 0.1.0 · agent 0.87.1" ("pi 0.87.1" beside the Pi page).
private struct AboutLine: View {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""

    let agent: String?

    var body: some View {
        Text(["Shepherd \(Self.version)", agent ?? "build \(Self.build)"].joined(separator: " · "))
            .font(.shSans(MobileLayout.settingsCaptionSize))
            .foregroundStyle(Color.sh.textTertiary)
    }
}

/// Settings ▸ Appearance: System, Light or Dark, for this device.
struct AppearanceScreen: View {
    @Environment(MobileAppearance.self) private var appearance

    var body: some View {
        SettingsPageScaffold("Appearance") {
            SettingsCard {
                ForEach(MobileAppearance.Mode.allCases) { mode in
                    Button { appearance.mode = mode } label: {
                        HStack(spacing: SH.Space.l) {
                            Text(mode.title).font(.sh(.ui)).foregroundStyle(Color.sh.textPrimary)
                            Spacer(minLength: SH.Space.m)
                            if appearance.mode == mode {
                                Image(systemName: "checkmark")
                                    .font(.sh(.ui, weight: .semibold))
                                    .foregroundStyle(Color.sh.textPrimary)
                            }
                        }
                        .padding(.horizontal, MobileLayout.settingsRowInset)
                        .frame(minHeight: MobileLayout.settingsRowHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.shRow(radius: 0))
                    .accessibilityAddTraits(appearance.mode == mode ? .isSelected : [])
                }
            }
            SettingsFootnote("System follows this device's appearance. Shepherd on a Mac keeps its own.")
        }
    }
}
