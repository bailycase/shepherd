import ShepherdUI
import SwiftUI
import Testing

/// Git sharing for designs (GitDesignPublish, -Open, -Coworker, -Changes, -Conflict, -Merge,
/// -MergeReview, DesignGitStatus): every component in each state the boards draw, light and dark
/// at text scale 1 and 1.3, on the window fill the boards draw them over.
@Suite("Git sharing previews", .serialized, .mainActorExclusive,
       .enabled(if: Preview.enabled && !Preview.liveModel, "set SHEPHERD_PREVIEW_DIR (without SHEPHERD_LIVE_MODEL) to render previews"))
@MainActor
struct GitSharingPreviewTests {
    private static let url = "git@github.com:acme/checkout-design.git"

    private static let chips: [(id: String, label: String, tone: NWGitTone)] = [
        ("local", "Share with Git", .primary), ("clean", "main · Up to date", .done), ("changed", "main · 3 changes", .primary),
        ("incoming", "main · Pull 1", .running), ("ahead", "main · Push 1", .primary), ("conflict", "main · Pull paused", .attention),
        ("resolving", "main · Merging", .running), ("merged", "main · Merge ready", .attention), ("offline", "main · Offline", .secondary),
    ]

    private func render<V: View>(_ name: String, size: CGSize, @ViewBuilder _ content: @escaping () -> V) async throws {
        try await Preview.renderMatrix("git-\(name)", size: size) {
            content().padding(NW.Space.xxl)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .background(Color.nw.bgWindow)
        }
    }

    @Test func chip() async throws {
        try await render("chip", size: CGSize(width: 260, height: 9 * 44 + 48)) {
            VStack(alignment: .trailing, spacing: NW.Space.m) {
                ForEach(Self.chips, id: \.id) { chip in
                    NWDesignGitChip(label: chip.label, tone: chip.tone, hint: "Git status for this design.", action: {})
                }
                NWDesignGitChip(label: "main · 3 changes", tone: .primary, hint: "Git status for this design.", isOpen: true, action: {})
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    @Test(arguments: ["empty", "filled", "error", "working"])
    func share(_ state: String) async throws {
        let filled = state != "empty"
        let error = state == "error" ? NWGitSheetError(title: "Repository unavailable",
                                                       detail: "Check the repository URL and your Git access, then try again. Nothing was pushed.") : nil
        try await render("share-\(state)", size: CGSize(width: 700, height: 900)) {
            NWGitShareSheet(repository: .constant(filled ? Self.url : ""), message: .constant(filled ? "Add checkout funnel design" : ""),
                            boards: 4, error: error, working: state == "working", close: {}, share: {})
        }
    }

    @Test(arguments: ["filled", "error", "working"])
    func open(_ state: String) async throws {
        let error = state == "error" ? NWGitSheetError(title: "Repository unavailable",
                                                       detail: "Check the repository URL and your Git access, then try again. Nothing was cloned.") : nil
        try await render("open-\(state)", size: CGSize(width: 640, height: 560)) {
            NWGitOpenSheet(repository: .constant(Self.url), error: error, working: state == "working", close: {}, clone: {})
        }
    }

    private static let files: [NWGitPanelState.File] = [
        .init(id: "A.dc.html", letter: "M", label: "Funnel first"),
        .init(id: "A-phone.dc.html", letter: "M", label: "Phone"),
        .init(id: "canvas.json", letter: "M", label: "Board placement"),
    ]

    private static func changes(merge: Bool = false, canCommit: Bool = true, canPush: Bool = true) -> NWGitPanelState.Changes {
        .init(title: merge ? "Review merge" : "Local changes",
              note: merge ? "Both commits are preserved. Review before committing." : "Saved on this Mac. Not shared yet.",
              files: files, selected: merge ? "A-phone.dc.html" : "A.dc.html",
              preview: merge
                  ? .init(title: "A · phone · merged label", beforeTitle: "Your version", before: "Checkout started · 12,904",
                          afterTitle: "Merge result", after: "Checkout · 12,904")
                  : .init(title: "A · Funnel first · label change", beforeTitle: "Committed", before: "Checkout started",
                          afterTitle: "Working copy", after: "Checkout started · 12,904"),
              localTitle: merge ? "Commit merge locally" : "Commit locally", pushTitle: merge ? "Commit merge & push" : "Commit & push",
              canCommit: canCommit, canPush: canPush)
    }

    private static func panel(_ mode: String) -> (NWGitPanelState, String) {
        let repo = "acme/checkout-design"
        let message = "Show absolute counts in the checkout funnel"
        switch mode {
        case "incoming":
            return (.init(branch: "main", repository: repo, sync: "1 commit to pull · no local changes", syncTone: .running, canPull: true,
                          pullHint: "Pull the new commit and reload the design", notice: nil, changes: nil,
                          incoming: .init(subject: "Clarify phone step labels", author: "Sam Nguyen", hash: "6bc29f1", files: ["A-phone.dc.html"]),
                          pushTitle: nil, working: false), "")
        case "offline":
            return (.init(branch: "main", repository: repo, sync: "Offline · last checked 10:42", syncTone: .attention, canPull: false,
                          pullHint: "Commit local changes before pulling",
                          notice: .init(title: "You can keep working offline", text: "Save or commit locally. Reconnect before pulling or pushing.", tone: .attention),
                          changes: changes(canPush: false), incoming: nil, pushTitle: nil, working: false), message)
        case "drawing":
            return (.init(branch: "main", repository: repo, sync: "Remote is up to date", syncTone: .done, canPull: false,
                          pullHint: "Wait for the design agent to finish this turn",
                          notice: .init(title: "Design agent is drawing",
                                        text: "Commit and pull are paused until the current turn finishes, so Git doesn't capture a half-drawn design.", tone: .attention),
                          changes: changes(canCommit: false, canPush: false), incoming: nil, pushTitle: nil, working: false), message)
        case "push-failed":
            return (.init(branch: "main", repository: repo, sync: "1 local commit · push failed", syncTone: .attention, canPull: false,
                          pullHint: "Commit local changes before pulling",
                          notice: .init(title: "Your commit is safe on this Mac",
                                        text: "The remote could not be reached. Check your connection and Git access, then try pushing again.", tone: .attention),
                          changes: nil, incoming: nil, pushTitle: "Retry push", working: false), "")
        case "merge":
            return (.init(branch: "main", repository: repo, sync: "Merge prepared · not committed", syncTone: .attention, canPull: false,
                          pullHint: "Commit local changes before pulling",
                          notice: .init(title: "Agent resolved the merge",
                                        text: "Kept your counts and Sam's phone labels. Boards, canvas and imports pass the checks. The merge commit keeps both parents.", tone: .done),
                          changes: changes(merge: true), incoming: nil, pushTitle: nil, working: false), "Merge phone labels with absolute counts")
        default:
            return (.init(branch: "main", repository: repo, sync: "Remote is up to date", syncTone: .done, canPull: false,
                          pullHint: "Commit local changes before pulling", notice: nil, changes: changes(), incoming: nil, pushTitle: nil, working: false), message)
        }
    }

    @Test(arguments: ["changed", "incoming", "offline", "drawing", "push-failed", "merge"])
    func gitPanel(_ mode: String) async throws {
        let (state, message) = Self.panel(mode)
        try await render("panel-\(mode)", size: CGSize(width: 580, height: 1000)) {
            NWGitPanel(state: state, message: .constant(message), close: {}, pull: {}, select: { _ in }, commit: { _ in }, push: {}, copyURL: {})
        }
    }

    @Test func panelScrolls() async throws {
        let (state, message) = Self.panel("changed")
        try await render("panel-short", size: CGSize(width: 580, height: 560)) {
            NWGitPanel(state: state, message: .constant(message), maxHeight: 480, close: {}, pull: {}, select: { _ in }, commit: { _ in }, push: {}, copyURL: {})
        }
    }

    @Test func mergeDialog() async throws {
        try await render("merge-dialog", size: CGSize(width: 752, height: 700)) {
            NWGitMergeDialog(branch: "main", upstream: "origin/main",
                             local: .init(subject: "Show absolute counts in the checkout funnel", author: "You", hash: "9e340b2",
                                          files: ["A.dc.html", "A-phone.dc.html", "canvas.json"]),
                             incoming: .init(subject: "Clarify phone step labels", author: "Sam Nguyen", hash: "6bc29f1", files: ["A-phone.dc.html"]),
                             keepLocal: {}, resolve: {})
        }
    }

    @Test func mergeCards() async throws {
        try await render("merge-card", size: CGSize(width: 760, height: 900)) {
            VStack(alignment: .leading, spacing: NW.Space.xxl) {
                NWGitMergeCard(phase: .running)
                NWGitMergeCard(phase: .ready, review: {})
                NWGitMergeCard(phase: .stopped, retry: {})
                NWGitMergeCard(phase: .failed("I couldn't verify the merged phone board. Your original design and both commits are unchanged."), retry: {})
            }
        }
    }

    @Test func intro() async throws {
        try await render("intro", size: CGSize(width: 560, height: 260)) { NWGitDesignIntro() }
    }

    @Test func notices() async throws {
        try await render("notices", size: CGSize(width: 640, height: 280)) {
            VStack(alignment: .leading, spacing: NW.Space.xl) {
                NWGitCanvasNotice(.opened, title: "Opened from Git", detail: "4 boards · acme-web · 2 comments", dismiss: {})
                NWGitCanvasNotice(.paused, title: "Pull paused", detail: "Your work is safe. Resolve overlapping changes before updating the canvas.")
            }
        }
    }
}
