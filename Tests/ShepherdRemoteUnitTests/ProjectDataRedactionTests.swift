import Testing
@testable import ShepherdRemote

@Suite("Project forwarded data privacy")
struct ProjectDataRedactionTests {
    @Test func forwardedCredentialsAreRemovedRatherThanPartiallyExposed() {
        let key = "sk-proj-0123456789abcdefghijklmnop"
        let value = "Header Bearer abcdefghijklmnopqrstuvwxyz, \"password\":\"very-secret-password\", https://example.invalid/?key=\(key)"
        let redacted = NativeRedaction.projectData(value)
        #expect(!redacted.contains(key) && !redacted.contains("abcdefghijklmnopqrstuvwxyz") && !redacted.contains("very-secret-password"))
        #expect(redacted.contains("[redacted]"))
        #expect(NativeRedaction.projectData("-----BEGIN PRIVATE KEY-----\nprivate bytes\n-----END PRIVATE KEY-----") == "[redacted]")
        #expect(NativeRedaction.projectData("Factual result: tests passed in /source/api_key.swift") == "Factual result: tests passed in /source/api_key.swift")
    }
}
