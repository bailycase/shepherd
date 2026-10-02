import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// The @ picker in a real composer, in a real window, before it has rows: typing "@" opens it at
/// once with "Loading designs…", the designs replace that when they are read, a read that takes
/// too long says "Couldn't load designs." with a Retry that is pressed the way VoiceOver presses
/// it, and a late answer to a read a newer one replaced is dropped. Nothing is posted to the
/// window; each scenario runs in its own process for the accessibility tree (`ControlPress`).
@Suite("Mention picker loading, in a composer", .integrationTimeLimit)
struct MentionPickerLoadingFlowTests {
    @Test func atSignOpensThePickerSayingItIsLoadingAndTheDesignsReplaceIt() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.loadingThenRows() }
        }
    }

    @Test func aReadThatTakesTooLongFailsWithARetryThatReadsAgain() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.timingOutThenRetrying() }
        }
    }

    // MARK: Fixtures

    /// The reads of this Mac's designs the picker asked for, each answered when the test says.
    final class CatalogReads: @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: [CheckedContinuation<DesignMentionCatalog, Never>] = []
        private var asked = 0

        var count: Int { lock.withLock { asked } }

        func read() async -> DesignMentionCatalog {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    asked += 1
                    waiting.append(continuation)
                }
            }
        }

        /// Answers every read still waiting, oldest first.
        func answer(_ catalog: DesignMentionCatalog) {
            let held = lock.withLock { () -> [CheckedContinuation<DesignMentionCatalog, Never>] in
                defer { waiting = [] }
                return waiting
            }
            for continuation in held { continuation.resume(returning: catalog) }
        }
    }

    /// Two designs, as this Mac's catalog lists them.
    static let catalog: DesignMentionCatalog = {
        func design(_ id: String, _ name: String, boards: Int, active: Double) -> DesignMentionItem {
            DesignMentionItem(kind: .design, reference: DesignReference(designID: DesignID(rawValue: id), board: nil)!, title: name,
                              breadcrumb: [], system: "acme-web", boardCount: boards, activeAt: active)
        }
        return DesignMentionCatalog(designs: [design("checkout", "Checkout funnel dashboard", boards: 2, active: 1_000),
                                              design("events", "Events explorer", boards: 1, active: 500)])
    }()

    @MainActor
    static func chips(_ reads: CatalogReads, timeout: Duration = DesignReferenceChips.defaultCatalogTimeout) -> DesignReferenceChips {
        DesignReferenceChips(agentID: AgentID(rawValue: "picker"), io: DesignReferenceChips.IO(catalog: { await reads.read() }),
                             catalogTimeout: timeout)
    }

    /// A composer that has the keyboard, on a local thread whose host takes design references.
    @MainActor
    static func composer(_ chips: DesignReferenceChips) async throws -> ComposerThread {
        let thread = ComposerThread(focused: true, designReferences: chips)
        try await thread.waitUntilReady()
        try await eventuallyOnMain("the field to take the keyboard") { thread.focusedEditor?.isFieldEditor == true }
        return thread
    }

    /// The picker's rows, by their accessibility labels.
    @MainActor
    static func rows(_ thread: ComposerThread) -> [String] {
        thread.window.elements().compactMap(\.label).filter { $0.hasPrefix("Checkout funnel") || $0.hasPrefix("Events explorer") }
    }

    // MARK: Scenarios

    @MainActor
    static func loadingThenRows() async throws {
        AccessibilityNode.enable()
        let reads = CatalogReads()
        let chips = Self.chips(reads)
        let thread = try await Self.composer(chips)
        defer { thread.close() }

        thread.type("Match the funnel in @")
        try await eventuallyOnMain("the picker to say it is loading") { thread.window.element("Loading designs") != nil }
        #expect(thread.window.element("Mention") != nil, "the picker opened at once, before any design was read")
        #expect(Self.rows(thread).isEmpty, "and lists nothing to choose")
        try await eventuallyOnMain("the read of the designs to start") { reads.count == 1 }
        #expect(chips.catalogStage == .loading)

        // Words typed while it loads filter the rows once they arrive.
        thread.type("fun")
        #expect(thread.window.element("Loading designs") != nil)
        let catalog = Self.catalog
        reads.answer(catalog)
        try await eventuallyOnMain("the designs to replace the loading line") {
            thread.window.element("Loading designs") == nil && !Self.rows(thread).isEmpty
        }
        let rows = Self.rows(thread)
        #expect(rows.contains { $0.hasPrefix("Checkout funnel dashboard") } && !rows.contains { $0.hasPrefix("Events explorer") },
                "the rows are the ones the draft as typed now asks for: \(rows)")
        #expect(chips.catalogStage == .rows)

        // Closing and opening again keeps the rows on screen while the designs are read once more.
        thread.store.draft = "Match the funnel in "
        try await eventuallyOnMain("the picker to close") { thread.window.element("Mention") == nil }
        thread.type("@")
        try await eventuallyOnMain("the picker to open on the rows it has") { !Self.rows(thread).isEmpty }
        #expect(thread.window.element("Loading designs") == nil, "a catalog already read never goes back to loading")
        try await eventuallyOnMain("the designs to be read once more") { reads.count == 2 }
        #expect(!Self.rows(thread).isEmpty && thread.window.element("Loading designs") == nil, "and the rows stay while it does")
    }

    @MainActor
    static func timingOutThenRetrying() async throws {
        AccessibilityNode.enable()
        let reads = CatalogReads()
        let chips = Self.chips(reads, timeout: .milliseconds(150))
        let thread = try await Self.composer(chips)
        defer { thread.close() }

        thread.type("@")
        try await eventuallyOnMain("the picker to say it is loading") { thread.window.element("Loading designs") != nil }
        try await eventuallyOnMain("the read to be given up on") {
            if case .failed = chips.catalogStage { return true } else { return false }
        }
        try await eventuallyOnMain("the picker to say so") { thread.window.element("Couldn’t load designs") != nil }
        #expect(thread.window.element("Loading designs") == nil, "a spinner that never ends is not left behind")
        #expect(Self.rows(thread).isEmpty)

        let retry = try #require(thread.window.controls().first { $0.label == "Retry" })
        #expect(ControlPress.undersized([retry], minimum: .desktop).isEmpty, "Retry is as big as a desktop control: \(retry)")
        let pressed = try thread.window.press("Retry")
        #expect(pressed.isEnabled)
        try await eventuallyOnMain("Retry to read again") { reads.count == 2 }
        try await eventuallyOnMain("the picker to say it is loading again") { thread.window.element("Loading designs") != nil }
        #expect(thread.window.element("Couldn’t load designs") == nil, "the failure is gone while it reads")

        // The first read answers now, long after it was given up on, and then the second: only the
        // second's belongs to this opening.
        reads.answer(Self.catalog)
        try await eventuallyOnMain("the designs to appear") { !Self.rows(thread).isEmpty }
        #expect(thread.window.element("Loading designs") == nil)
        #expect(chips.catalogStage == .rows)
        #expect(chips.catalog == Self.catalog)
    }
}
