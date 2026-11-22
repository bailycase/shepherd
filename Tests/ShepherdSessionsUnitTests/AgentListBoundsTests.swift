import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions

/// What `agent_list` sends: the plain list is every thread as it always was; `details` is newest first, capped on the host with a count of the
/// rest, and every text is one short line. Also the line a text becomes (`listLabel`) and that a dispatch record from before `titleGiven` reads
/// as task-titled.
@Suite("Agent list bounds")
struct AgentListBoundsTests {
    static let nasty = "line one\nline two\t\u{1B}[31mred\u{0}\u{202E}" + String(repeating: "x", count: 10_000)

    static func state(threads: Int, name: (Int) -> String = { "thread \($0)" }, space: String = "acme-web") -> ShepherdState {
        let space = Space(name: space, path: "/tmp/acme-web")
        var state = ShepherdState(spaces: [space])
        for i in 0..<threads {
            let pane = LeafPane(cwd: "/tmp/acme-web/\(i)", agentID: AgentID())
            let tab = Tab(spaceID: space.id, order: i, layout: .leaf(pane))
            state.tabs.append(tab)
            state.agents.append(Agent(id: pane.agentID!, name: name(i), spaceID: space.id, tabID: tab.id, paneID: pane.id, lastActiveAt: Double(i)))
        }
        return state
    }

    @Test func theDetailedListIsNewestFirstAndCappedWithTheCountOfTheRest() {
        let state = Self.state(threads: 70)
        let list = SessionServer.peerList(in: state, sender: state.agents[0].id, details: true)
        #expect(list.rows.count == SessionServer.detailedListMax && list.omitted == 20)
        #expect(list.rows.first?.name == "thread 69" && list.rows.last?.name == "thread 20", "newest first, the oldest left out")
        #expect(list.rows.map(\.lastActiveAt) == list.rows.compactMap(\.lastActiveAt).sorted(by: >).map { Optional($0) })
    }

    @Test func thePlainListIsEveryThreadAsItWas() {
        let state = Self.state(threads: 70, name: { _ in Self.nasty })
        let list = SessionServer.peerList(in: state, sender: state.agents[0].id, details: false)
        #expect(list.rows.count == 70 && list.omitted == 0)
        #expect(list.rows.allSatisfy { $0.name == Self.nasty }, "unchanged on purpose: the default reply is what nightly sends")
        #expect(SessionServer.peerInfos(in: state, sender: state.agents[0].id) == list.rows)
    }

    @Test func everyTextOfTheDetailedListIsOneShortLine() throws {
        let state = Self.state(threads: 2, name: { _ in Self.nasty }, space: Self.nasty)
        for row in SessionServer.peerList(in: state, sender: state.agents[0].id, details: true).rows {
            for text in [row.name, row.space ?? "", row.cwd] {
                #expect(!text.contains { $0.isNewline || $0 == "\t" || $0 == "\u{1B}" || $0 == "\u{0}" || $0 == "\u{202E}" }, "\(text.prefix(40))")
                #expect(text.count <= 240)
            }
            #expect(row.name.count <= 120 && row.space?.count ?? 0 <= 120)
            #expect(row.name.hasPrefix("line one line two [31mred"))
        }
    }

    @Test func aLabelIsOneLineWithNoControlCharacters() {
        #expect("a\r\nb\u{85}c\u{2028}d  e".listLabel() == "a b c d e")
        #expect("x\u{1B}[0m\u{7}y".listLabel() == "x[0my")
        #expect("short".listLabel() == "short")
        #expect(String(repeating: "é", count: 500).listLabel(limit: 10) == String(repeating: "é", count: 9) + "…")
    }

    @Test func aRecordFromBeforeTitleGivenReadsAsTaskTitled() throws {
        var record = FleetDispatchRecord(parentHostID: UUID(), parentHostName: "Mac", title: "Fix it", titleGiven: true, task: "t", repoKey: "k", createdAt: 1)
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        #expect(object["titleGiven"] as? Bool == true)
        object["titleGiven"] = nil
        record = try JSONDecoder().decode(FleetDispatchRecord.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(record.titleGiven == false)
        record.titleGiven = false
        #expect(try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) is [String: Any])
        #expect((try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])?["titleGiven"] == nil)
    }
}
