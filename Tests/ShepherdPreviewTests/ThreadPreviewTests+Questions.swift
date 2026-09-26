import AppKit
import Foundation
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// QuestionAnswered and QuestionStates › QuestionRecord on the Mac, in light and dark:
///
///     SHEPHERD_PREVIEW_DIR=/tmp/previews swift test --filter ThreadPreviewTests
extension ThreadPreviewTests {
    /// QuestionAnswered: where pi asked, the thread keeps "Agent asked:" and the question, then
    /// the answer as the user's bubble; pi's turn carries on under it. At rest the answer's time
    /// waits for the pointer, as every bubble's does.
    @Test func threadQuestionAnswered() async throws {
        let fixture = ThreadFixture(QuestionThreads.answered)
        defer { fixture.store.stop() }
        try await Preview.render("thread-question-answered", size: CGSize(width: 1180, height: 900), ready: {
            fixture.store.ready && !fixture.store.rows.isEmpty
        }) {
            fixture.thread(title: "Deploy media stack")
        }
    }

    /// The same turn with the pointer over it: "2:51 PM · answered" under the answer.
    @Test func threadQuestionAnsweredHovered() async throws {
        let fixture = ThreadFixture(QuestionThreads.answered)
        defer { fixture.store.stop() }
        let store = fixture.store
        let size = CGSize(width: 1180, height: 820)
        try await Preview.render("thread-question-answered-hovered", size: size, ready: { store.ready && !store.rows.isEmpty }) {
            QuestionThreadRows(store: store)
                .frame(width: size.width, height: size.height)
                .task { await store.run(request: fixture.request) }
        }
    }

    /// The record's states: an option chosen, Yes, a typed answer, and a question nobody
    /// answered (dismissed, or its timeout passed), which keeps its line alone.
    @Test func questionRecordStates() async throws {
        let size = CGSize(width: 760, height: 520)
        try await Preview.render("question-record-states", size: size) {
            VStack(alignment: .leading, spacing: 28) {
                NWQuestionRecord(question: "How should I handle Horizon’s uncommitted edits?",
                                 title: "Compare, keep what’s unique, then go through GitHub", answered: true,
                                 timestamp: "2:51 PM · answered", revealed: true)
                NWQuestionRecord(question: "Clear the session?", title: "Yes", answered: true, timestamp: "2:52 PM · answered",
                                 revealed: true)
                NWQuestionRecord(question: "Name for the release branch?", text: "release/2026-09", answered: true,
                                 timestamp: "2:53 PM · answered", revealed: true)
                NWQuestionRecord(question: "Which host should get the new Traefik config?", answered: false)
                Spacer(minLength: 0)
            }
            .padding(32)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color.nw.bgWindow)
        }
    }
}

/// The thread's rows with the pointer over the reply that holds the record.
private struct QuestionThreadRows: View {
    let store: NativeThreadStore

    var body: some View {
        let rows = store.rows
        VStack(alignment: .leading, spacing: AppLayout.turnSpacing) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if row.isUser {
                    UserTurn(turn: row.turn)
                } else if let presentation = row.presentation {
                    AgentTurn(presentation: presentation, live: row.live, startedAt: row.startedAt, retry: {}, review: { _ in },
                              hover: MessageHover(hovering: index == rows.count - 1))
                }
            }
        }
        .frame(maxWidth: AppLayout.threadMaxWidth)
        .padding(.horizontal, AppLayout.gutter)
        .padding(.top, AppLayout.threadTop)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.nw.bgWindow)
    }
}

/// QuestionAnswered's thread: the deploy, what pi found on Horizon, the question it asked and
/// the answer, then the work that followed. (A question asked from a tool also keeps that
/// tool's own activity line; the board draws one asked by an extension.)
@MainActor
enum QuestionThreads {
    typealias A = ActivityThreads

    static var answered: NativeThreadSnapshot {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: Date())
        let t0 = today.addingTimeInterval((14 * 60 + 46) * 60).timeIntervalSince1970 * 1000
        let asked = t0 + 20_000
        let answered = today.addingTimeInterval((14 * 60 + 51) * 60).timeIntervalSince1970 * 1000
        let found = """
        Before deploying I looked at Horizon’s checkout. It isn’t clean, so I stopped before pulling anything:

        - `master` on Horizon is 50 commits behind GitHub.
        - Horizon is on `chore/remove-homarr`, which split off from master.
        - 11 files are uncommitted: the Homarr removal, media support, routing, and an encrypted secret.
        - GitHub already has a merged PR that removes Homarr.
        """
        let messages = [
            A.user("u1", "Deploy the new media stack to Horizon.", at: t0),
            A.tool("s1", "bash", ["command": "ssh horizon git status"], output: "On branch chore/remove-homarr", start: t0 + 1_000, end: t0 + 5_000),
            A.tool("s2", "bash", ["command": "ssh horizon git fetch"], output: "", start: t0 + 5_000, end: t0 + 9_000),
            A.tool("s3", "bash", ["command": "ssh horizon git log --oneline master..origin/master | wc -l"], output: "50",
                   start: t0 + 9_000, end: t0 + 14_000),
            A.assistant("a1", found, at: t0 + 15_000),
            NativeThreadMessage(entryID: "q:ask", role: "question", blocks: [], timestamp: answered,
                                question: NativeQuestionRecord(kind: .select, question: "How should I handle Horizon’s uncommitted edits?",
                                                               answer: "Compare, keep what’s unique, then go through GitHub (Recommended)\nNew branch and PR for anything not merged.",
                                                               outcome: .answered, askedAt: asked)),
            A.tool("s4", "bash", ["command": "ssh horizon git diff --stat origin/master"], output: "11 files changed",
                   start: answered + 2_000, end: answered + 20_000),
            A.tool("s5", "bash", ["command": "ssh horizon git push origin HEAD:horizon/media-support"], output: "",
                   start: answered + 20_000, end: answered + 41_000),
            A.assistant("a2", "Four of the eleven files were already in the merged Homarr PR. The other seven are on `horizon/media-support`. The encrypted secret stays on Horizon.",
                        at: answered + 43_000),
        ]
        return A.snapshot(messages)
    }
}
