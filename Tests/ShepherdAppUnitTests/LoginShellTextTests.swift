import Foundation
import Testing
import ShepherdSessions

/// The text a failed login-shell step reports, and how values are quoted into a script.
@Suite("Login shell text")
struct LoginShellTextTests {
    /// A failure's detail is stderr, else stdout, else the exit status.
    @Test(arguments: [
        (LoginShell.Output(status: 128, stdout: "out", stderr: " err \n"), "err"),
        (LoginShell.Output(status: 128, stdout: " out \n", stderr: ""), "out"),
        (LoginShell.Output(status: 128, stdout: "", stderr: ""), "exit 128"),
    ])
    func failureDetailPrefersStderrThenStdoutThenStatus(output: LoginShell.Output, detail: String) {
        #expect(LoginShell.failureDetail(output) == detail)
    }

    /// Real git and gh failures: the first line, which is all the sheet shows before its
    /// tooltip, names the problem instead of git's `To <remote>` header.
    @Test(arguments: [
        ("""
        To github.com:ada/shepherd.git
         ! [rejected]        feat/x -> feat/x (non-fast-forward)
        error: failed to push some refs to 'github.com:ada/shepherd.git'
        hint: Updates were rejected because the tip of your current branch is behind
        """, "! [rejected] feat/x -> feat/x (non-fast-forward)"),
        ("""
        To github.com:ada/shepherd.git
         ! [remote rejected] feat/x -> feat/x (protected branch hook declined)
        error: failed to push some refs to 'github.com:ada/shepherd.git'
        """, "! [remote rejected] feat/x -> feat/x (protected branch hook declined)"),
        ("""
        ERROR: Permission to ada/shepherd.git denied to someone.
        fatal: Could not read from remote repository.
        """, "ERROR: Permission to ada/shepherd.git denied to someone."),
        ("pull request create failed: GraphQL: No commits between main and feat/x (createPullRequest)",
         "pull request create failed: GraphQL: No commits between main and feat/x (createPullRequest)"),
    ])
    func aFailureLeadsWithTheLineThatNamesTheProblem(stderr: String, first: String) {
        let detail = LoginShell.failureDetail(.init(status: 1, stdout: "", stderr: stderr))
        #expect(detail.split(separator: "\n").first.map(String.init) == first)
        let words = { (text: Substring) in text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        #expect(Set(detail.split(separator: "\n").map(words)) == Set(stderr.split(separator: "\n").map(words)),
                "the tooltip keeps every line")
    }

    @Test(arguments: [
        ("plain", "'plain'"),
        ("fix 'the' thing", #"'fix '\''the'\'' thing'"#),
        ("", "''"),
        ("$HOME; rm -rf /", "'$HOME; rm -rf /'"),
    ])
    func valuesAreSingleQuotedWithEmbeddedQuotesEscaped(value: String, quoted: String) {
        #expect(shellQuoted(value) == quoted)
    }
}
