import Foundation
import ShepherdCore
import ShepherdProtocol

/// Validates metadata without doing filesystem work. Explicit parenting changes presentation,
/// never agent working directories or instruction/config inheritance.
enum ProjectEditing {
    static func updated(_ space: Space, edit: ProjectEdit, spaces: [Space]) throws -> Space {
        var result = space
        if let name = edit.name {
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 256, name.rangeOfCharacter(from: .controlCharacters) == nil else {
                throw ProjectFileError("invalid_name", "Use a display name of 1–256 characters without control characters.")
            }
            result.name = name
        }
        if let rawParent = edit.parentProjectID {
            let parent = rawParent.isEmpty ? nil : SpaceID(rawValue: rawParent)
            guard parent != space.id, parent == nil || spaces.contains(where: { $0.id == parent && !$0.hidden }) else {
                throw ProjectFileError("invalid_parent", "Choose another registered local project, or an empty parentProjectID for a top-level project.")
            }
            result.parentID = parent
            result.parentIsExplicit = true
            let changed = spaces.map { $0.id == result.id ? result : $0 }
            let parents = ProjectNesting.parents(in: changed)
            // Invalid persisted edges render as roots, but an edit must never silently truncate them.
            let ids = Set(changed.map(\.id))
            for project in changed where project.parentIsExplicit {
                if let parent = project.parentID, ids.contains(parent), parents[project.id] != parent {
                    throw ProjectFileError("invalid_hierarchy", "Projects cannot form cycles or exceed 16 parent levels.")
                }
            }
        }
        guard edit.folderAction != .none || edit.destinationPath == nil else {
            throw ProjectFileError("explicit_folder_action_required", "destinationPath requires an explicit folderAction of move or copy. Metadata edits never move folders.")
        }
        return result
    }
}
