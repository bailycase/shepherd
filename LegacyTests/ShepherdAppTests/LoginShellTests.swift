import Foundation
import Testing
@testable import ShepherdApp

@Suite("Login shell execution")
struct LoginShellTests {
    @Test func concurrentCommandsCaptureOutputAndExitStatus() async {
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<24 {
                group.addTask {
                    let output = await LoginShell.run("printf 'out-\(index)'; printf 'err-\(index)' >&2; exit 7", timeout: 2)
                    #expect(output == .init(status: 7, stdout: "out-\(index)", stderr: "err-\(index)"))
                }
            }
        }
    }

    @Test func capturesBothStreamsBeyondPipeCapacity() async {
        let output = await LoginShell.run("for ((i=0; i<4096; i++)); do printf '0123456789abcdef'; printf 'fedcba9876543210' >&2; done", timeout: 2)
        #expect(output.status == 0)
        #expect(output.stdout == String(repeating: "0123456789abcdef", count: 4096))
        #expect(output.stderr == String(repeating: "fedcba9876543210", count: 4096))
    }

    @Test func commandTimeoutReturnsTimeoutStatus() async {
        let output = await LoginShell.run("exec /bin/sleep 5", timeout: 0.1)
        #expect(output.status == 124)
    }
}
