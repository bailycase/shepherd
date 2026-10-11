import Foundation
import ShepherdTestKit
import Testing
@testable import ShepherdApp

@Suite("Remote host destination bindings")
@MainActor
struct RemoteHostBindingTests {
    @Test func olderHostConfigurationsDecodeWithTheSameBindingOnEveryLoad() throws {
        let data = Data("""
        {"id":"00000000-0000-0000-0000-000000000001","name":"Builder",\
        "host":"builder.test","port":7433,"token":"fixture"}
        """.utf8)
        let first = try JSONDecoder().decode(RemoteHostStore.HostConfig.self, from: data)
        let again = try JSONDecoder().decode(RemoteHostStore.HostConfig.self, from: data)
        #expect(first.bindingID == first.id)
        #expect(again.bindingID == first.bindingID)
        let saved = try JSONEncoder().encode(first)
        #expect(try JSONDecoder().decode(RemoteHostStore.HostConfig.self, from: saved) == first)
    }

    @Test(arguments: ["address", "port", "credential"])
    func changingADestinationInvalidatesItsBindingAcrossReloads(field: String) throws {
        let defaults = ScratchDefaults()
        let store = RemoteHostStore(defaults: defaults, connects: false)
        store.addHost(name: "Builder", host: "builder.test", port: 7433, token: "fixture")
        let before = try #require(store.hosts.first)
        store.updateHost(id: before.id, name: before.name,
                         host: field == "address" ? "replacement.test" : before.host,
                         port: field == "port" ? 7434 : before.port,
                         token: field == "credential" ? "replacement-fixture" : before.token)
        let after = try #require(store.hosts.first)
        #expect(after.id == before.id)
        #expect(after.bindingID != before.bindingID)
        let reloaded = RemoteHostStore(defaults: defaults, connects: false)
        #expect(reloaded.hosts.first?.bindingID == after.bindingID)
    }

    @Test func renamingOrReconnectingAHostPreservesItsBinding() throws {
        let defaults = ScratchDefaults()
        let store = RemoteHostStore(defaults: defaults, connects: false)
        store.addHost(name: "Builder", host: "builder.test", port: 7433, token: "fixture")
        let original = try #require(store.hosts.first)
        store.updateHost(id: original.id, name: "Studio", host: original.host,
                         port: original.port, token: original.token)
        store.reconnect(id: original.id)
        #expect(store.hosts.first?.bindingID == original.bindingID)
        let reloaded = RemoteHostStore(defaults: defaults, connects: false)
        #expect(reloaded.hosts.first?.bindingID == original.bindingID)
        #expect(reloaded.hosts.first?.name == "Studio")
    }
}
