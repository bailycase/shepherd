import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdTestSupport
import ShepherdUI
import Testing
@testable import ShepherdApp

/// The model-settings popover, over the real composer in a real window, pressed the way VoiceOver
/// presses: each control is found in the accessibility tree and its press action run
/// (`ControlPress`), and nothing is posted to the window. SwiftUI draws that tree only for a
/// process an assistive client is attached to, which is process-wide, so each scenario runs in
/// its own process.
///
/// The Speed control once could not be clicked: its segments were `Button`s with a clear
/// background, so the only part of the Fast segment that answered a click was its label, 39×16pt
/// of the 147×24pt segment. `everySegmentIsAsBigAsItsDrawnSegment` measures that, and
/// `fastAndStandardSwitchTheThread` presses the segment through to the host.
@Suite("Model settings popover", .integrationTimeLimit)
struct ModelSettingsPopoverTests {
    @Test func fastAndStandardSwitchTheThread() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.switchingSpeed() }
        }
    }

    @Test func everySegmentIsAsBigAsItsDrawnSegment() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.measuringSegments() }
        }
    }

    @Test func aModelWithoutAFastTierHasNoSpeedRowAndALevelStillChanges() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.choosingWithoutSpeed() }
        }
    }

    @Test func theNewThreadPageSwitchesSpeedFromTheSamePopover() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.switchingSpeedOnTheNewThreadPage() }
        }
    }

    @Test func modelSearchTakesTheKeyboardFromTheChipAndChoosesWithArrowAndReturn() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.searchingModels() }
        }
        expectScenarioCompleted(result)
    }

    @MainActor
    static func searchingModels() async throws {
        AccessibilityNode.enable()
        let models = ["fixture/one", "fixture/two"].map { PiModelCatalog.Entry(id: $0, context: "200K", reasoning: false) }
        let thread = ComposerThread(models: models, focused: true)
        defer { thread.close() }
        try await thread.waitUntilReady()
        thread.store.draft = "Preserve my words"
        let chip = try thread.window.press("Model settings: anthropic/claude-opus-4-5")
        try await thread.settle()
        let all = try thread.window.press("All models…")
        #expect(ControlPress.undersized([chip, all], minimum: .desktop).isEmpty)
        try await thread.settle()
        let search = try #require(thread.focusedEditor)
        #expect(search.string.isEmpty)
        thread.type("fixture/")
        try await thread.settle()
        #expect(thread.store.draft == "Preserve my words")
        func key(_ code: UInt16, _ characters: String) throws {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: thread.window.window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            // Local offscreen dispatch reaches SwiftUI's key handlers; nothing is posted.
            thread.window.window.sendEvent(event)
            #expect(!thread.window.window.isKeyWindow)
        }
        let options = ModelCatalog(models).list(query: "fixture/", recent: RecentModels.load(thread.modelDefaults).map(\.id), current: thread.store.model).options
        let expected = try #require(options.dropFirst().first).id
        try key(125, "\u{f701}")
        try await thread.settle()
        try key(126, "\u{f700}")
        try await thread.settle()
        try key(125, "\u{f701}")
        try await thread.settle()
        try key(36, "\r")
        try await eventuallyOnMain("the highlighted model to reach the host") {
            thread.requests.contains { if case .setModel(_, _, _, let id) = $0 { id == expected } else { false } }
        }
        try await eventuallyOnMain("the composer to regain its keyboard") { thread.focusedEditor?.string == "Preserve my words" }
        let chosen = thread.store.model
        thread.openModelPicker()
        try await thread.settle()
        try key(53, "\u{1b}")
        try await eventuallyOnMain("Escape to return to the draft") { thread.focusedEditor?.string == "Preserve my words" }
        #expect(thread.store.model == chosen)
    }

    // MARK: Scenarios

    private static let chip = "Model settings: openai/gpt-6-luna"

    /// Opens the popover through the button, as a click would.
    @MainActor
    private static func openPopover(_ thread: ComposerThread, chip label: String = chip) async throws {
        try thread.window.press(label)
        try await thread.settle()
    }

    private static func tier(_ tier: String, in requests: [NativeThreadRequest]) -> Bool {
        requests.contains { if case .setServiceTier(_, _, _, let sent) = $0 { sent == tier } else { false } }
    }

    /// Standard to Fast to Standard: the host gets each, the thread and the button follow, and the
    /// popover stays open through both.
    @MainActor
    static func switchingSpeed() async throws {
        AccessibilityNode.enable()
        let thread = ComposerThread(speed: true)
        defer { thread.close() }
        try await thread.waitUntilReady()
        let button = { thread.window.element(Self.chip) }
        #expect(button()?.value == "Medium", "Standard draws no Fast mark on the button")
        let plainWidth = try #require(button()).frame.width

        try await openPopover(thread)
        var segments = thread.window.buttons(in: "Speed")
        try #require(segments.map(\.label) == ["Standard", "Fast"], "a model with a Fast tier has a Speed control")
        #expect(segments.map(\.isSelected) == [true, false])

        #expect(thread.window.element("gpt-6-luna, current, offers Fast") != nil, "the model row with a Fast tier wears the bolt")

        try thread.window.press("Fast", in: "Speed")
        try await eventuallyOnMain("the thread to say Fast") { thread.store.serviceTier == .fast }
        #expect(tier("fast", in: thread.requests), "the host was asked for Fast")
        try await eventuallyOnMain("the button to carry the Fast mark") { button()?.value == "Medium, Fast" }
        try await eventuallyOnMain("the bolt to widen the button") { (button()?.frame.width ?? 0) > plainWidth }
        segments = thread.window.buttons(in: "Speed")
        #expect(segments.map(\.isSelected) == [false, true], "the popover stayed open and shows Fast chosen")

        try thread.window.press("Standard", in: "Speed")
        try await eventuallyOnMain("the thread to say Standard") { thread.store.serviceTier == .standard }
        #expect(tier("standard", in: thread.requests))
        try await eventuallyOnMain("the button to lose the Fast mark") { button()?.value == "Medium" }
        try await eventuallyOnMain("the button to narrow again") { button()?.frame.width == plainWidth }
    }

    /// Every segment, chosen or not, answers a click over the whole of what is drawn: its frame in
    /// the accessibility tree (what the pointer hits) is the segment, not just its label.
    @MainActor
    static func measuringSegments() async throws {
        AccessibilityNode.enable()
        let thread = ComposerThread(speed: true, thinkingLevels: ["off", "minimal", "low", "medium", "high", "xhigh", "max"])
        defer { thread.close() }
        try await thread.waitUntilReady()
        try await openPopover(thread)

        func check(_ group: String, perRow: [Int]) throws {
            let track = try #require(thread.window.elements().first { $0.role == "AXGroup" && $0.label == group }).frame
            let segments = thread.window.buttons(in: group)
            try #require(segments.count == perRow.reduce(0, +), "\(group) has a segment for each choice")
            var index = 0
            for count in perRow {
                let share = (track.width - 2 * SH.Space.xxs - SH.Space.xxs * CGFloat(count - 1)) / CGFloat(count)
                for segment in segments[index..<index + count] {
                    #expect(abs(segment.frame.width - share) <= 1, "\(segment.label ?? "?") fills its share of the row: \(segment.frame.width) of \(share)")
                    #expect(segment.frame.height >= SH.Height.controlS, "\(segment.label ?? "?") is the whole segment tall: \(segment.frame.height)")
                }
                index += count
            }
        }
        try check("Speed", perRow: [2])
        try check("Thinking", perRow: [4, 3])
        let controls = ["Speed", "Thinking"].flatMap { ControlPress.controls(in: $0, under: thread.window.host) }
        try #require(controls.count == 9, "the Speed and Thinking rows list their nine segments")
        #expect(ControlPress.undersized(controls, minimum: .desktop).isEmpty,
                "every segment has a desktop hit area: \(ControlPress.undersized(controls, minimum: .desktop))")
    }

    /// A model that offers no raised tier has no Speed row (and no bolt), a level changes while the
    /// popover stays open, and All models… hands over to the full picker.
    @MainActor
    static func choosingWithoutSpeed() async throws {
        AccessibilityNode.enable()
        let thread = ComposerThread(thinkingLevels: ["low", "medium", "high", "xhigh"])
        defer { thread.close() }
        try await thread.waitUntilReady()
        let label = "Model settings: anthropic/claude-opus-4-5"
        try await openPopover(thread, chip: label)
        let all = thread.window.elements()
        #expect(!all.contains { $0.label == "SPEED" || $0.label == "Speed" }, "no Speed row for a model with no Fast tier")
        #expect(!all.contains { $0.label?.contains("offers Fast") == true }, "and no bolt on its row")
        #expect(thread.window.buttons(in: "Thinking").map(\.label) == ["Low", "Medium", "High", "Extra high"])

        try thread.window.press("Extra high", in: "Thinking")
        try await eventuallyOnMain("the thread to say Extra high") { thread.store.thinking == "xhigh" }
        try await eventuallyOnMain("the button to say Extra high") { thread.window.element(label)?.value == "Extra high" }
        #expect(thread.window.element("Model, thinking and speed") != nil, "a level leaves the popover open")

        // All models… hands over to the full picker (choosing a model would record it in Recent, in
        // the process's own preferences).
        try thread.window.press("All models…")
        try await thread.settle()
        #expect(thread.window.element("Model, thinking and speed") == nil, "All models… closes the popover")
        #expect(thread.window.element("Choose a model") != nil, "and opens the full picker")
    }

    /// The New thread page's composer takes the same popover, and its draft follows.
    @MainActor
    static func switchingSpeedOnTheNewThreadPage() async throws {
        AccessibilityNode.enable()
        try StubPi.installAsEngine()
        let listing = ModelListing(models: ["openai/gpt-5", "fixture/plain"], defaultModel: "openai/gpt-5", withoutThinking: ["fixture/plain"],
                                   thinkingLevels: ["openai/gpt-5": ["off", "low", "medium", "high", "xhigh", "max"]],
                                   serviceTiers: ["openai/gpt-5": ["standard", "fast"]], contexts: ["openai/gpt-5": "400K"])
        let app = try AppHarness(modelCatalog: { listing })
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let vm = try await app.start(with: ShepherdState(spaces: [space]))
        vm.openNewThread()
        let draft = vm.newThread
        try await eventuallyOnMain("creation capabilities to load") { !draft.loadingDefaults }
        draft.setModel("openai/gpt-5")
        let window = OffscreenWindow(size: CGSize(width: 1000, height: 700), dark: true, NewThreadPage(vm: vm, chrome: PageHeaderChrome()))
        defer { window.close() }
        let label = "Model settings: openai/gpt-5"
        func button() -> AccessibilityNode? { window.element(label) }
        try await eventuallyOnMain("the page's model-settings button") { button() != nil }

        try window.press(label)
        try await eventuallyOnMain("the popover") { window.buttons(in: "Speed").count == 2 }
        try window.press("Fast", in: "Speed")
        try await eventuallyOnMain("the draft to say Fast") { draft.serviceTier == .fast }
        try await eventuallyOnMain("the button to carry the Fast mark") { button()?.value?.hasSuffix("Fast") == true }
        #expect(window.buttons(in: "Speed").map(\.isSelected) == [false, true])
        try window.press("Standard", in: "Speed")
        try await eventuallyOnMain("the draft to say Standard") { draft.serviceTier == .standard }
        try await eventuallyOnMain("the button to lose the Fast mark") { button()?.value?.hasSuffix("Fast") == false }
    }
}
