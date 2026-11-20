import Foundation
import Testing
import ShepherdProtocol
import ShepherdRemote

@MainActor
struct ClientSpaceMCPSignInTests {
    @Test func aHostBlipAfterAuthorizationKeepsTheSameRunAndRedirect() async throws {
        let id = UUID(), redirect = "http://127.0.0.1:9876/callback?code=fixture"
        var requests: [ProjectMCPAction] = []
        var browserOpens = 0
        try await ClientSpaceMCPSignIn.run(server: "acme-issues", send: { action in
            requests.append(action)
            switch action {
            case .login:
                return .init(id: id, phase: .waiting, authorizationURL: "https://login.example.invalid/authorize")
            case .complete(let run, let answer) where run == id && answer == redirect:
                if requests.count == 2 { throw RemoteHostClientError.disconnected }
                return .init(id: id, phase: .done)
            default: throw ProjectFileError("unexpected", "Unexpected request")
            }
        }, authorize: { _, _ in
            browserOpens += 1
            return redirect
        }, wait: {})
        let complete = ProjectMCPAction.complete(id: id, redirectURL: redirect)
        #expect(requests == [.login(server: "acme-issues"), complete, complete])
        #expect(browserOpens == 1)
    }

    @Test func cancellingTheBrowserCancelsTheHostRun() async {
        let id = UUID()
        var requests: [ProjectMCPAction] = []
        await #expect(throws: CancellationError.self) {
            try await ClientSpaceMCPSignIn.run(server: "acme-issues", send: { action in
                requests.append(action)
                return .init(id: id, phase: .waiting, authorizationURL: "https://login.example.invalid/authorize")
            }, authorize: { _, _ in throw CancellationError() }, wait: {})
        }
        #expect(requests == [.login(server: "acme-issues"), .cancel(id: id)])
    }
}
