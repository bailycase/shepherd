import Foundation
import ShepherdCore
import Testing
@testable import ShepherdApp

@Suite("Project folder route")
struct ProjectFolderRouteTests {
    @Test func aLocalOwnerChoosesOnThisMacAndARemoteOwnerOnlyThroughItsOwnHost() {
        let host = UUID()
        #expect(ProjectFolderRoute.route(home: .local, connection: nil) == .thisMac)
        #expect(ProjectFolderRoute.thisMac.menuTitle == "Choose folder…" && ProjectFolderRoute.thisMac.isAvailable)
        let connected = ProjectFolderRoute.route(home: .host(host), connection: (name: "build-01", connected: true))
        #expect(connected == .host(host, name: "build-01") && connected.menuTitle == "Choose folder on build-01…" && connected.isAvailable)
        // An owner this Mac is not connected to (or no longer lists) is never answered with a folder of this Mac.
        let offline = ProjectFolderRoute.route(home: .host(host), connection: (name: "build-01", connected: false))
        #expect(offline == .offline(name: "build-01") && !offline.isAvailable && offline.menuTitle.contains("not connected"))
        #expect(ProjectFolderRoute.route(home: .host(host), connection: nil) == .offline(name: "its host"))
    }
}
