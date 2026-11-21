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
        let dialogs = SpaceDialogBindings.make(dialogs: store.spaceDialogs, spaces: spaces, shown: { store.settingsHost?.id },
                                               send: { send($0, to: $1, store: store) })
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
        .alert("Rename \(dialogs.renamed?.name ?? "space")", isPresented: dialogs.isRenaming) {
            TextField("Name", text: dialogs.name)
            Button("Rename", action: dialogs.rename)
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(SpaceLifecyclePresentation.removeTitle, isPresented: dialogs.isRemoving,
                            titleVisibility: .visible, presenting: dialogs.removed) { _ in
            Button(SpaceLifecyclePresentation.removeButton, role: .destructive, action: dialogs.remove)
        } message: { space in
            Text(SpaceLifecyclePresentation.removeMessage(name: space.name, threads: mobile.map { SpaceLifecyclePresentation.threads(in: $0.state, of: space) } ?? 0))
        }
    }

    /// The space's actions, as the Mac's project menu: Rename, Hide from Sidebar, its place in the order, Remove Space….
    private func menu(for space: Space, in spaces: [Space], host: SettingsHost, store: SettingsStore) -> some View {
        let target = SpaceLifecycleTarget(host: host.id, space: space.id)
        let up = SpaceLifecyclePresentation.moveUp(space.id, in: spaces), down = SpaceLifecyclePresentation.moveDown(space.id, in: spaces)
        return Menu {
            Button("Rename…") { store.spaceDialogs.rename = .init(target: target, name: space.name) }
            Button(SpaceLifecyclePresentation.toggleTitle(of: space)) {
                send(.setSidebarHidden(hidden: !space.sidebarHidden), to: target, store: store)
            }
            Button("Move Up") { if let up { send(up, to: target, store: store) } }
                .disabled(up == nil)
            Button("Move Down") { if let down { send(down, to: target, store: store) } }
                .disabled(down == nil)
            Divider()
            Button("Remove Space…", role: .destructive) { store.spaceDialogs.removal = target }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.sh(.ui))
                .foregroundStyle(Color.sh.textSecondary)
                .frame(minWidth: SHListMetrics.rowHeight, minHeight: SHListMetrics.rowHeight)
        }
        .disabled(busy)
        .accessibilityLabel("\(space.name) actions")
    }

    /// One change at a time, through the host the space was shown on, never the one Organize shows by now: the host's pushed state shows
    /// it, and a refusal shows in words.
    private func send(_ action: RemoteSpaceLifecycle, to target: SpaceLifecycleTarget, store: SettingsStore) {
        guard !busy, let client = SpaceLifecycleDialogs.host(of: target, in: store.hosts)?.client else { return }
        busy = true
        problem = nil
        Task {
            do { try await client.spaceLifecycle(action, spaceID: target.space) } catch { problem = SpaceLifecyclePresentation.problem(error) }
            busy = false
        }
    }
}
