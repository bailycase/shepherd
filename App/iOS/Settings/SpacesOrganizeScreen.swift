import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// Settings ▸ Spaces ▸ Organize (home track): rename, hide, reorder and remove the spaces of the host this device is paired with, as
/// the Mac's sidebar menu does (`spaces.lifecycle.v1`). The list is the host's own order and updates from its pushed state, so a
/// change shows once the host has made it. Removing forgets a space in Shepherd's record and stops its threads; no folder is touched.
struct SpacesOrganizeScreen: View {
    @Environment(MobileHosts.self) private var hosts
    @Environment(\.settingsColumn) private var inColumn
    @State private var problem: String?
    @State private var busy = false

    var body: some View {
        let store = SettingsStore.of(hosts)
        let host = store.settingsHost
        let mobile = host.flatMap { hosts.host($0.id) }
        let spaces = mobile.map { SpaceLifecyclePresentation.spaces(in: $0.state) } ?? []
        ScrollView {
            VStack(alignment: .leading, spacing: MobileLayout.sectionSpacing) {
                Text("Rename, hide, reorder or remove the spaces in the order \(host?.name ?? "the host") keeps them. A change shows on its Mac too.")
                    .shText(.caption)
                    .foregroundStyle(Color.sh.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, SH.Space.xs)
                if let host, let mobile {
                    if !host.serves(RemoteProtocol.spaceLifecycleCapability) {
                        SettingsFootnote(host.isConnected
                            ? "\(host.name)'s Shepherd is too old to change its spaces from here. Update it first."
                            : "\(host.name) is offline. Its spaces can be changed once it's back.")
                    } else if spaces.isEmpty {
                        SettingsFootnote("No spaces on \(host.name) yet.")
                    } else {
                        SHListCard {
                            ForEach(spaces) { space in
                                SettingsControlRow(space.name, note: "`\(space.path)`" + (space.sidebarHidden ? " · Hidden from the sidebar" : "")) {
                                    menu(for: space, in: spaces, host: host, store: store)
                                }
                                .opacity(space.sidebarHidden ? SHListMetrics.dimmedOpacity : 1)
                            }
                        }
                        SettingsFootnote("Removing a space only forgets it in Shepherd. Its folder and files stay on \(host.name).")
                    }
                    if let problem { SettingsFootnote(problem, tone: .failed) }
                } else {
                    SettingsFootnote("Add a host in Settings ▸ Fleet to organize its spaces.")
                }
            }
            .padding(.horizontal, MobileLayout.gutter)
            .padding(.top, inColumn ? MobileLayout.settingsColumnTop : 0)
            .padding(.bottom, MobileLayout.sectionSpacing)
            .frame(maxWidth: MobileLayout.homeMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .background(Color.sh.bgWindow)
        .navigationTitle("Organize spaces")
        .navigationBarTitleDisplayMode(inColumn ? .inline : .large)
        .alert("Rename \(spaces.first { $0.id == store.spaceRename?.space }?.name ?? "space")",
               isPresented: Binding(get: { store.spaceRename != nil }, set: { if !$0 { store.spaceRename = nil } })) {
            TextField("Name", text: Binding(get: { store.spaceRename?.name ?? "" }, set: { store.spaceRename?.name = $0 }))
            Button("Rename") {
                if let rename = store.spaceRename, let space = spaces.first(where: { $0.id == rename.space }),
                   let new = SpaceLifecyclePresentation.renamed(rename.name, from: space.name) {
                    send(.rename(name: new), space: space.id, host: host)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(SpaceLifecyclePresentation.removeTitle,
                            isPresented: Binding(get: { removal(in: spaces, store) != nil }, set: { if !$0 { store.spaceRemoval = nil } }),
                            titleVisibility: .visible, presenting: removal(in: spaces, store)) { space in
            Button(SpaceLifecyclePresentation.removeButton, role: .destructive) { send(.remove, space: space.id, host: host) }
        } message: { space in
            Text(SpaceLifecyclePresentation.removeMessage(name: space.name, threads: mobile.map { SpaceLifecyclePresentation.threads(in: $0.state, of: space) } ?? 0))
        }
    }

    /// The space waiting on Remove Space…'s answer, if the host still has it.
    private func removal(in spaces: [Space], _ store: SettingsStore) -> Space? {
        spaces.first { $0.id == store.spaceRemoval }
    }

    /// The space's actions, as the Mac's project menu: Rename, Hide from Sidebar, its place in the order, Remove Space….
    private func menu(for space: Space, in spaces: [Space], host: SettingsHost, store: SettingsStore) -> some View {
        let up = SpaceLifecyclePresentation.moveUp(space.id, in: spaces), down = SpaceLifecyclePresentation.moveDown(space.id, in: spaces)
        return Menu {
            Button("Rename…") { store.spaceRename = (space.id, space.name) }
            Button(SpaceLifecyclePresentation.toggleTitle(of: space)) {
                send(.setSidebarHidden(hidden: !space.sidebarHidden), space: space.id, host: host)
            }
            Button("Move Up") { if let up { send(up, space: space.id, host: host) } }
                .disabled(up == nil)
            Button("Move Down") { if let down { send(down, space: space.id, host: host) } }
                .disabled(down == nil)
            Divider()
            Button("Remove Space…", role: .destructive) { store.spaceRemoval = space.id }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.sh(.ui))
                .foregroundStyle(Color.sh.textSecondary)
                .frame(minWidth: SHListMetrics.rowHeight, minHeight: SHListMetrics.rowHeight)
        }
        .disabled(busy)
        .accessibilityLabel("\(space.name) actions")
    }

    /// One change at a time: the host's pushed state shows it, and a refusal shows in words.
    private func send(_ action: RemoteSpaceLifecycle, space: SpaceID, host: SettingsHost?) {
        guard !busy, let client = host?.client as? RemoteHostClient else { return }
        busy = true
        problem = nil
        Task {
            do { try await client.spaceLifecycle(action, spaceID: space) } catch { problem = SpaceLifecyclePresentation.problem(error) }
            busy = false
        }
    }
}
