import SwiftUI
import ShepherdUI

/// Settings (MobileSettings board; home track): the Settings tab's root on iPhone, pushed over the
/// detail on iPad. Only what the phone has: appearance, hosts, and about.
struct SettingsScreen: View {
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileAppearance.self) private var appearance
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        let model = HomeFeed.of(hosts).model
        ScrollView {
            VStack(alignment: .leading, spacing: MobileLayout.sectionSpacing) {
                NWListCard {
                    row("Appearance", symbol: "circle.lefthalf.filled", trailing: .value(appearance.mode.title), route: .appearance)
                }
                SettingsSection("Machines") {
                    NWListCard {
                        row("Hosts", symbol: "desktopcomputer",
                            trailing: model.offlineCount > 0 ? .alert("\(model.offlineCount) offline")
                                : .value(model.hosts.isEmpty ? "None" : String(model.hosts.count)),
                            route: .hosts)
                    }
                }
                SettingsSection("About") {
                    NWListCard { AboutRow() }
                }
            }
            .padding(.horizontal, MobileLayout.gutter)
            .padding(.bottom, MobileLayout.sectionSpacing)
            .frame(maxWidth: MobileLayout.homeMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .background(Color.nw.bgWindow)
        .navigationTitle("Settings")
    }

    private func row(_ title: String, symbol: String, trailing: NWListRow.Trailing, route: SettingsRoute) -> some View {
        Button { navigator.open(.settings(route)) } label: {
            NWListRow(title, leading: .symbol(symbol), trailing: trailing)
        }
        .buttonStyle(.nwRow(radius: 0))
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

/// Shepherd's version and build.
private struct AboutRow: View {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""

    var body: some View {
        HStack(spacing: NW.Space.l) {
            NWCrook()
                .frame(width: NWListMetrics.symbol, height: NWListMetrics.symbol)
                .frame(width: NWListMetrics.leadingWidth)
                .accessibilityHidden(true)
            Text("Shepherd \(Self.version)").font(.nw(.ui, weight: .medium)).foregroundStyle(Color.nw.textPrimary)
            Spacer(minLength: NW.Space.m)
            Text("build \(Self.build)").font(.nw(.mono)).foregroundStyle(Color.nw.textTertiary)
        }
        .padding(.horizontal, NW.Space.l)
        .frame(minHeight: NWListMetrics.rowHeight)
        .accessibilityElement(children: .combine)
    }
}

/// Settings ▸ Appearance: System, Light or Dark, for this device.
struct AppearanceScreen: View {
    @Environment(MobileAppearance.self) private var appearance

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
            .frame(maxWidth: MobileLayout.homeMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .background(Color.nw.bgWindow)
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }
}
