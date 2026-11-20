import SwiftUI
import ShepherdRemote
import ShepherdTestSupport
import ShepherdUI
import Testing
@testable import ShepherdApp

/// Stop all working threads: the confirm (seven working threads, so its list ends in "and 2 more") and the result
/// it ends in, and the Agent menu's item (a stand-in: the real one is a native menu a preview can't open, so this draws its
/// rows with the item's own title), in light and dark. Made-up thread names.
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

/// The Agent menu around Stop All Working Threads, drawn from the item's own title. Not the NSMenu.
private struct AgentMenuStandIn: View {
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row("Stop", enabled: true)
            row(StopAllWorking.menuTitle(count: count), enabled: count > 0, highlighted: count > 0)
            row("Choose Model…", enabled: true)
        }
        .padding(SH.Space.s)
        .frame(width: 280)
        .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Radius.m))
        .overlay(RoundedRectangle(cornerRadius: SH.Radius.m).strokeBorder(Color.sh.lineSubtle))
    }

    private func row(_ title: String, enabled: Bool, highlighted: Bool = false) -> some View {
        Text(title)
            .font(.sh(.ui))
            .foregroundStyle(enabled ? Color.sh.textPrimary : Color.sh.textTertiary)
            .padding(.horizontal, SH.Space.m)
            .frame(maxWidth: .infinity, minHeight: SH.Height.rowCompact, alignment: .leading)
            .background(highlighted ? Color.sh.bgSelected : .clear, in: RoundedRectangle(cornerRadius: SH.Radius.s))
    }
}

extension StopAllPreviewTests {
    @Test func theAgentMenuItemShowsTheCountAndDisablesWhenNothingIsWorking() async throws {
        let size = CGSize(width: 360, height: 280)
        try await Preview.renderMatrix("stop-all-menu-item", size: size) {
            VStack(spacing: SH.Space.l) {
                AgentMenuStandIn(count: 7)
                AgentMenuStandIn(count: 0)
            }
            .frame(width: size.width, height: size.height).background(Color.sh.bgWindow)
        }
    }
}
