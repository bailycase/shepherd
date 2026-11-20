import ShepherdCore
import ShepherdRemote

struct ProjectHistoryInput: Equatable {
    let rows: [ProjectTaskRow]
    let query: String

    func items() -> [Item] {
        ProjectTaskHistory(rows: rows, query: query).sections.flatMap { section in
            [.header(section.group, count: section.rows.count)] + section.rows.map { row in
                .row(row, first: row.id == section.rows.first?.id, last: row.id == section.rows.last?.id)
            }
        }
    }

    /// Flatten the cards into the scroll view's lazy stack, keeping each row's own card segment.
    enum Item: Identifiable, Equatable {
        case header(ProjectTaskGroup, count: Int)
        case row(ProjectTaskRow, first: Bool, last: Bool)

        enum ID: Hashable {
            case header(ProjectTaskGroup)
            case row(ProjectTaskID)
        }

        var id: ID {
            switch self {
            case .header(let group, _): .header(group)
            case .row(let row, _, _): .row(row.id)
            }
        }
    }
}
