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
        case .general, .agents, .spaces, .git, .advanced: nil
        }
    }

    /// The pages the list shows: Hooks only where a host serves them.
    func listPages(_ pages: [SettingsPage]) -> [SettingsPage] {
        pages.filter { $0 != .hooks || showsHooks }
    }
}

/// The phone's list, grouped as the Mac's is: General and Appearance, Agents (with Design systems
/// while a host serves designs), Work, then Advanced and Experiments; About last.
private struct SettingsList: View {
    let store: SettingsStore
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileAppearance.self) private var appearance
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        let designs = MobileDesigns.of(hosts).model
        ScrollView {
            VStack(alignment: .leading, spacing: MobileLayout.sectionSpacing) {
                ForEach(Array(SettingsPage.groups.enumerated()), id: \.offset) { _, group in
                    SettingsSection(group.title) {
                        SHListCard {
                            ForEach(store.listPages(group.pages), id: \.self) { page in
                                Button { navigator.open(.settings(page.route)) } label: {
                                    SettingsNavRow(page.title, value: store.listValue(page, appearance: appearance))
                                }
                                .buttonStyle(.shRow(radius: 0))
                            }
                            // While a host serves designs (More's row, before the phone had five tabs).
                            if group.title == "Agents", designs.available {
                                Button { navigator.open(.designs(.systems)) } label: {
                                    SettingsNavRow("Design systems", value: designs.systems.isEmpty ? nil : String(designs.systems.count))
                                }
                                .buttonStyle(.shRow(radius: 0))
                            }
                        }
                    }
                }
                SettingsSection("About") {
                    SHListCard { AboutRow(agent: store.agentVersion) }
                }
            }
            .padding(.horizontal, MobileLayout.gutter)
            .padding(.bottom, MobileLayout.sectionSpacing)
            .frame(maxWidth: MobileLayout.homeMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await store.refresh() }
        .background(Color.sh.bgWindow)
        .navigationTitle("Settings")
    }
}

/// A row of the phone's list or a page's drill-in: its title (over a note), a value, and a
/// chevron. No leading icon (the boards draw none).
struct SettingsNavRow: View {
    let title: String
    let note: String?
    let value: String?
    @Environment(\.dynamicTypeSize) private var typeSize

    init(_ title: String, note: String? = nil, value: String? = nil) {
        self.title = title
        self.note = note
        self.value = value
    }

    var body: some View {
        let sh = Color.sh
        HStack(spacing: SH.Space.l) {
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(title)
                    .font(.sh(.ui))
                    .foregroundStyle(sh.textPrimary)
                    .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                if let note {
                    Text(note)
                        .font(.sh(.caption))
                        .foregroundStyle(sh.textTertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let value {
                Text(value)
                    .font(.sh(.ui))
                    .foregroundStyle(sh.textTertiary)
                    .lineLimit(1)
            }
            Image(systemName: "chevron.right")
                .font(.sh(.caption, weight: .semibold))
                .foregroundStyle(sh.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, SH.Space.l)
        .padding(.vertical, SH.Space.m)
        .frame(maxWidth: .infinity, minHeight: note == nil ? SHListMetrics.rowHeight : SHListMetrics.twoLineRowHeight, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// The iPad's Settings (iPadSettingsInstructions): a 300pt list of its pages in the Mac's groups,
/// the open one on `bgSelected`, beside that page. The page names the bar and puts its actions
/// there. Too narrow for both (iPhone Duo), the phone's list.
private struct SettingsSplit: View {
    let store: SettingsStore
    @Environment(MobileNavigator.self) private var navigator
    private var selection: SettingsSelection { navigator.settingsSelection }

    var body: some View {
        PadListDetail(listWidth: MobileLayout.settingsListWidth) {
            ScrollView {
                VStack(alignment: .leading, spacing: MobileLayout.settingsListRowSpacing) {
                    ForEach(Array(SettingsPage.groups.enumerated()), id: \.offset) { index, group in
                        if let title = group.title {
                            Text(title)
                                .shText(.caption)
                                .foregroundStyle(Color.sh.textTertiary)
                                .accessibilityAddTraits(.isHeader)
                                .padding(.horizontal, SH.Space.l)
                                .padding(.top, MobileLayout.settingsListGroupGap)
                                .padding(.bottom, SH.Space.xs)
                        } else if index > 0 {
                            Color.clear.frame(height: MobileLayout.settingsListGroupGap)
                        }
                        ForEach(store.listPages(group.pages), id: \.self) { page in
                            SettingsListItem(page: page, selected: selection.page == page) { selection.page = page }
                        }
                    }
                }
                .padding(MobileLayout.settingsListInset)
                AboutLine(agent: store.listFootVersion(page: selection.page))
                    .padding(.horizontal, MobileLayout.settingsListInset + SH.Space.l)
                    .padding(.vertical, SH.Space.l)
            }
            .refreshable { await store.refresh() }
            .background(Color.sh.bgWindow)
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

/// One page in the iPad's list: its name; the open one on `bgSelected` and semibold.
private struct SettingsListItem: View {
    let page: SettingsPage
    let selected: Bool
    let open: () -> Void

    var body: some View {
        let sh = Color.sh
        Button(action: open) {
            HStack(spacing: SH.Space.l) {
                Text(page.title)
                    .font(.sh(.ui, weight: selected ? .semibold : .regular))
                    .foregroundStyle(sh.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, SH.Space.l)
            .frame(minHeight: MobileLayout.settingsListItemHeight)
            .background(selected ? sh.bgSelected : .clear, in: RoundedRectangle(cornerRadius: MobileLayout.settingsListRowRadius))
            .contentShape(RoundedRectangle(cornerRadius: MobileLayout.settingsListRowRadius))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
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
    @ViewBuilder let content: () -> Content

    /// A group with no title is its card alone (the list's General and Appearance).
    init(_ title: String?, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MobileLayout.headerSpacing) {
            if let title { SHListHeader(title) }
            content()
        }
    }
}

/// Shepherd's version beside the agent the host runs ("agent 0.87.1"), or this build while no
/// host has said.
private struct AboutRow: View {
    let agent: String?

    var body: some View {
        HStack(spacing: SH.Space.l) {
            Text("Shepherd \(AboutLine.version)").font(.sh(.ui, weight: .medium)).foregroundStyle(Color.sh.textPrimary)
            Spacer(minLength: SH.Space.m)
            Text(agent ?? "build \(AboutLine.build)").font(.sh(.mono)).foregroundStyle(Color.sh.textTertiary)
        }
        .padding(.horizontal, SH.Space.l)
        .frame(minHeight: SHListMetrics.rowHeight)
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
            .shText(.caption)
            .foregroundStyle(Color.sh.textTertiary)
    }
}

/// Settings ▸ Appearance: System, Light or Dark, for this device.
struct AppearanceScreen: View {
    @Environment(MobileAppearance.self) private var appearance
    @Environment(\.settingsColumn) private var inColumn

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MobileLayout.headerSpacing) {
                SHListCard {
                    ForEach(MobileAppearance.Mode.allCases) { mode in
                        Button { appearance.mode = mode } label: {
                            HStack(spacing: SH.Space.l) {
                                Text(mode.title).font(.sh(.ui, weight: .medium)).foregroundStyle(Color.sh.textPrimary)
                                Spacer(minLength: SH.Space.m)
                                if appearance.mode == mode {
                                    Image(systemName: "checkmark")
                                        .font(.sh(.ui, weight: .semibold))
                                        .foregroundStyle(Color.sh.lantern)
                                }
                            }
                            .padding(.horizontal, SH.Space.l)
                            .frame(minHeight: SHListMetrics.rowHeight)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.shRow(radius: 0))
                        .accessibilityAddTraits(appearance.mode == mode ? .isSelected : [])
                    }
                }
                Text("System follows this device's appearance. Shepherd on a Mac keeps its own.")
                    .shText(.caption).foregroundStyle(Color.sh.textTertiary)
                    .padding(.horizontal, SH.Space.xs)
            }
            .padding(.horizontal, MobileLayout.gutter)
            .padding(.top, inColumn ? MobileLayout.settingsColumnTop : 0)
            .frame(maxWidth: MobileLayout.homeMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .background(Color.sh.bgWindow)
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }
}
