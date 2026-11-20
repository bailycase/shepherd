import Foundation
import ShepherdCore

extension StateStore {
    /// Reject only records with a known broken dependency. Other invalid references are left
    /// for validate() to refuse, rather than guessed at or rewritten.
    static func recover(_ original: Data, rejectedAt url: URL) throws -> ShepherdState {
        var document = try PersistedFile<ShepherdState>.jsonObject(in: original)
        func array(_ key: String) throws -> [Any] {
            guard let array = document[key] as? [Any] else { throw CocoaError(.fileReadCorruptFile) }
            return array
        }
        func ids(_ records: [Any]) -> Set<String> {
            Set(records.compactMap { ($0 as? [String: Any])?["id"] as? String })
        }

        let spaces = try LossyJSONArray<Space>(array("spaces"))
        var tabs = try LossyJSONArray<Tab>(array("tabs"))
        var agents = try LossyJSONArray<Agent>(array("agents"))
        let badSpaces = ids(spaces.rejected)
        var badAgents: Set<String>
        // A tab can name an agent in its layout, and an agent needs its tab. Follow both
        // directions until the rejected group stops growing.
        while true {
            badAgents = ids(agents.rejected)
            tabs.reject { tab in
                tab.spaceID.map { badSpaces.contains($0.rawValue) } == true
                    || tab.inspectorFor.map { badAgents.contains($0.rawValue) } == true
                    || tab.layout.leaves.contains { $0.agentID.map { badAgents.contains($0.rawValue) } == true }
            }
            let badTabs = ids(tabs.rejected)
            let count = agents.rejected.count
            agents.reject { badSpaces.contains($0.spaceID.rawValue) || badTabs.contains($0.tabID.rawValue) }
            if agents.rejected.count == count { break }
        }

        var rejected = ["spaces": spaces.rejected, "tabs": tabs.rejected, "agents": agents.rejected]
        document["spaces"] = spaces.records.map(\.raw)
        document["tabs"] = tabs.records.map(\.raw)
        document["agents"] = agents.records.map(\.raw)
        if let raw = document["automations"], !(raw is NSNull) {
            var automations = try LossyJSONArray<Automation>(array("automations"))
            guard automations.rejected.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            automations.reject { automation in
                if automation.agentID.map({ badAgents.contains($0.rawValue) }) == true { return true }
                if case .thread(let id) = automation.destination { return badAgents.contains(id.rawValue) }
                return false
            }
            document["automations"] = automations.records.map(\.raw)
            rejected["automations"] = automations.rejected
        }
        rejected = rejected.filter { !$0.value.isEmpty }
        // No element decode failed: this is not a graph the lossy decoder can safely repair.
        guard !rejected.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        try JSONSerialization.data(withJSONObject: rejected, options: [.prettyPrinted, .sortedKeys])
            .write(to: url, options: .withoutOverwriting)
        let candidate = try JSONDecoder().decode(ShepherdState.self, from: JSONSerialization.data(withJSONObject: document))
        try candidate.validate()
        return candidate
    }
}
