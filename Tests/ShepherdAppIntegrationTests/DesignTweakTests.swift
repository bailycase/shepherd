import AppKit
import CryptoKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp
@testable import ShepherdRemote

/// The Tweak tab against a real server (docs/designs.md › Tweak): a drag writes once, on
/// release, as a splice of the board's source; a stale revision is read again and the change made
/// once more; Every <name> writes every board it reaches as one change; data-props values land in
/// canvas.json; Reset and Undo put back exactly what was there.
@Suite("Design tweak", .mainActorExclusive)
@MainActor
struct DesignTweakTests {
    static func board(_ title: String, note: String = "", helmet: String = "") -> String {
        """
        <!doctype html>
        <html lang="en">
        <head><meta charset="utf-8"><title>\(title)</title><script src="./support.js"></script></head>
        <body>
        <x-dc>
        <helmet><style>:root{--accent:#4f46e5;--slate:#475569;--space-4:16px;--space-6:24px;--space-8:32px}</style>\(helmet)</helmet>
        <div style="width: 400px; height: 300px; display: flex; flex-direction: column; gap: 16px">
        <div data-el="funnel card" style="background: #ffffff; border-radius: 12px; padding: 20px 24px"><span style="font-size: 14px; color: #0f172a">Checkout funnel</span></div>
        <p>{{ note }}\(note)</p>
        </div>
        </x-dc>
        <script type="text/x-dc" data-dc-script data-props='{"$preview":{"width":400,"height":300},"rows":{"editor":"int","min":1,"max":8,"default":4}}'>
        class Component extends DCLogic { renderVals() { return { note: 'Rows ' + (this.props.rows ?? 4) }; } }
        </script>
        </body>
        </html>
        """
    }

    static let a = DesignPath("A.dc.html")!
    static let phone = DesignPath("A-phone.dc.html")!
    /// The card: tid 3 (helmet 0, its style 1, the root 2), the root's first child.
    static let card = DesignElementID(board: "A.dc.html", tid: 3, path: [1, 0])!

    private struct Opened {
        let app: AppHarness
        let design: Design
        let tweak: DesignTweakModel
    }

    /// A design with two boards holding a "funnel card", its screen's Tweak model selecting the
    /// card on A.
    private func open() async throws -> Opened {
        let app = try AppHarness()
        app.settings.designToolEnabled = true
        let space = Fixture.space(path: app.dir.path)
        let vm = try await app.start(with: ShepherdState(spaces: [space]))
        vm.designNetwork = .none
        let design = Design(name: "Checkout funnel", spaceID: space.id, createdAt: 1_000)
        _ = try await app.server.createDesign(design)
        _ = try await app.server.writeDesignBoards(design.id, sources: [Self.a: Self.board("A"), Self.phone: Self.board("A · phone")])
        _ = try await app.server.updateDesignIndex(design.id, patch: .object([
            "boards": .object([
                "A.dc.html": .object(["x": .number(0), "y": .number(0), "w": .number(400), "h": .number(300), "title": .string("A · Funnel first")]),
                "A-phone.dc.html": .object(["x": .number(480), "y": .number(0), "w": .number(400), "h": .number(300), "title": .string("A · phone")]),
            ]),
        ]))
        try await eventuallyOnMain("the design to load") { vm.state.designs.count == 1 }
        let tweak = try #require(vm.designScreen(design.id).tweak)
        await tweak.select(DesignTweakTarget(board: Self.a, element: Self.card, kind: .shape, tag: "card · funnel card"))
        return Opened(app: app, design: design, tweak: tweak)
    }

    private func source(_ opened: Opened, _ path: DesignPath = a) async throws -> String {
        try await opened.app.server.designBoard(opened.design.id, path: path).source
    }

    private func revision(_ opened: Opened) async throws -> UInt64 {
        try await opened.app.server.designSnapshot(opened.design.id).revision
    }

    private func padding(_ opened: Opened, _ path: DesignPath = a) async throws -> String? {
        DesignStyleEdit.style(of: 3, in: try await source(opened, path))?.value("padding")
    }

    @Test func theCardOffersItsControls() async throws {
        let opened = try await open()
        defer { opened.app.stop() }
        let rows = opened.tweak.presentation.groups.flatMap { group in group.rows.map { "\(group.title)/\($0.label)" } }
        #expect(rows == ["Layout/Padding", "Layout/Radius", "Color/Fill", "Board/Rows"])
        #expect(opened.tweak.presentation.board == "A · Funnel first")
        #expect(opened.tweak.presentation.scopeName == "funnel card")
    }

    /// Dragging the padding slider writes nothing until it is let go, then writes once: one
    /// revision, one version kept, the spliced value the board's token.
    @Test func aDragWritesOnceOnRelease() async throws {
        let opened = try await open()
        defer { opened.app.stop() }
        let before = try await revision(opened)
        let original = try await source(opened)
        for index in [0, 1, 2, 1, 2] { opened.tweak.setStep(.padding, index: index, phase: .changed) }
        #expect(try await revision(opened) == before, "nothing is written while dragging")

        opened.tweak.setStep(.padding, index: 2, phase: .ended)
        try await eventuallyReading("the release to be written") { try await self.padding(opened) == "var(--space-8)" }
        #expect(opened.tweak.writes == 1)
        #expect(try await revision(opened) == before + 1)
        #expect(try await opened.app.server.designVersions(opened.design.id, path: Self.a).last?.sha256
                == SHA256.hash(data: Data(original.utf8)).map { String(format: "%02x", $0) }.joined())
        let written = try await source(opened)
        #expect(written == original.replacingOccurrences(of: "padding: 20px 24px", with: "padding: var(--space-8)"),
                "only the value changed")
        #expect(try await padding(opened, Self.phone) == "20px 24px", "This board only")
    }

    /// The agent wrote while the slider was held: the write names a revision the design has moved
    /// past, so the board is read again and the change made on what the agent wrote.
    @Test func aStaleRevisionIsReadAgainAndTheChangeMadeOnce() async throws {
        let opened = try await open()
        defer { opened.app.stop() }
        opened.tweak.setStep(.padding, index: 0, phase: .changed)
        let agent = Self.board("A", note: " · rewritten")
        _ = try await opened.app.server.writeDesignBoard(opened.design.id, path: Self.a, source: agent)
        let before = try await revision(opened)

        opened.tweak.setStep(.padding, index: 0, phase: .ended)
        try await eventuallyReading("the tweak to land on the agent's board") { try await self.padding(opened) == "var(--space-4)" }
        let written = try await source(opened)
        #expect(written.contains("· rewritten"), "the agent's write is kept")
        #expect(opened.tweak.writes == 2, "the stale write, then the one made again")
        #expect(try await revision(opened) == before + 1)
        #expect(opened.tweak.presentation.problem == nil)
    }

    /// The agent's write moved the card's tid (a new element in the helmet) but not its place:
    /// the tweak lands on the card, found by its path, and never on what took its tid.
    @Test func aTweakAfterAWriteThatMovedTheElementLandsOnItByItsPath() async throws {
        let opened = try await open()
        defer { opened.app.stop() }
        opened.tweak.setStep(.padding, index: 0, phase: .changed)
        let agent = Self.board("A", helmet: #"<link rel="preconnect" href="https://fonts.googleapis.com">"#)
        _ = try await opened.app.server.writeDesignBoard(opened.design.id, path: Self.a, source: agent)

        opened.tweak.setStep(.padding, index: 0, phase: .ended)
        try await eventuallyReading("the tweak to land on the card") {
            DesignStyleEdit.style(of: 4, in: try await self.source(opened))?.value("padding") == "var(--space-4)"
        }
        let written = try await source(opened)
        #expect(DesignStyleEdit.style(of: 3, in: written)?.value("padding") == nil, "the element now at tid 3 is untouched")
        #expect(written == agent.replacingOccurrences(of: "padding: 20px 24px", with: "padding: var(--space-4)"))
    }

    @Test func everyElementOfTheNameIsWrittenAsOneChange() async throws {
        let opened = try await open()
        defer { opened.app.stop() }
        opened.tweak.scope = .every
        try await eventuallyOnMain("the scope to reach both boards") {
            return opened.tweak.presentation.scopeNote?.hasPrefix("Every funnel card: A · phone and A · Funnel first.") == true
        }
        let before = try await revision(opened)
        opened.tweak.choose(.radius, "16")
        try await eventuallyReading("both boards to take the radius") {
            let a = DesignStyleEdit.style(of: 3, in: try await self.source(opened))?.value("border-radius")
            let phone = DesignStyleEdit.style(of: 3, in: try await self.source(opened, Self.phone))?.value("border-radius")
            return a == "16px" && phone == "16px"
        }
        #expect(try await revision(opened) == before + 1, "one revision for both boards")
    }

    @Test func aColorIsAlwaysAToken() async throws {
        let opened = try await open()
        defer { opened.app.stop() }
        guard case .colors(let colors, _)? = opened.tweak.presentation.groups.flatMap(\.rows).first(where: { $0.label == "Fill" })?.control else {
            Issue.record("no fill")
            return
        }
        #expect(colors.map(\.title) == ["accent", "slate"])
        opened.tweak.choose(.fill, color: colors[0])
        try await eventuallyReading("the fill to be written") {
            DesignStyleEdit.style(of: 3, in: try await self.source(opened))?.value("background") == "var(--accent)"
        }
    }

    /// A data-props value goes to canvas.json's tweaks, once per release.
    @Test func aPropsValueIsWrittenToCanvasJSON() async throws {
        let opened = try await open()
        defer { opened.app.stop() }
        let original = try await source(opened)
        for rows in [5.0, 6, 7] { opened.tweak.setProp("rows", .number(rows), phase: .changed) }
        opened.tweak.setProp("rows", .number(7), phase: .ended)
        try await eventuallyReading("the value to reach canvas.json") {
            try await opened.app.server.designSnapshot(opened.design.id).index.tweaks(for: Self.a) == ["rows": .number(7)]
        }
        #expect(opened.tweak.writes == 1)
        #expect(try await source(opened) == original, "the board's file is untouched")
        opened.tweak.setProp("rows", .number(99), phase: .ended)
        try await eventuallyReading("an out-of-range value to be clamped") {
            try await opened.app.server.designSnapshot(opened.design.id).index.tweaks(for: Self.a) == ["rows": .number(8)]
        }
    }

    /// Reset puts back the bytes the board had before this session's tweaks.
    @Test func resetPutsBackExactlyWhatWasThere() async throws {
        let opened = try await open()
        defer { opened.app.stop() }
        let original = try await source(opened)
        opened.tweak.setStep(.padding, index: 1, phase: .ended)
        try await eventuallyReading("the padding to be written") { try await self.padding(opened) == "var(--space-6)" }
        opened.tweak.choose(.radius, "8")
        try await eventuallyOnMain("Reset to be offered") { opened.tweak.presentation.canReset && opened.tweak.writes == 2 }
        opened.tweak.reset()
        try await eventuallyReading("the board to be as it was") { try await self.source(opened) == original }
        try await eventuallyOnMain("Reset to have nothing left") { !opened.tweak.presentation.canReset }
    }

    /// Undo puts the board back to the version the tweak kept; Redo brings the tweak back.
    @Test func undoAndRedoATweak() async throws {
        let opened = try await open()
        defer { opened.app.stop() }
        let undo = UndoManager()
        opened.tweak.undoManager = undo
        let original = try await source(opened)
        opened.tweak.setStep(.padding, index: 0, phase: .ended)
        try await eventuallyReading("the padding to be written") { try await self.padding(opened) == "var(--space-4)" }
        let tweaked = try await source(opened)
        #expect(undo.canUndo && undo.undoActionName == "Tweak")

        undo.undo()
        try await eventuallyReading("Undo to put the board back") { try await self.source(opened) == original }
        #expect(undo.canRedo)
        undo.redo()
        try await eventuallyReading("Redo to bring the tweak back") { try await self.source(opened) == tweaked }
    }

    /// Undo never takes back a later write: once the agent rewrote the board, it refuses.
    @Test func undoAfterTheAgentRewroteTheBoardLeavesItAlone() async throws {
        let opened = try await open()
        defer { opened.app.stop() }
        let undo = UndoManager()
        opened.tweak.undoManager = undo
        opened.tweak.setStep(.padding, index: 0, phase: .ended)
        try await eventuallyReading("the padding to be written") { try await self.padding(opened) == "var(--space-4)" }
        let agent = Self.board("A", note: " · agent")
        _ = try await opened.app.server.writeDesignBoard(opened.design.id, path: Self.a, source: agent)
        undo.undo()
        try await eventuallyOnMain("Undo to say it couldn't") { opened.tweak.presentation.problem != nil }
        #expect(try await source(opened) == agent)
    }
}

private struct NeverHappened: Error, CustomStringConvertible {
    let what: String
    var description: String { "timed out waiting for \(what)" }
}

/// `eventuallyOnMain` for a condition that reads from the server (it awaits).
@MainActor
private func eventuallyReading(_ what: String, timeout: Duration = defaultWaitTimeout,
                               _ condition: @MainActor () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    if try await condition() { return }
    throw NeverHappened(what: what)
}
