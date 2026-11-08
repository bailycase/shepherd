import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdApp

@Suite("Add space")
@MainActor
struct AddSpaceModelTests {
    private let parent = SpaceID()
    private var rows: [ProjectsRow] {
        let local = ProjectsHost(id: "local", name: "This Mac", known: [])
        let remote = ProjectsHost(id: "build", name: "Build-01", known: [])
        return [ProjectsRow(host: local, project: ProjectSummary(directory: "/code/shepherd", name: "shepherd", displayPath: "~/code/shepherd", summary: "", projectID: parent)),
                ProjectsRow(host: remote, project: ProjectSummary(directory: "/srv/daemon", name: "daemon", displayPath: "/srv/daemon", summary: "", projectID: SpaceID()))]
    }

    @Test(arguments: [
        ("", "/code/landing", "local", false, "Enter a space name of up to 80 characters."),
        ("a/b", "/code/landing", "local", false, "Enter a space name of up to 80 characters."),
        ("landing", "code/landing", "local", false, "Choose an absolute or home-relative folder path."),
        ("landing", "/code/../etc", "local", false, "Choose an absolute or home-relative folder path."),
        ("landing", "/code/shepherd/", "local", false, "That folder is already a space on this host."),
        ("landing", "/code/landing", "build", true, "Choose a parent space on the same host."),
    ])
    func refusesWhatTheBoardRefuses(name: String, path: String, host: String, withParent: Bool, problem: String) {
        #expect(AddSpaceModel.problem(name: name, path: path, hostID: host, parentID: withParent ? parent : nil, rows: rows) == problem)
    }

    @Test func acceptsARootOrAChildOnTheSameHost() {
        #expect(AddSpaceModel.problem(name: "landing", path: "~/code/landing", hostID: "local", parentID: nil, rows: rows) == nil)
        #expect(AddSpaceModel.problem(name: "landing", path: "/elsewhere/landing", hostID: "local", parentID: parent, rows: rows) == nil)
        #expect(AddSpaceModel.problem(name: "api", path: "/srv/daemon", hostID: "local", parentID: nil, rows: rows) == nil)
    }

    @Test func theParentFollowsTheHost() {
        let model = AddSpaceModel(hosts: rows.map(\.host), rows: rows, hostID: "local", parentID: parent) { _ in }
        #expect(model.title == "Add child space" && model.parentName == "shepherd")
        model.hostID = "build"
        #expect(model.parentID == nil && model.title == "Add space" && model.parents.isEmpty)
    }

    @Test func onlyAFolderInsideTheParentsInherits() {
        let model = AddSpaceModel(hosts: rows.map(\.host), rows: rows, hostID: "local", parentID: parent) { _ in }
        model.path = "/code/shepherd/landing"
        #expect(model.inheritsFromParent == true)
        model.path = "/elsewhere/landing"
        #expect(model.inheritsFromParent == false)
        model.parentID = nil
        #expect(model.inheritsFromParent == nil)
    }
}
