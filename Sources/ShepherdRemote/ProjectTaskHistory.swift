import Foundation

/// The matching task rows, grouped in display order and in owner order within each group.
public struct ProjectTaskHistory: Equatable {
    public struct Section: Identifiable, Equatable {
        public let group: ProjectTaskGroup
        public let rows: [ProjectTaskRow]
        public var id: ProjectTaskGroup { group }
    }

    public let sections: [Section]

    public init(rows: [ProjectTaskRow], query: String, groups: Set<ProjectTaskGroup> = []) {
        let words = query.lowercased().split(separator: " ")
        var grouped: [ProjectTaskGroup: [ProjectTaskRow]] = [:]
        for row in rows {
            guard groups.isEmpty || groups.contains(row.group) else { continue }
            if !words.isEmpty {
                let fields = [row.title.lowercased(), row.detail?.lowercased() ?? "", row.lead?.lowercased() ?? ""]
                guard words.allSatisfy({ word in fields.contains { $0.contains(word) } }) else { continue }
            }
            grouped[row.group, default: []].append(row)
        }
        sections = ProjectTaskGroup.allCases.compactMap { group in
            grouped[group].map { Section(group: group, rows: $0) }
        }
    }
}
