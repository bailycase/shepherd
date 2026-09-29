import Foundation
import Testing
@testable import ShepherdSessions

@Suite struct CLIProxyAPITests {
    @Test(arguments: [
        ("proxy.example.com", "https://proxy.example.com/v1"),
        (" http://localhost:8317/ ", "http://localhost:8317/v1"),
        ("https://PROXY.example.com/custom/v1/", "https://proxy.example.com/custom/v1"),
        ("http://[::1]:8317/v1", "http://[::1]:8317/v1")
    ])
    func serverAddressesNormalizeWithoutChangingExplicitPaths(input: String, expected: String) throws {
        #expect(try CLIProxyAPIStore.baseURL(input).absoluteString == expected)
    }

    @Test(arguments: ["", "ftp://proxy.example.com", "https://key@proxy.example.com", "https://proxy.example.com?key=secret",
                      "https://proxy.example.com/#secret", "https://proxy.example.com:99999", "https://bad host"])
    func serverAddressesRejectCredentialsAndNonHTTPDestinations(input: String) {
        #expect(throws: CLIProxyAPIStore.Failure.self) { try CLIProxyAPIStore.baseURL(input) }
    }

    @Test func discoveryPreservesRouteIdentityAndRejectsAnEmptyOrBrokenCatalog() throws {
        let data = Data(#"{"data":[{"id":"~anthropic/claude-sonnet","owned_by":"anthropic"},{"id":"gpt-model"},{"id":"gpt-model"}]}"#.utf8)
        let models = try CLIProxyAPIStore.models(data)
        #expect(models.map(\.id) == ["gpt-model", "~anthropic/claude-sonnet"])
        #expect(models.last?.owned_by == "anthropic")
        for text in [#"{"data":[]}"#, #"{"data":[{"id":""}]}"#, #"{"data":[{}]}"#, #"{"error":"bad key"}"#] {
            #expect(throws: CLIProxyAPIStore.Failure.self) { try CLIProxyAPIStore.models(Data(text.utf8)) }
        }
    }
}
