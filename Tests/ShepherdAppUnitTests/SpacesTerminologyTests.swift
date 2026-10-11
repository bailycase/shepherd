import Foundation
import ShepherdProtocol
import ShepherdUI
import Testing
@testable import ShepherdApp

/// The old folder concept reads "Space" everywhere a person sees it, so the new Projects feature
/// can own "Project" (docs/design/boards/SpacesTerminology.md). Stored values, protocol names and
/// the tool ids an agent calls keep their old spelling.
@Suite("Spaces terminology")
@MainActor
struct SpacesTerminologyTests {
    @Test func theFolderSidebarStyleReadsSpacesAndStoresProjects() {
        #expect(NWSidebarStyle.projects.title == "Spaces")
        #expect(NWSidebarStyle.projects.summary == "A folder for each space with its threads inside.")
        #expect(NWSidebarStyle.projects.rawValue == "projects", "older preferences keep decoding")
        #expect(NWSidebarStyle.activity.title == "Activity")
    }

    @Test func settingsPageIsSpacesAndItsSearchFindsTheOldWordToo() {
        #expect(SettingsSection.projects.title == "Spaces")
        #expect(SettingsSection.projects.rawValue == "projects", "the stored section id is unchanged")
        #expect(SettingsSection.projects.items.contains("Filter spaces"))
        #expect(SettingsSection.projects.items.contains("Add space"))
        #expect(SettingsSection.projects.matches(for: "folders") == ["Filter spaces"])
        #expect(SettingsSection.appearance.matches(for: "spaces").contains("Organize by"))
    }

    @Test func thePlaceChipAndItsBlockersSaySpace() {
        #expect(NewThreadPlaces.chip([], chosen: nil).project == "Choose a space")
        #expect(NewThreadPlaces.referencesNote == "Design references go to spaces on this Mac.")
    }

    @Test func menuAndCommandLabelsForFolderSpacesSaySpace() {
        #expect(ShortcutAction.saveProjectFile.title == "Save Space File")
        #expect(PanesExtension.extensionSource.contains("label: \"Register Space\""))
        #expect(PanesExtension.extensionSource.contains("label: \"Remove Space\""))
    }

    @Test func agentToolIdsAndProtocolNamesKeepTheirOldSpelling() {
        for tool in ["project_register", "project_add_child", "project_edit", "project_delete", "project_refresh", "shepherd_projects"] {
            #expect(PanesExtension.extensionSource.contains(tool))
        }
        #expect(RemoteProtocol.projectsCapability == "projects.v1")
        #expect(RemoteProtocol.projectDetailsCapability == "projects.details.v1")
    }

    /// The user's amendment to ProjectLead-Activity: Designs leads the Activity groups.
    @Test func activityGroupsPutDesignsFirst() {
        let order = SidebarLists().sections.map(\.section)
        #expect(order == [.designs, .needsYou, .working, .done, .pinned, .recents])
    }
}
