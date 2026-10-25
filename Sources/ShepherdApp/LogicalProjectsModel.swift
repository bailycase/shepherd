import Foundation
import Observation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// Settings and navigation for the new Projects feature (ProjectLead boards), over the owning
// host's `logicalProjects` API. This model creates no thread, session or process; it edits the
// persisted record. Every edit carries the revision it was shown. A refusal re-reads the project
// and keeps the user's draft, so nothing is overwritten on a stale view.

/// The four in-workspace Project settings pages (ProjectLead-Settings*), in the boards' order.
enum LogicalProjectSettingsTab: String, CaseIterable, Identifiable {
    case general = "General", spaces = "Spaces", memory = "Memory", automations = "Automations"
    var id: Self { self }
}

// MARK: The Projects experiment (Settings ▸ Experiments)

extension ShepherdViewModel {
    /// This Mac's switch. Every Project entry point in the UI reads it; the host gates the requests themselves.
    var projectsEnabled: Bool { settings.projectsEnabled }

    /// The pages that exist only while Projects is on.
    var isProjectDestination: Bool { destination == .project || destination == .projectSettings }

    /// Call from the backend's `settings.onProjectsChange`, after `server.setProjectsEnabled`. Off closes only Project navigation: the
    /// page on screen, the New project and New thread sheets, and the pane's task and file. Projects, their files, conversation drafts
    /// and the pane's tab and filter stay. On does nothing, so nothing reopens and no work resumes.
    func projectsExperimentChanged() {
        guard !projectsEnabled else { return }
        if isProjectDestination { destination = nil }
        if selectedLogicalProject != nil { selectedLogicalProject = nil }
        if newLogicalProject != nil { newLogicalProject = nil }
        if assigningProjectTask != nil { assigningProjectTask = nil }
        if logicalProjectPaneTask != nil { logicalProjectPaneTask = nil }
        if logicalProjectPaneFile != nil { logicalProjectPaneFile = nil }
    }
}
