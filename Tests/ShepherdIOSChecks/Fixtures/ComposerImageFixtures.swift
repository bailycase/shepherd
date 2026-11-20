import Foundation
import UIKit
import UniformTypeIdentifiers
import ShepherdCore
import ShepherdRemote

private func check(_ ok: Bool, _ message: String) {
    FixtureCheck.report("FIXTURE CHECK \(ok ? "ok" : "FAILED"): \(message)")
}

extension FixtureCatalog {
    /// The composer with images waiting (S6): chips from two screenshots, and a mixed drop where the PDF is refused with a message
    /// and the screenshot still attaches. Both go through the same `ComposerState.attach(providers:)` a drop or paste calls.
    static var composerImages: [FixtureScreen] {
        let thread = FixtureData.ref(FixtureData.preview)
        func screen(_ name: String, prepare: @escaping @MainActor (ComposerState) async -> Void,
                    verify: @escaping @MainActor (ComposerState) -> Void) -> FixtureScreen {
            FixtureScreen(name: name, hosts: ThreadFixtures.hosts(), routes: [.thread(thread)], prepare: { app in
                let store = app.threads.store(for: thread)
                await FixtureWindows.wait("the thread", seconds: 20) { !store.rows.isEmpty }
                let state = ComposerStates.shared.state(for: thread)
                store.draft = "Does the settings page match the mock?"
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
                report.suggestedName = "Q3 report.pdf"
                await state.attach(providers: [picture, report])
            }, verify: { state in
                check(state.attachments.count == 1, "the screenshot of a mixed drop attaches")
                check(state.attachmentError == "Q3 report.pdf isn't an image. Only images can be attached here.",
                                   "the PDF is refused with a message")
            }),
        ]
    }
}
