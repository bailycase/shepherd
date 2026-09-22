import Foundation

/// `Resources/stub-pi.py`: a scripted `pi --mode rpc` for integration tests (no network, no
/// model). Run it as `["python3", StubPi.path]`; `STUB_PI_LOG` in the env records its stdin.
public enum StubPi {
    public static var path: String {
        Bundle.module.url(forResource: "stub-pi", withExtension: "py")!.path
    }

    public static var command: [String] { ["python3", path] }
}
