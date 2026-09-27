import Foundation

/// `Resources/fake-pi-sdk.mjs`: pi's `ModelRuntime` as the sign-in bridge uses it, with scripted
/// providers (Anthropic and OpenAI Codex in the browser, GitHub Copilot by device code, DeepSeek by
/// key) and fake credentials. `FAKE_PI_CONTROL` names the folder a test drops `approved` into to
/// finish a device sign-in.
public enum FakePiSDK {
    public static var path: String {
        Bundle.module.url(forResource: "fake-pi-sdk", withExtension: "mjs")!.path
    }

    /// The pasted code the fake accepts, and the key it takes as working.
    public static let goodCode = "FAKE-CODE"
    public static let goodKey = "sk-fake-good-key-0001"
    /// The fake's credential values, which nothing may ever show.
    public static let secrets = ["fake-access-token-0001", "fake-refresh-token-0001"]
}
