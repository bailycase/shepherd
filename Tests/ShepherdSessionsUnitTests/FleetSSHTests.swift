import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdSessions

/// What an SSH find accepts to run and how it reads what comes back. Running ssh itself is the integration suite's.
@Suite("Fleet SSH find")
struct FleetSSHTests {
    static let found = FleetWhere(hostID: UUID(), name: "Mac mini", app: "Shepherd Nightly", build: "1.9", port: 7434,
                                  routes: [FleetReportedRoute(host: "192.168.20.14", kind: .lan)])

    @Test(arguments: ["me@mini.example.internal", "mini.example.internal", "mini", "me@192.168.20.14", "me@[fe80::1%en0]", "dev.user+tag@mini-2.local", "mini:22"])
    func aTargetIsUserAtHostOrAnAlias(_ target: String) {
        #expect(FleetSSHFinder.isTarget(target))
    }

    /// A target is an argument to ssh: nothing that is an option, a second argument, or a shell word gets through.
    @Test(arguments: ["", "-oProxyCommand=evil", "-J", "me@mini; rm -rf /", "me@mini extra", "me@@mini", "@mini", "me@", "me@mini\n", "$(whoami)@mini", "me@`id`", "me@mini|cat", "é@mini", String(repeating: "a", count: 400)])
    func anythingElseIsRefusedBeforeSSHRuns(_ target: String) {
        #expect(!FleetSSHFinder.isTarget(target))
    }

    @Test func theTypedHostIsAWayToTheMacToo() {
        #expect(FleetSSHFinder.host(of: "me@mini.example.internal") == "mini.example.internal")
        #expect(FleetSSHFinder.host(of: "mini") == "mini")
        #expect(FleetSSHFinder.host(of: "me@[fe80::1%en0]") == nil, "bracketed hosts aren't a route as typed")
    }

    @Test func theRemoteCommandHoldsNoSingleQuoteAndOnlyRunsTheInstalledCLI() {
        let command = FleetSSHFinder.remoteCommand(appName: "Shepherd Nightly")
        #expect(command.hasPrefix("/bin/sh -c '") && command.hasSuffix("'"))
        let script = command.dropFirst("/bin/sh -c '".count).dropLast()
        #expect(!script.contains("'"), "the script sits in one pair of quotes")
        #expect(script.contains("\"/Applications/Shepherd Nightly.app\"") && script.contains("$HOME/Applications/Shepherd Nightly.app"))
        #expect(script.contains("shepherd-cli\" fleet-where"))
        // It reads: nothing in it writes, deletes, or opens a connection of its own.
        for word in ["rm ", "mv ", "cp ", ">>", "curl", "nc ", "tee"] { #expect(!script.contains(word), "\(word)") }
    }

    @Test func anAnswerIsReadFromAZeroExit() throws {
        #expect(try FleetSSHFinder.interpret(status: 0, output: Data(Self.found.line().utf8), errors: "", target: "me@mini") == Self.found)
    }

    @Test(arguments: [
        (127, "shepherd-not-installed\n", FleetSSHFinder.Failure.notInstalled),
        (1, "shepherd: unknown arguments: fleet-where\nUsage: shepherd --import herdr\n", .notInstalled),
        (FleetWhereCommand.notRunningStatus, "shepherd: Shepherd isn't running\n", .notRunning),
        (FleetWhereCommand.notServingStatus, "shepherd: Shepherd isn't serving\n", .notServing),
        (2, "something else", .unreadable),
    ])
    func eachExitSaysWhatIsWrong(_ status: Int32, _ errors: String, _ expected: FleetSSHFinder.Failure) {
        #expect(throws: expected) { try FleetSSHFinder.interpret(status: status, output: Data(), errors: errors, target: "me@mini") }
    }

    @Test func aZeroExitThatIsNotShepherdsAnswerIsUnreadable() {
        #expect(throws: FleetSSHFinder.Failure.unreadable) { try FleetSSHFinder.interpret(status: 0, output: Data("hello\n".utf8), errors: "", target: "me@mini") }
    }

    @Test(arguments: [
        ("me@mini: Permission denied (publickey,password).", "ssh was refused"),
        ("Host key verification failed.", "doesn't trust that Mac's host key"),
        ("@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@", "doesn't trust that Mac's host key"),
        ("ssh: Could not resolve hostname mini: nodename nor servname provided", "No Mac is called mini"),
        ("ssh: connect to host mini port 22: Connection refused", "refused the connection"),
        ("ssh: connect to host mini port 22: Operation timed out", "Couldn't reach mini over ssh"),
        ("ssh: connect to host mini port 22: No route to host", "Couldn't reach mini over ssh"),
        ("kex_exchange_identification: read: Connection reset", "ssh couldn't connect: kex_exchange_identification"),
        ("", "ssh couldn't connect."),
    ])
    func sshsComplaintBecomesASentence(_ errors: String, _ contains: String) throws {
        do {
            _ = try FleetSSHFinder.interpret(status: 255, output: Data(), errors: errors, target: "me@mini")
            Issue.record("a failed ssh was read as an answer")
        } catch let FleetSSHFinder.Failure.connection(message) {
            #expect(message.contains(contains), "\(message)")
        }
    }

    @Test func everyFailureHasASentenceForThePerson() {
        let all: [FleetSSHFinder.Failure] = [.badTarget, .noSSH, .timedOut, .connection("x"), .notInstalled, .notRunning, .notServing, .unreadable]
        for failure in all { #expect(failure.message.count > 10 && failure.message.hasSuffix(".") || failure == .connection("x")) }
    }
}
