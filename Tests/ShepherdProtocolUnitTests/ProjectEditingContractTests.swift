import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol

@Suite("Project editing contracts")
struct ProjectEditingContractTests {
    @Test func olderSpacesAndEditsNeverOptIntoParentOverridesOrFolderOperations() throws {
        let decoder = JSONDecoder()
        let space = try decoder.decode(Space.self, from: Data(#"{"id":"one","name":"one","path":"/one"}"#.utf8))
        #expect(space.parentID == nil && !space.parentIsExplicit)
        let edit = try decoder.decode(ProjectEdit.self, from: Data(#"{"name":"Renamed"}"#.utf8))
        #expect(edit.folderAction == .none && edit.destinationPath == nil && edit.parentProjectID == nil)
    }

    @Test func explicitRootAndParentSurviveStateRoundTrips() throws {
        let parent = Space(id: SpaceID(rawValue: "parent"), name: "Parent", path: "/parent")
        let child = Space(name: "Child", path: "/elsewhere", parentID: parent.id, parentIsExplicit: true)
        let root = Space(name: "Root", path: "/parent/root", parentIsExplicit: true)
        let state = ShepherdState(spaces: [parent, child, root])
        let restored = try JSONDecoder().decode(ShepherdState.self, from: JSONEncoder().encode(state))
        #expect(restored == state)
        #expect(ProjectNesting.parents(in: restored.spaces) == [child.id: parent.id])
    }

    @Test func persistedParentCyclesAndMissingParentsRemainVisibleRoots() {
        var a = Space(name: "A", path: "/a", parentIsExplicit: true)
        var b = Space(name: "B", path: "/b", parentIsExplicit: true)
        a.parentID = b.id; b.parentID = a.id
        let orphan = Space(name: "Orphan", path: "/orphan", parentID: SpaceID(), parentIsExplicit: true)
        #expect(ProjectNesting.parents(in: [a, b, orphan]).isEmpty)
    }

    @Test func actualConfigParentIsNotConfusedWithLogicalOrganization() throws {
        let summary = ProjectSummary(directory: "/a/docs", name: "docs", displayPath: "/a/docs", summary: "", parent: "/b",
                                     inheritedMCP: ["physical-parent-server"], inheritedFromName: "Platform A")
        let restored = try JSONDecoder().decode(ProjectSummary.self, from: JSONEncoder().encode(summary))
        #expect(restored == summary)
        #expect(restored.parent == "/b" && restored.inheritedFromName == "Platform A")
    }
}
