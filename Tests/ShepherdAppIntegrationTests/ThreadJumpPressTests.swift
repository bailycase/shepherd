import AppKit
import ShepherdRemote
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

@Suite("Jump to latest control", .integrationTimeLimit)
struct ThreadJumpPressTests {
    @Test func jumpingReattachesTheDetachedReaderInEachState() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors {
                for native in [false, true] {
                    for running in [false, true] {
                        try await Self.pressingJump(native: native, running: running)
                    }
                }
            }
        }
    }

    @MainActor
    private static func pressingJump(native: Bool, running: Bool) async throws {
        AccessibilityNode.enable()
        let host = ThreadTailFlowTests.FlowHost(turns: 85, mix: .giant)
        let deck = ThreadTailFlowTests.Deck(host: host, size: CGSize(width: 1180, height: 900), native: native)
        var phase = "open", completed = false
        defer {
            if !completed {
                print("Jump failure phase=\(phase), native=\(native), running=\(running), \(deck.reading.map(String.init(describing:)) ?? "no scroll view")")
                let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RUNNER_TEMP"] ?? NSTemporaryDirectory())
                    .appendingPathComponent("shepherd-completion-repro")
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let image = try ThreadWindowCapture.image(deck.window.window)
                    let bitmap = NSBitmapImageRep(cgImage: image)
                    let prefix = "jump-\(native)-\(running)-\(phase)"
                    try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(prefix + ".png"))
                    let evidence: [String: Any] = ["phase": phase, "native": native, "running": running,
                        "reading": deck.reading.map(String.init(describing:)) ?? "none",
                        "following": deck.tailGuard.following, "rows": deck.store.rows.count,
                        "visible": deck.tailGuard.visible,
                        "pageFrame": NSStringFromRect(deck.page.frame)]
                    try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])
                        .write(to: directory.appendingPathComponent(prefix + ".json"))
                } catch { print("Jump failure capture unavailable") }
            }
            deck.close()
        }
        let jump = {
            deck.layout()
            return AccessibilityNode.all(under: deck.page).first { $0.label == "Jump to latest" }
        }
        try await deck.open()
        phase = "streaming-tail"
        let reply = ThreadBlankScreenTests.reply("jump-live", ThreadBlankScreenTests.prose(12, 85), at: ThreadBlankScreenTests.base + 9_000_000)
        await deck.publish(running: true, provisional: [reply])
        try await deck.expectTail("before detaching")
        phase = "detach"
        deck.command(.previousTurn)
        try await eventuallyOnMain("reader above the tail with jump control drawn, native=\(native), running=\(running)") {
            guard let reading = deck.state().reading else { return false }
            return !deck.tailGuard.following && reading.distance > NativeScrollFollower.threshold && jump() != nil
        }
        phase = "requested-state"
        if !running {
            await deck.publish(running: false, provisional: []) { $0.all.append(reply) }
        }
        try await eventuallyOnMain("jump control in the requested state") {
            deck.store.running == running && jump() != nil
        }
        phase = "press"
        let control = try ControlPress.press("Jump to latest", under: deck.page)
        #expect(ControlPress.undersized([control], minimum: .desktop).isEmpty)
        try await eventuallyOnMain("press attaches the reader") { deck.tailGuard.following }
        try await deck.expectTail("after pressing Jump to latest")
        try await eventuallyOnMain("pressed jump reaches the measured tail") {
            guard let reading = deck.state().reading else { return false }
            return abs(reading.distance) <= NativeScrollFollower.threshold
        }
        try await eventuallyOnMain("attached reader has no jump control") {
            jump() == nil
        }
        completed = true
    }
}
