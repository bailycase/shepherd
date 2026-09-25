import SwiftUI
import ShepherdUI

/// Settings (MobileSettings board; home track): the Settings tab's root on iPhone.
struct SettingsScreen: View {
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileAppearance.self) private var appearance

    var body: some View {
        let offline = hosts.hosts.count { !$0.phase.isConnected }
        List {
            Section {
                NavigationLink(value: MobileRoute.settings(.appearance)) {
                    LabeledContent("Appearance", value: appearance.mode.title)
                }
            }
            Section("Machines") {
                NavigationLink(value: MobileRoute.settings(.hosts)) {
                    LabeledContent("Hosts", value: offline > 0 ? "\(offline) offline" : "\(hosts.hosts.count)")
                }
            }
            Section("About") {
                LabeledContent("Shepherd", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
            }
        }
        .font(.nw(.ui))
        .scrollContentBackground(.hidden)
        .background(Color.nw.bgWindow)
        .navigationTitle("Settings")
    }
}

/// Settings ▸ Appearance: System, Light or Dark, for this device.
struct AppearanceScreen: View {
    @Environment(MobileAppearance.self) private var appearance

    var body: some View {
        @Bindable var appearance = appearance
        List {
            Picker("Appearance", selection: $appearance.mode) {
                ForEach(MobileAppearance.Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        .font(.nw(.ui))
        .scrollContentBackground(.hidden)
        .background(Color.nw.bgWindow)
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }
}
