import Foundation
import Testing
import ShepherdCore

@Suite("Typed identifiers")
struct IdentifierTests {
    @Test func generatedIDsAreUniqueLowercaseUUIDs() throws {
        let a = AgentID(), b = AgentID()
        #expect(a != b)
        #expect(a.rawValue == a.rawValue.lowercased())
        #expect(UUID(uuidString: a.rawValue) != nil)
    }

    @Test func encodesAsABareJSONString() throws {
        let id = SpaceID(rawValue: "space-1")
        #expect(String(decoding: try JSONEncoder().encode(id), as: UTF8.self) == #""space-1""#)
        #expect(try Fixture.decode(SpaceID.self, #""space-1""#) == id)
    }

    @Test func descriptionIsTheRawValue() {
        #expect(PaneID(rawValue: "p-9").description == "p-9")
        #expect("\(TabID(rawValue: "t-1"))" == "t-1")
    }

    @Test func idsWithTheSameRawValueAreEqualAndHashTogether() {
        let set: Set<AgentID> = [AgentID(rawValue: "x"), AgentID(rawValue: "x"), AgentID(rawValue: "y")]
        #expect(set.count == 2)
    }
}
