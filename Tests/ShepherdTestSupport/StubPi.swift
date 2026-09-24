import Foundation

/// `Resources/stub-pi.py`: a scripted `pi --mode rpc` for integration tests (no network, no
/// model). Run it as `["python3", StubPi.path]`; `STUB_PI_LOG` in the env records its stdin.
public enum StubPi {
    public static var path: String {
        Bundle.module.url(forResource: "stub-pi", withExtension: "py")!.path
    }

    public static var command: [String] { ["python3", path] }

    /// What the stub on PATH answers to `pi --list-models`.
    public static let modelListing = """
    provider   model                      context  max-out  thinking  images
    anthropic  claude-opus-4-5            200K     64K      yes       yes
    anthropic  claude-sonnet-4-5          1M       64K      yes       yes
    anthropic  claude-haiku-4-5           200K     64K      yes       yes
    openai     gpt-5                      400K     128K     yes       yes
    google     gemini-2.5-pro             1M       64K      yes       yes
    """

    private static let installed = Locked(false)

    /// Puts the stub first on PATH as `pi` (answering `--list-models` with `modelListing`), for
    /// code that launches pi the way the app does (`zsh -l -c "exec pi …"`). It only writes a file
    /// into `TestProcess.binDirectory`, which the process put on PATH when it loaded, and stays
    /// for the rest of the process: every later `pi` a test's shell runs is the stub.
    public static func installOnPath() throws {
        try installed.withValue { installed in
            guard !installed else { return }
            let bin = TestProcess.binDirectory
            let listing = bin.appendingPathComponent("pi-models.txt")
            try Data((modelListing + "\n").utf8).write(to: listing)
            let script = """
            #!/bin/sh
            if [ "$1" = "--list-models" ]; then cat '\(listing.path)'; exit 0; fi
            exec /usr/bin/env python3 '\(path)'

            """
            // Written aside and renamed, so a concurrent shell never finds a half-written or
            // non-executable `pi`.
            let staged = bin.appendingPathComponent(".pi-\(UUID().uuidString)")
            try Data(script.utf8).write(to: staged)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
            guard rename(staged.path, bin.appendingPathComponent("pi").path) == 0 else {
                throw CommandFailure("rename \(staged.lastPathComponent) pi", String(cString: strerror(errno)))
            }
            installed = true
        }
    }
}
