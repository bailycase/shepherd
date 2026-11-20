import Foundation
@testable import ShepherdProtocol
import Testing

struct MessageSpecTests {
    @Test func everyKindHasARow() {
        for kind in RemoteRequest.Kind.allCases {
            #expect(MessageSpec.table[kind] != nil, "MessageSpec.table needs a row for \(kind)")
        }
    }

    /// A kind with no row has no spec, so the host refuses it instead of serving it as `authenticated`.
    @Test func missingRowFailsClosed() {
        #expect(MessageSpec.spec(for: .stateFetch, in: [:]) == nil)
        #expect(MessageSpec.spec(for: .stateFetch) != nil)
    }

    /// `kind` is what the codec writes as `type`, so a spec row reaches the request it names.
    @Test func kindIsTheWireType() throws {
        var seen: Set<RemoteRequest.Kind> = []
        for request in RemoteRequestTests.wireSamples + RemoteRequestTests.roundTripOnly {
            let object = try JSONSerialization.jsonObject(with: NDJSON.encode(request)) as? [String: Any]
            #expect(object?["type"] as? String == request.kind.rawValue)
            seen.insert(request.kind)
        }
        #expect(seen == Set(RemoteRequest.Kind.allCases))
    }

    @Test func transcriptSnapshotUsesTheAuthenticatedNativeThreadRow() throws {
        let request = RemoteRequest.nativeThread(id: 1, agentID: .init(rawValue: "agent"), request: .transcriptSnapshot())
        #expect(request.kind == .nativeThread)
        let spec = try #require(MessageSpec.spec(for: request.kind))
        #expect(spec.access == .authenticated)
        // The route checks the host's transcript offer only for this payload, not for all nativeThread requests.
        #expect(spec.requires == nil)
    }

    @Test func authorizationClassOfTheRefusalFamilies() {
        func access(_ kind: RemoteRequest.Kind) -> MessageSpec.Access? { MessageSpec.spec(for: kind)?.access }
        for kind in [RemoteRequest.Kind.fleetIdentify, .fleetPair, .fleetPairDevice] { #expect(access(kind) == .beforeHello) }
        #expect(access(.hello) == .hello)
        #expect(access(.fleetPeerAnswer) == .fleetPeer(refusal: "Only a Mac in the fleet answers a call."))
        for kind in [RemoteRequest.Kind.drain, .hostUpdateGate, .focusThread, .projectExecutors, .startThread, .spaceAction, .projectRequest] {
            guard case .localOnly = access(kind) else { Issue.record("\(kind) is local only"); continue }
        }
        // Everything else is served to any authenticated connection.
        let special: Set<RemoteRequest.Kind> = [.fleetIdentify, .fleetPair, .fleetPairDevice, .hello, .fleetPeerAnswer,
                                                .drain, .hostUpdateGate, .focusThread, .projectExecutors, .startThread, .spaceAction, .projectRequest]
        for kind in Set(RemoteRequest.Kind.allCases).subtracting(special) { #expect(access(kind) == .authenticated) }
    }

    /// The host's own capability refusals today: push, thread subscribe, fleet digest, and logical projects.
    /// Host settings are not here: the host does not check `HostSettingChange.capability`.
    @Test func capabilityRequirementsOfTheRefusalFamilies() {
        func requirement(_ kind: RemoteRequest.Kind) -> MessageSpec.Requirement? { MessageSpec.spec(for: kind)?.requires }
        #expect(requirement(.pushRegistration)?.capability.rawValue == "push.notifications.v1")
        #expect(requirement(.pushUnregister)?.capability.rawValue == "push.notifications.v1")
        #expect(requirement(.nativeThreadSubscribe)?.capability.rawValue == "native.revisions.v1")
        #expect(requirement(.fleetDigest)?.capability.rawValue == "native.fleetDigest.v1")
        for kind in [RemoteRequest.Kind.pushRegistration, .pushUnregister, .nativeThreadSubscribe, .fleetDigest] {
            #expect(requirement(kind)?.negotiated == true)
        }
        #expect(requirement(.logicalProjects)?.capability.rawValue == "logicalProjects.v1")
        #expect(requirement(.logicalProjects)?.negotiated == false)
        #expect(requirement(.hostSettings) == nil)
    }
}
