import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// Settings ▸ Spaces ▸ Organize (spaces.lifecycle.v1): a host's spaces in its own order, one hidden from its sidebar, and the dialogs.
// Every name is made up. The fixture host changes nothing, so the screens only read.
extension FixtureCatalog {
    static var spaceLifecycle: [FixtureScreen] {
        let web = FixtureData.acmeWeb
        return [
            FixtureScreen(name: "settings-spaces", hosts: FixtureData.spaceHosts(), routes: [.settings(.spaces)], tab: .settings),
            FixtureScreen(name: "settings-spaces-organize", hosts: FixtureData.spaceHosts(), routes: [.settings(.spaces), .settings(.organizeSpaces)], tab: .settings),
            FixtureScreen(name: "settings-spaces-organize-rename", hosts: FixtureData.spaceHosts(),
                          routes: [.settings(.spaces), .settings(.organizeSpaces)], tab: .settings,
                          prepare: { app in SettingsStore.of(app.hosts).spaceDialogs.rename = .init(target: .init(host: FixtureData.studio, space: web.id), name: web.name) }),
            FixtureScreen(name: "settings-spaces-organize-remove", hosts: FixtureData.spaceHosts(),
                          routes: [.settings(.spaces), .settings(.organizeSpaces)], tab: .settings,
                          prepare: { app in SettingsStore.of(app.hosts).spaceDialogs.removal = .init(host: FixtureData.studio, space: web.id) }),
            // Two Macs; the one Organize shows is forgotten with its Rename and Remove Space… open: both end, the other Mac stays.
            FixtureScreen(name: "settings-spaces-organize-forgotten", hosts: FixtureData.spaceHosts() + [FixtureHostData(id: FixtureData.buildBox, name: "Build box", state: ShepherdState())],
                          routes: [.settings(.spaces), .settings(.organizeSpaces)], tab: .settings,
                          verify: { app in
                              let store = SettingsStore.of(app.hosts)
                              guard store.settingsHost?.id == FixtureData.studio, store.hosts.count == 2 else {
                                  return FixtureCheck.report("FIXTURE CHECK FAILED: Organize shows \(String(describing: store.settingsHost?.id)) of \(store.hosts.count) hosts")
                              }
                              let target = SpaceLifecycleTarget(host: FixtureData.studio, space: web.id)
                              store.spaceDialogs.rename = .init(target: target, name: web.name)
                              store.spaceDialogs.removal = target
                              SettingsStore.forget(host: FixtureData.studio, in: app.hosts)
                              let ended = store.spaceDialogs.rename == nil && store.spaceDialogs.removal == nil
                              FixtureCheck.report(ended && store.settingsHost?.id == FixtureData.buildBox
                                  ? "FIXTURE CHECK ok: forgetting the shown host ends its Rename and Remove Space…"
                                  : "FIXTURE CHECK FAILED: rename \(String(describing: store.spaceDialogs.rename)), removal \(String(describing: store.spaceDialogs.removal)), shown \(String(describing: store.settingsHost?.id))")
                          }),
            // The iPad's list beside Spaces, which offers Organize.
            FixtureScreen(name: "settings-pad-spaces", hosts: FixtureData.spaceHosts(), routes: [.settings(.root)], tab: .settings,
                          prepare: { app in app.navigator.settingsSelection.page = .spaces }),
            // A host from before the capability: its spaces stay as they are, and the page says why.
            FixtureScreen(name: "settings-spaces-organize-old", hosts: FixtureData.spaceHosts(offering: false),
                          routes: [.settings(.spaces), .settings(.organizeSpaces)], tab: .settings),
        ]
    }
}

extension FixtureData {
    static let acmeWeb = Space(id: SpaceID(rawValue: "space-acme-web"), name: "acme-web", path: "/Users/dev/acme-web")
    static let acmeApi = Space(id: SpaceID(rawValue: "space-acme-api"), name: "acme-api", path: "/Users/dev/acme-api")
    static let acmeDocs = Space(id: SpaceID(rawValue: "space-acme-docs"), name: "acme-docs", path: "/Users/dev/acme-docs", sidebarHidden: true)

    /// Studio with three spaces (acme-docs hidden from its sidebar), the reserved one the host keeps for threads with no space, and two
    /// threads in acme-web. `offering` false is a host that predates `spaces.lifecycle.v1`.
    static func spaceHosts(offering: Bool = true) -> [FixtureHostData] {
        let reserved = Space(id: SpaceID(rawValue: "space-none"), name: "No space", path: "/Users/dev", hidden: true, holdsThreads: true)
        let threads = [agent(preview, "Fix the signup form", .idle, space: acmeWeb), agent(extensions, "Add a pricing page", .working, space: acmeWeb)]
        var studio = FixtureHostData(id: FixtureData.studio, name: "Studio",
                                     state: ShepherdState(spaces: [acmeWeb, acmeApi, acmeDocs, reserved], agents: threads))
        if !offering { studio.capabilities = RemoteProtocol.capabilities.filter { $0 != RemoteProtocol.spaceLifecycleCapability } }
        let listing = ProjectListing(projects: [acmeWeb, acmeApi, acmeDocs].map {
            ProjectSummary(directory: $0.path, name: $0.name, displayPath: "~/" + ($0.path as NSString).lastPathComponent,
                           summary: "AGENTS.md", projectID: $0.id)
        })
        // The listing is a read, but the fixture host counts every `projects` request as a change unless a check takes it.
        studio.accepts = { request in
            guard case .projects(let id, .list) = request else { return nil }
            return .projects(id: id, result: .listing(listing))
        }
        return [studio]
    }
}
