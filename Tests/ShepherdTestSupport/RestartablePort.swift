import Darwin
import Foundation
import ShepherdSessions
import ShepherdTestKit

/// A remote-listener port a scratch host can get back after a restart.
///
/// A host that binds port 0 gets an ephemeral port (49152 and up). Once it stops, that number is
/// free, and any other test in the process that binds port 0 can be handed it before the restarted
/// host asks for it again ("bind failed: Address already in use"). A real host's port is fixed, so
/// the restarting tests keep it fixed too: `listen` picks it below the ephemeral range, where
/// binding port 0 never lands, and hands each number out once per process.
///
/// A restart asks for the number it had. The kernel can still hold a stopped listener's port for a
/// moment on a loaded machine (the descriptor is gone from this process before the socket is), so
/// the restart waits for the bind to succeed, as a host relaunching on its fixed port would retry.
public enum RestartablePort {
    private static let range: ClosedRange<UInt16> = 20_000...48_999
    private static let taken = Locked(Set<UInt16>())

    private static func inUse(_ error: Error) -> Bool {
        if case SessionServerError.system(let call, let code) = error { return call == "bind" && code == EADDRINUSE }
        return false
    }

    /// Starts a listener with `start` and returns the port it bound. `port` 0 chooses a number
    /// nobody else in this process has; a restart passes the number it had, which stays reserved.
    /// A number another process already holds is skipped (a new one) or waited for (a restart).
    public static func listen(_ port: UInt16 = 0, _ start: (UInt16) throws -> UInt16) async throws -> UInt16 {
        if port != 0 {
            try await eventually("port \(port) to be free to bind again") {
                do { _ = try start(port); return true } catch where inUse(error) { return false }
            }
            return port
        }
        var lastError: Error = SessionServerError.system(call: "bind", errno: EADDRINUSE)
        for _ in 0..<100 {
            let candidate = taken.withValue { used -> UInt16 in
                var number = UInt16.random(in: range)
                while used.contains(number) { number = UInt16.random(in: range) }
                used.insert(number)
                return number
            }
            do { return try start(candidate) } catch where inUse(error) { lastError = error }
        }
        throw lastError
    }
}
