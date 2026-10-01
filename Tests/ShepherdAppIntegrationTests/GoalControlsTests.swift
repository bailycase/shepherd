import AppKit
import Foundation
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// Real goal-card buttons over a ThreadView. AX attachment and text scaling are process-wide,
/// so every scenario runs in an exit child; windows never become key and no events are posted.
@Suite("Goal controls", .integrationTimeLimit)
struct GoalControlsTests {
    @Test func everyStateOffersOnlyItsActionsAndPauseResumeClearReachTheHost() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.controlsByState() }
        }
    }

    @Test func editingAndCancelKeepTheGoalStateAndOnlyAChangedSaveSendsAnEdit() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.editing() }
        }
    }

    @Test func aPendingQuestionDisablesResumeUntilTheQuestionIsAnswered() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.answerThenResume() }
        }
    }

    @Test func pauseStillWorksDuringAWorkerTurn() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.duringWork() }
        }
    }

    @Test func aStaleGoalFenceIsRefusedAndTheNextPressUsesTheRefreshedFence() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.staleFence() }
        }
    }

    @Test func sharedDockTargetsStayInsideTheCardAndDoNotOverlapOrShiftWithStatus() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.dockTargets() }
        }
    }

    @Test func largerTextGrowsTheGoalCardPillAndResumeWithoutClippingTargets() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.scaling() }
        }
    }

    @Test func aGoalStopKeepsItsDiagnosticHiddenUntilItsDisclosureIsPressed() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.disclosure() }
        }
    }

    @MainActor
    private static func disclosure() async throws {
        AccessibilityNode.enable()
        let window = OffscreenWindow(dark: true)
        defer { window.close() }
        window.show(GoalRecordLine(text: "Goal needs you · choose a deployment target\n\nDetails:\nChoose staging or production. Diagnostic entry-7f9a4d.")
            .padding(NW.Space.l).frame(width: 640, height: 240, alignment: .top))
        try await eventuallyOnMain("the Details disclosure to attach") { window.element("Details") != nil }
        #expect(!window.elements().contains { (($0.label ?? "") + ($0.value ?? "")).contains("entry-7f9a4d") })
        try #require(window.element("Details")?.press() == true)
        try await eventuallyOnMain("the proof to appear after its disclosure is pressed") {
            window.elements().contains { (($0.label ?? "") + ($0.value ?? "")).contains("entry-7f9a4d") }
        }
        #expect(!window.window.isKeyWindow)
    }

    private static let states: [(NativeGoalState, [String])] = [
        (.working, ["Pause goal", "Edit goal", "Clear goal"]),
        (.checking, ["Pause goal", "Edit goal", "Clear goal"]),
        (.met, ["Clear goal"]),
        (.paused, ["Resume goal", "Edit goal", "Clear goal"]),
        (.needsYou, ["Resume goal", "Edit goal", "Clear goal"]),
    ]

    private static func goal(_ state: NativeGoalState, revision: Int = 4, text: String = "Ledger tests pass and go vet is clean.") -> NativeGoal {
        NativeGoal(id: "00000000-0000-0000-0000-0000000000AA", revision: revision, text: text, state: state,
                   elapsedSeconds: 400, tokensUsed: 71_000,
                   reason: state == .needsYou ? "The agent is waiting for your answer." : "Keep this stop/check reason.")
    }

    @MainActor
    private final class Host {
        let store = NativeThreadStore()
        let commands = ThreadCommandCenter()
        let window: OffscreenWindow
        var snapshot: NativeThreadSnapshot
        var requests: [NativeThreadRequest] = []
        var goalRequests: [NativeThreadRequest] {
            requests.filter { if case .goal = $0 { true } else { false } }
        }
        var buttons: [String] {
            window.elements().filter { $0.role == "AXButton" }.compactMap(\.label).filter { $0.hasSuffix(" goal") }
        }

        init(goal: NativeGoal?, running: Bool = false, dialogs: [NativeThreadDialog] = []) {
            snapshot = ComposerThread.snapshot(messages: 6, commands: [], dialogs: dialogs)
            snapshot.goal = goal
            snapshot.running = running
            snapshot.supportedActions.append("goal")
            window = OffscreenWindow(dark: true)
            let request: NativeThreadStore.Request = { [weak self] value in
                guard let self else { return .failure(code: "gone", message: "Host released") }
                self.requests.append(value)
                switch value {
                case .goal(let session, let generation, let operation, let action, let expectedID, let expectedRevision):
                    guard session == self.snapshot.piSessionID, generation == self.snapshot.generation,
                          var current = self.snapshot.goal else {
                        return .failure(code: "stale_session", message: "The session changed.")
                    }
                    guard expectedID == current.id, expectedRevision == current.revision else {
                        return .failure(code: "stale_goal", message: "The goal changed. Refresh it before acting.")
                    }
                    // Mirror shepherd-goal: edit changes the condition, not the state/reason;
                    // an unchanged condition is accepted without invalidating the revision.
                    switch action {
                    case .pause: current.state = .paused; current.reason = "Paused by you."
                    case .resume:
                        guard self.snapshot.dialogs.isEmpty else {
                            return .failure(code: "question_pending", message: "Answer the question before resuming the goal.")
                        }
                        current.state = .working; current.reason = nil
                    case .clear:
                        self.snapshot.goal = nil
                        self.snapshot.revision += 1
                        return .accepted(operationID: operation)
                    case .edit(let text):
                        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failure(code: "invalid", message: "Empty goal condition.") }
                        if text == current.text { return .accepted(operationID: operation) }
                        current.text = text
                    case .set: return .failure(code: "invalid", message: "This fixture edits existing goals only.")
                    }
                    current.revision += 1
                    self.snapshot.goal = current
                    self.snapshot.revision += 1
                    return .accepted(operationID: operation)
                case .answer(let session, let generation, let operation, let dialogID, _):
                    guard session == self.snapshot.piSessionID, generation == self.snapshot.generation,
                          self.snapshot.dialogs.contains(where: { $0.id == dialogID }) else {
                        return .failure(code: "stale_dialog", message: "The question changed.")
                    }
                    self.snapshot.dialogs.removeAll { $0.id == dialogID }
                    if self.snapshot.goal?.state == .needsYou {
                        self.snapshot.goal?.reason = "Answer received; resume to continue the goal."
                    }
                    self.snapshot.revision += 1
                    return .accepted(operationID: operation)
                default: return .snapshot(value: self.snapshot)
                }
            }
            window.show(ThreadView(store: store, active: true, isFocused: false, request: request,
                                   commandKey: "goal-controls", listModels: { .empty })
                .environment(\.threadCommands, commands)
                .environment(\.nwMotionPaused, true)
                .environment(\._accessibilityReduceMotion, true)
                .transaction { $0.disablesAnimations = true })
        }

        func ready() async throws {
            try await eventuallyOnMain("the goal thread to load its card") {
                store.ready && store.goal == snapshot.goal && Set(buttons) == Set(snapshot.goal.map { goal in
                    GoalControlsTests.states.first { $0.0 == goal.state }!.1
                } ?? [])
            }
            #expect(!window.window.isKeyWindow, "the fixture never takes the user's focus")
        }

        func button(_ label: String) -> AccessibilityNode? {
            window.elements().first { $0.role == "AXButton" && $0.label == label }
        }

        func press(_ label: String) throws {
            let button = try #require(button(label), "\(label) exists")
            try #require(button.goalIsEnabled, "\(label) is enabled")
            try #require(button.press(), "\(label) accepts its accessibility press")
        }

        func expectRequest(_ action: NativeGoalAction, fencedBy goal: NativeGoal, index: Int = 0) throws {
            try #require(goalRequests.indices.contains(index))
            guard case .goal(let session, let generation, _, let sent, let id, let revision) = goalRequests[index] else {
                Issue.record("Missing goal request"); return
            }
            #expect(session == snapshot.piSessionID && generation == snapshot.generation)
            #expect(sent == action && id == goal.id && revision == goal.revision)
        }

        func close() { store.stop(); window.close() }
    }

    @MainActor
    private static func controlsByState() async throws {
        AccessibilityNode.enable()
        for (state, offered) in states {
            for label in offered where label != "Edit goal" {
                let original = goal(state)
                let host = Host(goal: original)
                defer { host.close() }
                try await host.ready()
                #expect(Set(host.buttons) == Set(offered), "\(state) offers no other state's actions")
                try host.press(label)
                try await eventuallyOnMain("\(state) \(label) to reach the host") { host.goalRequests.count == 1 && !host.store.busy }
                switch label {
                case "Pause goal", "Resume goal":
                    let pausing = label == "Pause goal"
                    try host.expectRequest(pausing ? .pause : .resume, fencedBy: original)
                    var expected = original
                    expected.state = pausing ? .paused : .working
                    expected.reason = pausing ? "Paused by you." : nil
                    expected.revision += 1
                    try await eventuallyOnMain("the card to show the resulting goal") {
                        host.store.goal == expected && Set(host.buttons) == Set(pausing
                            ? ["Resume goal", "Edit goal", "Clear goal"] : ["Pause goal", "Edit goal", "Clear goal"])
                    }
                case "Clear goal":
                    try host.expectRequest(.clear, fencedBy: original)
                    try await eventuallyOnMain("clear to remove the card and all its actions") { host.store.goal == nil && host.buttons.isEmpty }
                default: Issue.record("Unexpected action \(label)")
                }
            }
        }
        let empty = Host(goal: nil)
        defer { empty.close() }
        try await empty.ready()
        #expect(empty.buttons.isEmpty && empty.window.element("Goal condition") == nil)
    }

    @MainActor
    private static func editing() async throws {
        AccessibilityNode.enable()
        for (state, offered) in states where offered.contains("Edit goal") {
            let original = goal(state)
            let host = Host(goal: original)
            defer { host.close() }
            try await host.ready()
            try host.press("Edit goal")
            try await eventuallyOnMain("\(state) editor to open") { host.window.element("Goal condition") != nil && host.button("Save") != nil }
            #expect(host.goalRequests.isEmpty && host.store.goal == original)
            #expect(Set(host.buttons) == Set(offered), "editing leaves the goal's state and actions visible")
            let unchangedSave = try #require(host.button("Save"))
            #expect(!unchangedSave.goalIsEnabled, "unchanged Save is disabled")
            _ = unchangedSave.press()
            try host.press("Cancel")
            try await eventuallyOnMain("Cancel to close without sending") { host.window.element("Goal condition") == nil }
            #expect(host.goalRequests.isEmpty && host.store.goal == original)

            try host.press("Edit goal")
            try await eventuallyOnMain("the goal editor to reopen") { host.window.element("Goal condition") != nil }
            let field = try #require(host.window.element("Goal condition"))
            let changed = "Ledger tests and race checks pass."
            try #require(field.setGoalValue(changed), "the AX field accepts a value without window focus")
            try await eventuallyOnMain("the modified condition to enable Save") {
                host.window.element("Goal condition")?.value == changed && host.button("Save")?.goalIsEnabled == true
            }
            #expect(!host.window.window.isKeyWindow)
            try host.press("Cancel")
            try await eventuallyOnMain("Cancel to discard the modified condition") { host.window.element("Goal condition") == nil }
            #expect(host.goalRequests.isEmpty && host.store.goal == original)

            try host.press("Edit goal")
            try await eventuallyOnMain("the original condition to return on reopen") { host.window.element("Goal condition")?.value == original.text }
            #expect(host.button("Save")?.goalIsEnabled == false)
            try #require(host.window.element("Goal condition")?.setGoalValue(" \n ") == true)
            try await eventuallyOnMain("an empty condition to stay unsavable") { host.button("Save")?.goalIsEnabled == false }
            try #require(host.window.element("Goal condition")?.setGoalValue(changed) == true)
            try await eventuallyOnMain("changed Save to enable") { host.button("Save")?.goalIsEnabled == true }
            try host.press("Save")
            var expected = original
            expected.text = changed
            expected.revision += 1
            try await eventuallyOnMain("Save to update the condition and close the editor") {
                host.store.goal == expected && host.window.element("Goal condition") == nil && !host.store.busy
            }
            #expect(host.goalRequests.count == 1)
            try host.expectRequest(.edit(text: changed), fencedBy: original)
            #expect(Set(host.buttons) == Set(offered), "Save preserves the state, reason and offered actions")
        }
        let finishing = Host(goal: goal(.checking))
        defer { finishing.close() }
        try await finishing.ready()
        try finishing.press("Edit goal")
        try await eventuallyOnMain("the checking editor to open") { finishing.window.element("Goal condition") != nil }
        try #require(finishing.window.element("Goal condition")?.setGoalValue("A different goal") == true)
        try await eventuallyOnMain("the checking edit to enable Save") { finishing.button("Save")?.goalIsEnabled == true }
        finishing.snapshot.goal?.state = .met
        finishing.snapshot.revision += 1
        await finishing.store.refresh()
        try await eventuallyOnMain("a met goal to disable the already-open editor's Save") { finishing.button("Save")?.goalIsEnabled == false }
        #expect(finishing.goalRequests.isEmpty, "an edited condition cannot inherit old green proof")
        try finishing.press("Cancel")
    }

    @MainActor
    private static func answerThenResume() async throws {
        AccessibilityNode.enable()
        for state in [NativeGoalState.paused, .needsYou] {
            let question = NativeThreadDialog(id: "permission", kind: .confirm, title: "Run the race checks?")
            let host = Host(goal: goal(state), dialogs: [question])
            defer { host.close() }
            try await host.ready()
            try await eventuallyOnMain("the question to appear with disabled Resume") {
                host.store.dialogs.count == 1 && host.button("Resume goal")?.goalIsEnabled == false && host.button("Yes") != nil
            }
            let original = try #require(host.store.goal)
            _ = host.button("Resume goal")?.press()
            try host.press("Yes")
            try await eventuallyOnMain("the answer to resolve the question and enable Resume") {
                host.store.dialogs.isEmpty && !host.store.busy && host.button("Resume goal")?.goalIsEnabled == true
            }
            #expect(host.goalRequests.isEmpty, "a disabled Resume sends no request or automatic continuation")
            #expect(host.store.goal?.state == state)
            let answered = host.requests.compactMap { request -> NativeDialogAnswer? in
                guard case .answer(let session, let generation, _, let id, let answer) = request else { return nil }
                #expect(session == host.snapshot.piSessionID && generation == host.snapshot.generation && id == question.id)
                return answer
            }
            #expect(answered == [.confirm(value: true)])
            let displayed = try #require(host.store.goal)
            #expect(displayed.id == original.id && displayed.revision == original.revision)
            try host.press("Resume goal")
            try await eventuallyOnMain("Resume after the answer to start work") { host.store.goal?.state == .working && !host.store.busy }
            #expect(host.goalRequests.count == 1)
            try host.expectRequest(.resume, fencedBy: displayed)
            #expect(host.store.goal?.reason == nil && host.store.goal?.revision == displayed.revision + 1)
        }
    }

    @MainActor
    private static func duringWork() async throws {
        AccessibilityNode.enable()
        for state in [NativeGoalState.working, .checking] {
            let original = goal(state)
            let host = Host(goal: original, running: true)
            defer { host.close() }
            try await host.ready()
            try host.press("Pause goal")
            try await eventuallyOnMain("Pause while pi runs to stop only the goal") { host.store.goal?.state == .paused && !host.store.busy }
            try host.expectRequest(.pause, fencedBy: original)
            #expect(host.store.snapshot?.running == true)
            #expect(!host.requests.contains { if case .abort = $0 { true } else { false } })
        }
    }

    @MainActor
    private static func staleFence() async throws {
        AccessibilityNode.enable()
        let original = goal(.working)
        let host = Host(goal: original)
        defer { host.close() }
        try await host.ready()
        let newer = goal(.working, revision: original.revision + 1, text: "Edited elsewhere.")
        host.snapshot.goal = newer
        host.snapshot.revision += 1
        try host.press("Pause goal")
        try await eventuallyOnMain("the stale action to fail and refresh the card") {
            host.store.notice?.contains("goal changed") == true && host.store.goal == newer && !host.store.busy
        }
        try host.expectRequest(.pause, fencedBy: original)
        #expect(host.snapshot.goal == newer, "the stale press did not apply Pause")
        try host.press("Pause goal")
        try await eventuallyOnMain("the refreshed press to pause") { host.goalRequests.count == 2 && host.store.goal?.state == .paused && !host.store.busy }
        try host.expectRequest(.pause, fencedBy: newer, index: 1)
        #expect(host.store.goal?.revision == newer.revision + 1)
    }

    // The same clipping boundary as the app: an unframed goal is the first section of NWDockStack.
    @MainActor
    private static func dock(_ state: NWGoalState, size: NWGoalSize, pressed: @escaping (String) -> Void) -> OffscreenWindow {
        OffscreenWindow(size: CGSize(width: size == .touch ? 366 : 620, height: 360), dark: true,
            NWDockStack(size: size == .touch ? .phone : .pointer, showsTray: true, showsQueue: true) {
                VStack(spacing: 0) {
                    NWGoalCard(state: state, time: "6m 40s", meta: "71k tokens", text: "Tests and race checks pass.", size: size, framed: false,
                               pause: { pressed("Pause goal") }, resume: { pressed("Resume goal") },
                               edit: { pressed("Edit goal") }, clear: { pressed("Clear goal") })
                        .accessibilityLabel("Goal section")
                    Text("Subagent section").font(.nw(.body)).frame(maxWidth: .infinity).frame(height: NW.Height.touch)
                }
            } queue: {
                Text("Queue section").font(.nw(.body)).frame(maxWidth: .infinity).frame(height: NW.Height.touch)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: .infinity, alignment: .top)
            .environment(\.nwMotionPaused, true)
            .environment(\._accessibilityReduceMotion, true))
    }

    @MainActor
    private static func measure(_ window: OffscreenWindow, state: NWGoalState, size: NWGoalSize) async throws -> (card: CGRect, status: CGRect, actions: [String: CGRect]) {
        try await eventuallyOnMain("the shared dock's goal accessibility tree") {
            window.element("Goal section") != nil && window.element("Clear goal") != nil
        }
        let card = try #require(window.element("Goal section")).frame
        let statusName: String = switch state {
        case .working: "Working"
        case .checking: "Checking"
        case .met: "Met"
        case .paused: "Paused"
        case .needsYou: "Needs you"
        }
        let status = try #require(window.elements().first { $0.label?.contains(statusName) == true }).frame
        let buttons = window.elements().filter { $0.role == "AXButton" && $0.label?.hasSuffix(" goal") == true }
        var frames: [String: CGRect] = [:]
        for button in buttons {
            let label = try #require(button.label)
            let frame = button.frame
            frames[label] = frame
            #expect(frame.width >= size.hitTarget - 0.5 && frame.height >= size.hitTarget - 0.5, "\(label) has its whole hit target")
            #expect(card.insetBy(dx: -0.5, dy: -0.5).contains(frame), "\(label) stays inside the shared dock's goal section")
            if size == .touch && ThemeStore.shared.textScale == 1 {
                #expect(frame.minY >= card.maxY - NW.Height.touch - 0.5, "the target uses only the header and its four-point body inset")
            }
            for point in [CGPoint(x: frame.minX + 1, y: frame.minY + 1), CGPoint(x: frame.maxX - 1, y: frame.minY + 1),
                          CGPoint(x: frame.minX + 1, y: frame.maxY - 1), CGPoint(x: frame.maxX - 1, y: frame.maxY - 1),
                          CGPoint(x: frame.midX, y: frame.midY)] {
                let hit = (window.host.accessibilityHitTest(point) as? NSObject).map(AccessibilityNode.init)
                #expect(hit?.label == label, "\(label) answers over its full target, including the shared dock's clipped edges")
            }
        }
        for (index, button) in buttons.enumerated() {
            for other in buttons.dropFirst(index + 1) {
                #expect(!button.frame.insetBy(dx: 0.5, dy: 0.5).intersects(other.frame.insetBy(dx: 0.5, dy: 0.5)), "goal action targets do not overlap")
            }
        }
        #expect(!window.window.isKeyWindow)
        return (card, status, frames)
    }

    @MainActor
    private static func dockTargets() async throws {
        AccessibilityNode.enable()
        for size in [NWGoalSize.desktop, .touch] {
            var measurements: [NWGoalState: (card: CGRect, status: CGRect, actions: [String: CGRect])] = [:]
            for state in NWGoalState.allCases {
                var pressed: [String] = []
                let window = dock(state, size: size) { pressed.append($0) }
                defer { window.close() }
                let measured = try await measure(window, state: state, size: size)
                measurements[state] = measured
                let native: NativeGoalState = switch state {
                case .working: .working
                case .checking: .checking
                case .met: .met
                case .paused: .paused
                case .needsYou: .needsYou
                }
                let expected = states.first { $0.0 == native }!.1.filter { size == .desktop || $0 != "Edit goal" }
                #expect(Set(measured.actions.keys) == Set(expected))
                for label in expected { try #require(window.element(label)?.press() == true) }
                #expect(pressed == expected, "every drawn header action calls its handler")
            }
            let pairs: [(NWGoalState, NWGoalState)] = [(.working, .checking), (.paused, .needsYou)]
            for (first, second) in pairs {
                let a = try #require(measurements[first]), b = try #require(measurements[second])
                #expect(abs(a.status.minX - b.status.minX) <= 0.5, "the status pill's leading edge stays put")
                if first == .working {
                    #expect(abs(a.status.width - b.status.width) <= 0.5, "Working reserves Checking's pill width")
                }
                #expect(Set(a.actions.keys) == Set(b.actions.keys))
                for label in a.actions.keys {
                    let af = try #require(a.actions[label]), bf = try #require(b.actions[label])
                    #expect(abs(af.minX - bf.minX) <= 0.5 && abs(af.minY - bf.minY) <= 0.5 && abs(af.width - bf.width) <= 0.5,
                            "\(label) stays put with identical metadata and action sets")
                }
            }
        }
    }

    @MainActor
    private static func scaling() async throws {
        AccessibilityNode.enable()
        for size in [NWGoalSize.desktop, .touch] {
            ThemeStore.shared.textScale = 1
            let normal = dock(.paused, size: size) { _ in }
            defer { normal.close() }
            let base = try await measure(normal, state: .paused, size: size)
            ThemeStore.shared.textScale = 1.5
            let large = dock(.paused, size: size) { _ in }
            defer { large.close() }
            let scaled = try await measure(large, state: .paused, size: size)
            #expect(scaled.card.height > base.card.height, "the card grows rather than clipping larger text")
            #expect(scaled.status.width > base.status.width && scaled.status.height > base.status.height, "the pill grows with text size")
            let resume = try #require(scaled.actions["Resume goal"]), baseResume = try #require(base.actions["Resume goal"])
            #expect(resume.width > baseResume.width, "Resume grows to fit its larger label")
        }
    }
}

@MainActor
private extension AccessibilityNode {
    var goalIsEnabled: Bool {
        let selector = NSSelectorFromString("isAccessibilityEnabled")
        guard object.responds(to: selector) else { return false }
        typealias Call = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(object.method(for: selector), to: Call.self)(object, selector)
    }

    /// Set the field's AX value, not its first responder or a posted key event.
    @discardableResult
    func setGoalValue(_ value: String) -> Bool {
        let selector = NSSelectorFromString("setAccessibilityValue:")
        guard object.responds(to: selector) else { return false }
        typealias Call = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        unsafeBitCast(object.method(for: selector), to: Call.self)(object, selector, value as NSString)
        // AppKit's AX setter updates the cell but does not notify SwiftUI's text binding.
        // Deliver the native edit callback directly; no focus claim or input event is needed.
        let field = object as? NSTextField ?? (object as? NSCell)?.controlView as? NSTextField
        field?.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        return true
    }
}
