import Foundation

/// `Resources/stub-pi.py`: a scripted `pi --mode rpc` for integration tests (no network, no
/// model). Run it as `["python3", StubPi.path]`; `STUB_PI_LOG` in the env records its stdin.
public enum StubPi {
    public static var path: String {
        Bundle.module.url(forResource: "stub-pi", withExtension: "py")!.path
    }

    public static var command: [String] { ["python3", path] }

    /// What the stub engine answers to `pi --list-models`.
    public static let modelListing = """
    provider   model                      context  max-out  thinking  images
    anthropic  claude-opus-4-5            200K     64K      yes       yes
    anthropic  claude-sonnet-4-5          1M       64K      yes       yes
    anthropic  claude-haiku-4-5           200K     64K      yes       yes
    openai     gpt-5                      400K     128K     yes       yes
    google     gemini-2.5-pro             1M       64K      yes       yes
    """

    private static let installed = Locked(false)

    /// Installs the stub as the engine every app-level launch starts (`TestProcess.piEngine`,
    /// which `SHEPHERD_PI_ENGINE` names), answering `--list-models` with `modelListing`, for code
    /// that launches pi the way the app does (`PiLaunch`). It only writes a file into
    /// `TestProcess.binDirectory` and stays for the rest of the process: every later launch of
    /// the engine is the stub. A bare `pi` on PATH still refuses to run.
    public static func installAsEngine() throws {
        try installed.withValue { installed in
            guard !installed else { return }
            let bin = TestProcess.binDirectory
            let listing = bin.appendingPathComponent("pi-models.txt")
            try Data((modelListing + "\n").utf8).write(to: listing)
            let script = """
            #!/bin/sh
            if [ "$1" = "--list-models" ]; then cat '\(listing.path)'; exit 0; fi
            exec /usr/bin/env python3 '\(path)' "$@"

            """
            // Written aside and renamed, so a concurrent shell never finds a half-written or
            // non-executable engine.
            let staged = bin.appendingPathComponent(".pi-\(UUID().uuidString)")
            try Data(script.utf8).write(to: staged)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
            guard rename(staged.path, TestProcess.piEngine.path) == 0 else {
                throw CommandFailure("rename \(staged.lastPathComponent) pi-engine", String(cString: strerror(errno)))
            }
            installed = true
        }
    }
}
