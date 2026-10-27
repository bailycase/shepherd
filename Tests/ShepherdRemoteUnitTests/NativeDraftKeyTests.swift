import Foundation
import Testing
import ShepherdCore
import ShepherdRemote

@Suite("Device draft keys")
struct NativeDraftKeyTests {
    @Test func draftsAndImageNoticesStayWithTheirHostAndAgent() {
        let first = UUID(), second = UUID()
        let a = AgentID(rawValue: "a"), b = AgentID(rawValue: "b")
        let key = NativeDraftKey.text(host: first, agent: a)
        #expect(key == NativeDraftKey.text(host: first, agent: a))
        #expect(key != NativeDraftKey.text(host: second, agent: a))
        #expect(key != NativeDraftKey.text(host: first, agent: b))
        #expect(key != NativeDraftKey.images(host: first, agent: a))
        #expect(key.hasPrefix(NativeDraftKey.prefix(host: first)))
        #expect(!key.hasPrefix(NativeDraftKey.prefix(host: second)))
    }
}
