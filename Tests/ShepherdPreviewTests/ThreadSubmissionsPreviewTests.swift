import AppKit
import Foundation
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp
@testable import ShepherdUI

/// Sends the store captured but the host has not accepted (UX-02), drawn from a real store driven
/// through a refusing, a silent and a holding host: sending, refused (Restore waits for an empty
/// composer) and unknown (Discard only). And the window while the workspace opens.
@Suite("Thread submissions previews", .mainActorExclusive,
       .enabled(if: Preview.enabled && !Preview.liveModel, "set SHEPHERD_PREVIEW_DIR (without SHEPHERD_LIVE_MODEL) to render previews"))
@MainActor
struct ThreadSubmissionsPreviewTests {
    @MainActor final class Host {
        var answers: [Bool?] = []  // true refuse, nil unknown, false hold forever
        let snapshot = NativeThreadSnapshot(piSessionID: "session", generation: "generation", revision: 1, running: false,
                                            supportedActions: ["send", "sendImages"], dialogsSupported: true, dialogs: [],
                                            messages: [], provisional: [], clipped: false)
        func request(_ request: NativeThreadRequest) async throws -> NativeThreadResult {
            guard case .send = request else { return .snapshot(value: snapshot) }
            switch answers.removeFirst() {
            case true?: return .failure(code: "refused", message: "The agent refused it.")
            case nil: throw CancellationError()
            case false?:
                let (never, _) = AsyncStream<Void>.makeStream()
                for await _ in never {}
                throw CancellationError()
            }
        }
    }

    @Test func sendingRefusedAndUnknown() async throws {
        let host = Host()
        host.answers = [nil, true, false]
        let store = NativeThreadStore(startingLimit: .seconds(60)) { _ in
            let (never, _) = AsyncStream<Void>.makeStream()
            for await _ in never {}
            throw CancellationError()
        }
        let loop = Task { await store.run(request: { try await host.request($0) }) }
        defer { loop.cancel() }
        try await eventuallyOnMain("ready") { store.ready }
        let input = ThreadInput()
        store.draft = "Compare the header spacing with the board before merging."
        await ComposerImageCapture.send(store: store, input: input, delivery: .followUp)
        // Refused (sent straight from the store, so it is not put back): it stays in the thread, Restore held by the new draft.
        store.draft = "Rename the token to bgSelected and update both themes."
        await store.send(images: [NativeImage(mimeType: "image/png", data: Data([1]), name: "screen.png")], delivery: .followUp)
        store.draft = "Then run the snapshot tests."
        let held = Task { await ComposerImageCapture.send(store: store, input: input, delivery: .followUp) }
        defer { held.cancel() }
        try await eventuallyOnMain("three records") { store.submissions.count == 3 }
        store.draft = "A new draft"
        try await Preview.renderMatrix("thread-submissions", size: CGSize(width: 720, height: 520)) {
            ScrollView {
                VStack(alignment: .leading, spacing: AppLayout.turnSpacing) { ThreadSubmissions(store: store, input: input) }
                    .padding(SH.Space.xxl)
            }
            .background(Color.sh.bgWindow)
        }
    }

    @Test func launchSurfaceWhileTheWorkspaceOpens() async throws {
        try await Preview.render("launch-surface-slow", size: CGSize(width: 720, height: 420)) { LaunchSurface(slow: true) }
    }
}
