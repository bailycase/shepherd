import Foundation
import UIKit
import UniformTypeIdentifiers
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

private func check(_ ok: Bool, _ message: String) {
    FixtureCheck.report("FIXTURE CHECK \(ok ? "ok" : "FAILED"): \(message)")
}

/// A made-up project ("acme-web") for these screens: the repo is public, so renders never show Shepherd's own paths or tasks.
private enum AcmeWeb {
    static let agent = AgentID(rawValue: "agent-acme-settings")
    static let space = Space(id: SpaceID(rawValue: "space-acme-web"), name: "acme-web", path: "/Users/dev/acme-web")

    static func hosts() -> [FixtureHostData] {
        typealias F = FixtureData
        var snapshot = F.snapshot([
            F.user("a1", "The settings page looks off on narrow screens. Can you check it against the mock?"),
            F.assistant("a2", "I'll compare the layout with the mock and fix the spacing.", at: 4_000),
            F.tool("a3", "read", args: #"{"path":"src/pages/Settings.tsx"}"#, output: "export function Settings() {", at: 20_000),
            F.tool("a4", "edit", args: #"{"path":"src/pages/Settings.tsx","oldText":"gap-2","newText":"gap-4"}"#, output: "Edited", at: 60_000),
            F.assistant("a5", "The form columns were stacking with too little gap. I widened it to match the mock.", at: 90_000),
        ])
        snapshot.supportedActions = ["send", "abort", "answer", "queue", "setModel", "setThinking", "sendImages"]
        snapshot.stats = NativeThreadStats(contextTokens: 42_300, contextWindow: 200_000)
        let agent = F.agent(agent, "Fix settings page layout", .idle, space: space)
        var host = FixtureHostData(id: F.studio, name: "Studio", state: ShepherdState(spaces: [space], agents: [agent]),
                                   threads: [self.agent: snapshot])
        host.models = ["anthropic/claude-opus", "anthropic/claude-sonnet"]
        return [host]
    }
}

extension FixtureCatalog {
    /// The composer with images waiting (S6): chips from two screenshots, and a mixed drop where the PDF is refused with a message
    /// and the screenshot still attaches. Both go through the same `ComposerState.attach(providers:)` a drop or paste calls.
    static var composerImages: [FixtureScreen] {
        let thread = FixtureData.ref(AcmeWeb.agent)
        func screen(_ name: String, prepare: @escaping @MainActor (ComposerState) async -> Void,
                    verify: @escaping @MainActor (ComposerState) -> Void) -> FixtureScreen {
            FixtureScreen(name: name, hosts: AcmeWeb.hosts(), routes: [.thread(thread)], prepare: { app in
                let store = app.threads.store(for: thread)
                await FixtureWindows.wait("the thread", seconds: 20) { !store.rows.isEmpty }
                let state = ComposerStates.shared.state(for: thread)
                store.draft = "Does the settings page match the mock now?"
                await prepare(state)
            }, verify: { _ in verify(ComposerStates.shared.state(for: thread)) })
        }
        return [
            screen("composer-images", prepare: { state in
                let first = NewThreadFixtures.image(.systemTeal, name: "settings-light")
                let second = NewThreadFixtures.image(.systemOrange, name: "settings-dark")
                await state.attach([first, second].compactMap { $0 }.map { ($0.image.data, $0.name) })
            }, verify: { state in
                check(state.attachments.count == 2 && state.attachmentError == nil, "two screenshots attach as chips")
            }),
            screen("composer-images-refused", prepare: { state in
                let png = NewThreadFixtures.image(.systemTeal, name: "settings-light")?.image.data ?? Data()
                let picture = NSItemProvider(item: png as NSData, typeIdentifier: UTType.png.identifier)
                picture.suggestedName = "settings-light.png"
                let report = NSItemProvider(item: Data("%PDF-1.4".utf8) as NSData, typeIdentifier: UTType.pdf.identifier)
                report.suggestedName = "design-notes.pdf"
                state.attach(providers: [picture, report])
                await FixtureWindows.wait("the drop", seconds: 20) { state.pendingImports == 0 }
            }, verify: { state in
                check(state.attachments.count == 1, "the screenshot of a mixed drop attaches")
                check(state.attachmentError == "design-notes.pdf isn't an image. Only images can be attached here.",
                                   "the PDF is refused with a message")
            }),
        ]
    }
}
