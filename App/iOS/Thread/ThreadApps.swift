import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// A thread's apps on its host (`apps.v1`): the space's quick actions and what each is doing, read
/// while the thread is on screen, and Run, Stop or Restart sent to the host.
@MainActor
@Observable
final class ThreadApps {
    /// Nil: the host doesn't offer apps, or the space has no quick actions.
    private(set) var apps: RemoteQuickApps?
    /// The last Run or Stop the host refused, and why.
    private(set) var problem: String?

    /// How often the list is read again while the thread is on screen, for an app that starts,
    /// ends or finds its port on the host.
    // ponytail: a poll; the host could push app changes if a slower or faster poll ever shows.
    static let refresh: Duration = .seconds(3)

    /// Reads the space's apps until cancelled; nil `client` (an older host, none connected) shows none.
    func watch(_ client: RemoteHostClient?, space: SpaceID?) async {
        guard let client, let space, client.capabilities.contains(RemoteProtocol.appsCapability) else { apps = nil; return }
        while !Task.isCancelled {
            await send(.list(spaceID: space), to: client)
            try? await Task.sleep(for: Self.refresh)
        }
    }

    /// A menu row's tap: runs, stops or restarts it, a space's app in `agent`'s folder.
    func act(on item: RemoteApp, client: RemoteHostClient?, space: SpaceID?, agent: AgentID) async {
        guard let client, let space else { return }
        let request: RemoteAppsRequest = switch RemoteQuickApps.action(item) {
        case .run, .restart: .run(spaceID: space, name: item.app.name, mac: item.mac, agentID: agent)
        case .stop: .stop(spaceID: space, name: item.app.name, mac: item.mac)
        }
        await send(request, to: client, failing: item.app.name)
    }

    /// Sends `request` and shows the list it answers. A Run or Stop the host refuses says why in
    /// the menu, under `failing`'s name; a list it can't give hides the control.
    private func send(_ request: RemoteAppsRequest, to client: RemoteHostClient, failing name: String? = nil) async {
        do {
            let next = RemoteQuickApps(try await client.apps(request))
            if apps != next { apps = next }
            if name != nil { problem = nil }
        } catch {
            guard let name else { apps = nil; return }
            if case RemoteHostClientError.rejected(_, let message) = error { problem = "\(name): \(message)" }
            else { problem = "\(name): \(error.localizedDescription)" }
        }
    }
}

/// The thread header's Run (AppsQuickAction, AppsRunning boards; the Mac's `ThreadAppsButton`): the
/// space's first quick action, or the app running now with its port. A tap opens its menu, which
/// lists every quick action in the space with what each is doing; a row runs, stops or restarts it
/// on the host. On a phone the button is its glyph; on regular width it names the app.
struct ThreadAppsMenu: View {
    let apps: RemoteQuickApps
    let problem: String?
    let act: (RemoteApp) -> Void
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let primary = apps.primary
        let running = primary.run?.isLive == true
        Menu {
            Section("Apps in \(apps.space)") {
                ForEach(apps.items) { item in
                    Button { act(item) } label: {
                        Label(item.app.name, systemImage: item.run?.isLive == true ? "stop.fill" : "play.fill")
                        Text(RemoteQuickApps.detail(item))
                    }
                }
            }
            if let problem {
                Section { Text(problem) }
            }
        } label: {
            if sizeClass == .regular {
                HStack(spacing: SH.Space.s) {
                    if running {
                        SHStatusDot(primary.run?.status == .starting ? .running : .done)
                    } else {
                        Image(systemName: "play.fill").font(.sh(.micro)).foregroundStyle(Color.sh.textPrimary)
                    }
                    Text(primary.app.name).foregroundStyle(Color.sh.textPrimary)
                    if running, let port = RemoteQuickApps.portLabel(primary) {
                        Text(port).font(.sh(.mono)).foregroundStyle(Color.sh.textSecondary)
                    }
                }
            } else {
                Image(systemName: running ? "play.circle.fill" : "play.fill")
                    .foregroundStyle(running ? AgentState.done.color : Color.sh.textPrimary)
            }
        }
        .accessibilityLabel(running ? "\(primary.app.name), running" : "Run \(primary.app.name)")
        .accessibilityHint("Apps in \(apps.space)")
    }
}
