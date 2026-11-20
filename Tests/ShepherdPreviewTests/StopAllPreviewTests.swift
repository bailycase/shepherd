import SwiftUI
import ShepherdRemote
import ShepherdTestSupport
import ShepherdUI
import Testing
@testable import ShepherdApp

/// Stop all working threads: the confirm (seven working threads, so its list ends in "and 2 more") and the result
/// it ends in, in light and dark. Made-up thread names. The Agent menu's item is a native menu a preview can't open;
/// `StopAllMenuTests` checks only the command's title and enablement, so the native menu item itself is not covered
/// (verify by hand in the Dev app).
@Suite("Stop all previews", .serialized, .mainActorExclusive, .enabled(if: Preview.enabled && !Preview.liveModel, "set SHEPHERD_PREVIEW_DIR (without SHEPHERD_LIVE_MODEL)"))
@MainActor
struct StopAllPreviewTests {
    static let size = CGSize(width: 560, height: 520)
    static let names = ["Speed up checkout CI", "Fix flaky cart test", "Migrate invoices to v2", "Restyle the settings page",
                        "Triage new Sentry issues", "Plan acme-web search", "Cache the product feed"]

    static var targets: [StopAllWorking.Target] {
        let host = UUID()
        return names.enumerated().map { .init(host: host, agent: .init(rawValue: "agent-\($0.offset)"), name: $0.element) }
    }

    @Test func theConfirmNamesTheCountAndTheFirstFewThreads() async throws {
        let targets = Self.targets
        try await Preview.renderMatrix("stop-all-confirm", size: Self.size) {
            StopWorkingDialog(targets: targets, stop: {}, cancel: {}).shPopover().frame(width: Self.size.width, height: Self.size.height)
                .background(Color.sh.bgWindow)
        }
    }

    @Test func theResultSaysWhatStoppedAndWhatFailedAndWhy() async throws {
        let outcome = StopAllWorking.Outcome(stopped: 5, alreadyStopped: 1, failures: [
            .init(name: "Restyle the settings page", message: "The session changed. Refresh the thread and try again.")])
        try await Preview.renderMatrix("stop-all-result", size: Self.size) {
            ActionErrorDialog(error: ActionError(title: outcome.title, message: outcome.message), dismiss: {}).shPopover()
                .frame(width: Self.size.width, height: Self.size.height).background(Color.sh.bgWindow)
        }
    }
}
