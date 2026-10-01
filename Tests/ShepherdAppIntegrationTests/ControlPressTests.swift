import AppKit
import ShepherdTestSupport
import SwiftUI
import Testing

/// `ControlPress` over a tiny view of its own: it presses what is a control, says so when it is
/// not one or cannot be pressed, and measures what a person can hit. Each scenario runs in its own
/// process because attaching to SwiftUI's accessibility tree is process-wide (see `ControlPress`).
@Suite("Control press", .integrationTimeLimit)
struct ControlPressTests {
    @Test func pressingAControlRunsItsActionAndReturnsIt() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.pressing() }
        }
    }

    @Test func aPressThatCannotHappenSaysWhyAndListsWhatTheWindowOffers() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.refusing() }
        }
    }

    @Test func hitAreasCatchAControlThatOnlyItsLabelAnswers() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.measuring() }
        }
    }

    // MARK: Scenarios

    @MainActor
    final class Counter {
        var presses: [String] = []
    }

    /// Buttons, a disabled one, a hidden one, a tap gesture that is no button, text that only says it
    /// is one, two with one label, and a segmented row.
    struct Panel: View {
        let counter: Counter
        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Button("Pause") { counter.presses.append("pause") }
                Button("Resume") { counter.presses.append("resume") }.disabled(true)
                Button("Secret") { counter.presses.append("secret") }.hidden()
                Text("Clear").onTapGesture { counter.presses.append("clear") }
                Text("Fake").accessibilityAddTraits(.isButton)
                Button("Edit") { counter.presses.append("edit 1") }
                Button("Edit") { counter.presses.append("edit 2") }
                HStack(spacing: 4) {
                    Button("Standard") { counter.presses.append("standard") }
                    Button("Fast") { counter.presses.append("fast") }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Speed")
            }
            .padding(20)
        }
    }

    @MainActor
    static func pressing() async throws {
        AccessibilityNode.enable()
        let counter = Counter()
        let window = OffscreenWindow(size: CGSize(width: 400, height: 400), dark: true, Panel(counter: counter))
        defer { window.close() }

        let pressed = try window.press("Pause")
        #expect(counter.presses == ["pause"], "the press ran the button's action")
        #expect(pressed.label == "Pause" && pressed.role == ControlRole.button && pressed.isEnabled)
        #expect(pressed.frame.width > 0 && pressed.frame.height > 0, "and the control it returns has its frame")

        try window.press("Fast", in: "Speed")
        try window.press("Edit", nth: 1)
        #expect(counter.presses == ["pause", "fast", "edit 2"], "a group scopes the search and nth picks among equals")
    }

    @MainActor
    static func refusing() async throws {
        AccessibilityNode.enable()
        let counter = Counter()
        let window = OffscreenWindow(size: CGSize(width: 400, height: 400), dark: true, Panel(counter: counter))
        defer { window.close() }

        func refusal(_ body: () throws -> Void) -> ControlPressError? {
            do { try body() } catch let error as ControlPressError { return error } catch {}
            return nil
        }

        let missing = try #require(refusal { try window.press("Pasue") }, "a label nobody has is refused")
        #expect(missing.reason == .notFound)
        #expect(missing.description.contains("\"Pasue\"") && missing.description.contains("\"Pause\"") && missing.description.contains("\"Fast\""),
                "and the message lists the labels that exist: \(missing)")

        let hidden = try #require(refusal { try window.press("Secret") }, "a hidden control is not in the tree")
        #expect(hidden.reason == .notFound)
        #expect(!(hidden.description.components(separatedBy: "offers: ").last ?? "").contains("Secret"), "and is not listed among what the window offers: \(hidden)")

        let tap = try #require(refusal { try window.press("Clear") }, "a tap gesture on text is not a button")
        #expect(tap.reason == .notFound, "\(tap)")

        let fake = try #require(refusal { try window.press("Fake") }, "text that only says it is a button takes no press")
        #expect(fake.reason == .refused, "\(fake)")

        let disabled = try #require(refusal { try window.press("Resume") }, "a disabled button takes no press")
        #expect(disabled.reason == .disabled && disabled.description.contains("disabled"), "\(disabled)")

        let twins = try #require(refusal { try window.press("Edit") }, "two buttons with one label are ambiguous")
        #expect(twins.reason == .ambiguous, "\(twins)")
        let past = try #require(refusal { try window.press("Edit", nth: 2) })
        #expect(past.reason == .notFound)

        let wrongGroup = try #require(refusal { try window.press("Pause", in: "Speed") }, "a group holds only its own controls")
        #expect(wrongGroup.reason == .notFound)

        #expect(counter.presses.isEmpty, "none of the refused presses ran an action: \(counter.presses)")
    }

    /// A plain-style button whose background is clear answers a click only over its label, and the
    /// tree's frame says so; with a content shape the whole padded rectangle is the control.
    @MainActor
    static func measuring() async throws {
        AccessibilityNode.enable()
        struct Rows: View {
            var body: some View {
                VStack(alignment: .leading, spacing: 20) {
                    Button { } label: { Text("Label only").padding(20) }.buttonStyle(.plain)
                    Button { } label: { Text("Whole button").padding(20).contentShape(Rectangle()) }.buttonStyle(.plain)
                    Button { } label: { Text("Tiny").font(.system(size: 9)) }.buttonStyle(.plain)
                }
                .padding(20)
            }
        }
        let window = OffscreenWindow(size: CGSize(width: 400, height: 300), dark: true, Rows())
        defer { window.close() }
        let controls = window.controls()
        let desktop = ControlPress.undersized(controls, minimum: .desktop).compactMap(\.label)
        #expect(desktop.contains("Label only"), "padding with no content shape is not part of the control, so its frame is the label's: \(controls)")
        #expect(desktop.contains("Tiny"), "a 9pt label is under 24pt: \(controls)")
        #expect(!desktop.contains("Whole button"), "a padded button with a content shape is the whole rectangle: \(controls)")
        let touch = ControlPress.undersized(controls, minimum: .touch).compactMap(\.label)
        #expect(touch.sorted() == ["Label only", "Tiny"], "the whole 122×56 button clears a finger's 44pt: \(controls)")
    }
}
