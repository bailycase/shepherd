import Foundation
import UIKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// Platform parity S3: the seven surfaces that have no fold code, rendered by the shipped views in whatever posture the
// run puts the device in (`run-simulator.sh -f closed|book|open`, `-r landscape`, iPad portrait and landscape), made-up
// "acme-web" data. Each prints one `FIXTURE CHECK ok: <surface> …` line with the layout the posture produced and the
// window's size. The surface is whatever the posture shows: on compact width Search is the pushed screen and Designs the
// phone's list, since the palette and the iPad's design list are regular-width screens.
//
//   s3-overview  s3-files  s3-palette  s3-newthread  s3-addhost  s3-designs  s3-browser   the seven surfaces
//   s3-palette-narrow, s3-files-narrow                                                    the palette's 420 pt list and
//                                                                                         Files' 210 pt tree in a 680 pt window
//   s3-header-680, s3-header-720, s3-header-800                                           the thread header's branch chip in
//                                                                                         a narrow window beside its pane
//   s3-survive                                                                            editor, terminal and sheet open,
//                                                                                         folded shut and open again (Duo, `-f open`)
//   s3-survive-window                                                                     the same in an iPad window dragged
//                                                                                         across the compact line
extension FixtureCatalog {
    static var resize: [FixtureScreen] {
        let preview = FixtureData.ref(FixtureData.preview)
        let palette: @MainActor (MobileApp, String) async -> Void = { app, surface in
            if app.navigator.layout == .pad {
                app.navigator.open(.thread(preview))
                app.navigator.present(.search(.palette(query: "review")))
            } else {
                app.navigator.open(.search(.search(query: "review")))
            }
            await ResizeFixtures.settled(app, surface)
        }
        let files: @MainActor (MobileApp, String) async -> Void = { app, surface in
            await ResizeFixtures.openFiles(app)
            await ResizeFixtures.settled(app, surface)
        }
        return [
            FixtureScreen(name: "s3-overview", hosts: ResizeFixtures.acme(HomeFixtureData.fleet()), prepare: { app in
                await HomeFeed.of(app.hosts).refresh()
                if app.navigator.layout == .pad { await OverviewOpenCheck.hideSidebar(app) }
                await ResizeFixtures.settled(app, "Home overview")
            }),
            FixtureScreen(name: "s3-files", hosts: FilesPadFixture.hosts(), routes: [.thread(FilesPadFixture.ref), .sidePane(.files(FilesPadFixture.ref))],
                          prepare: { app in await files(app, "Files") }),
            FixtureScreen(name: "s3-palette", hosts: ResizeFixtures.acme(SearchFixtures.hosts()), prepare: { app in await palette(app, "Search") }),
            FixtureScreen(name: "s3-newthread", hosts: ResizeFixtures.acme(NewThreadFixtures.hosts()), routes: NewThreadFixtures.behind,
                          presented: NewThreadFixtures.compose, prepare: { app in
                              await NewThreadFixtures.form { $0.prompt = ResizeFixtures.sheetText }
                              await ResizeFixtures.settled(app, "New thread")
                          }),
            FixtureScreen(name: "s3-addhost", hosts: ResizeFixtures.acme(FixtureData.hosts()), presented: .settings(.host(nil)),
                          prepare: { app in await ResizeFixtures.settled(app, "Add a Mac") }, setup: { FixtureData.pairing(code: "4829") }),
            FixtureScreen(name: "s3-designs", hosts: ResizeFixtures.acme(DesignsFixtures.hosts(updating: false)), prepare: { app in
                await DesignsFixtures.listed(app)
                if app.navigator.layout == .pad {
                    app.navigator.open(.padDesign(.list))
                    let ref = PadDesignRef(host: FixtureData.studio, design: DesignsFixtures.checkout)
                    await FixtureWindows.wait("design thumbnail", seconds: 30) { PadDesignThumbnails.shared.image(ref) != nil }
                } else {
                    app.navigator.open(.designs(.list))
                    await DesignsFixtures.drawn(images: 4)
                }
                await ResizeFixtures.settled(app, "Designs")
            }),
            FixtureScreen(name: "s3-browser", hosts: ResizeFixtures.acme(BrowserFixture.hosts(running: true, html: BrowserFixture.checkout)),
                          routes: [.thread(preview), .browser(.page(preview))], prepare: { app in
                              await FixtureCheck.wait("page loaded through the tunnel", seconds: 30) {
                                  guard let page = MobileBrowsers.shared.existing(preview) else { return false }
                                  return page.url != nil && !page.isLoading && page.webView?.url != nil
                              }
                              await ResizeFixtures.settled(app, "Browser")
                          }),
            // The two fixed columns, in a window 680 pt wide (narrow, regular: 640 pt is already compact): the palette's results list is 420 pt of it.
            FixtureScreen(name: "s3-palette-narrow", hosts: ResizeFixtures.acme(SearchFixtures.hosts()),
                          prepare: { app in await palette(app, "Search palette, 680 pt window") }, frameWidth: ResizeFixtures.narrow),
            FixtureScreen(name: "s3-files-narrow", hosts: FilesPadFixture.hosts(), routes: [.thread(FilesPadFixture.ref), .sidePane(.files(FilesPadFixture.ref))],
                          prepare: { app in await files(app, "Files, 680 pt window") }, frameWidth: ResizeFixtures.narrow),
            // The thread header with a long title and branch, in windows 680, 720 and 800 pt wide. The names stay literal: `run-simulator.sh` reads them from this file.
            FixtureScreen(name: "s3-header-680", hosts: ResizeFixtures.longTitle(FilesPadFixture.hosts()),
                          routes: [.thread(FilesPadFixture.ref), .sidePane(.files(FilesPadFixture.ref))],
                          prepare: { app in await files(app, "Thread header, 680 pt window") }, frameWidth: 680),
            FixtureScreen(name: "s3-header-720", hosts: ResizeFixtures.longTitle(FilesPadFixture.hosts()),
                          routes: [.thread(FilesPadFixture.ref), .sidePane(.files(FilesPadFixture.ref))],
                          prepare: { app in await files(app, "Thread header, 720 pt window") }, frameWidth: 720),
            FixtureScreen(name: "s3-header-800", hosts: ResizeFixtures.longTitle(FilesPadFixture.hosts()),
                          routes: [.thread(FilesPadFixture.ref), .sidePane(.files(FilesPadFixture.ref))],
                          prepare: { app in await files(app, "Thread header, 800 pt window") }, frameWidth: 800),
            FixtureScreen(name: "s3-survive", hosts: ResizeFixtures.surviveHosts(), routes: [.thread(preview)],
                          prepare: { app in await ResizeFixtures.survive(app) }),
            // The same on an iPad, in a window dragged narrower than the compact line (640 pt) and wider again (760 pt).
            FixtureScreen(name: "s3-survive-window", hosts: ResizeFixtures.surviveHosts(), routes: [.thread(preview)],
                          prepare: { app in await ResizeFixtures.survive(app, widths: (shut: 640, open: 760)) }, frameWidth: 760),
        ]
    }
}

@MainActor
enum ResizeFixtures {
    static let narrow: CGFloat = 680

    /// What the shared fixtures say that belongs to the Shepherd repo or its own work, in the made-up acme-web's words.
    nonisolated static let rewrites: [(String, String)] = [
        ("Sources/ShepherdApp/DesktopNativeThreadView.swift", "src/pages/Cart.tsx"),
        ("App/iOS/ThreadView.swift", "src/components/CartRow.tsx"),
        ("Investigate SwiftUI live preview", "Investigate slow cart page"), ("Plan shepherd extensions", "Plan promo code rollout"),
        ("Dock review pane", "Move order summary"), ("Fix remote subagent deletion", "Fix stale cart totals"),
        ("Fix terminal output buffer", "Fix order export buffer"), ("Queue steering polish", "Polish the cart drawer"),
        ("Restyle the native UI on the new tokens.", "Restyle the product page on the new tokens."), ("Restyle native UI", "Restyle product page"),
        ("Dock the review pane beside the thread.", "Move the order summary beside the payment form."),
        ("Where should review dock?", "Where should the order summary go?"),
        ("Beside the thread", "Beside the form"), ("Over the thread", "Above the form"), ("In its own window", "On its own page"),
        ("pi/swiftui-previews", "fix/slow-cart"), ("pi/shepherd-extensions", "feat/promo-rollout"), ("pi/refund-events", "feat/refund-events"),
        ("chore/remove-homarr", "chore/remove-banner"),
        ("Remove the visible speaker labels, and make tool rows show something useful instead of just \"complete\".",
         "Remove the duplicate totals row, and make cart rows show something useful instead of just \"pending\"."),
        ("Remove the visible speaker labels", "Remove the duplicate totals row"),
        ("I'll finish removing the speaker labels and make tool rows show a useful command or path preview.",
         "I'll finish removing the totals row and make cart rows show a useful status preview."),
        ("The labels live in two views; the tool rows need a preview line.", "The totals live in two components; the cart rows need a status line."),
        ("Plan the shepherd extensions and build the first one.", "Plan the promo code rollout and build the first step."),
        ("Reading the extension points first.", "Reading the promo code module first."),
        ("import SwiftUI", "import React"), ("swift test --filter ThreadRows", "pnpm test cart"), ("swift build", "pnpm build"),
        ("Compiling ShepherdCore\nCompiling ShepherdProtocol", "Compiling cart\nCompiling checkout"),
        ("✔ Test run with 1 test in 1 suite passed after 0.2 seconds.", "✓ 1 test passed in 0.2s"),
        ("Removed the visible speaker labels and the desktop gutter. User-message fills still distinguish the conversation.\n\nFocused regression test and Mac Dev build passed.",
         "Removed the duplicate totals row and the extra gutter. The remaining rows still show each item.\n\nFocused regression test and local build passed."),
        ("fix/tool-rows-show-the-command-or-path-instead-of-complete", "fix/cart-rows-show-the-status-instead-of-pending"),
        ("feat/mobile-new-thread-pickers", "feat/mobile-cart-pickers"), ("chore/bump-swift-term", "chore/bump-vite"),
        ("spike/duo-fold-aware-composer-layout-experiments", "spike/two-column-cart-layout-experiments"),
        ("docs/remote-protocol", "docs/api-reference"), ("fix/review-scope-menu", "fix/promo-scope-menu"),
        ("open the review pane beside the thread once the preview settles, then", "open the review panel beside the cart once the totals settle, then"),
        ("the review extension reads the diff before it asks you", "the review step reads the diff before it asks you"),
        ("a review of the buffer flush found two copies of each", "a review of the export flush found two copies of each"),
    ]

    /// `value` with every `rewrites` entry applied to the text it encodes to (a snapshot, a state, a reply).
    nonisolated static func rewritten<T: Codable>(_ value: T) -> T {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        func escaped(_ text: String) -> String {
            (try? encoder.encode(text)).flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? text
        }
        guard let data = try? encoder.encode(value), var json = String(data: data, encoding: .utf8) else { return value }
        for (from, to) in rewrites { json = json.replacingOccurrences(of: escaped(from), with: escaped(to)) }
        return (try? JSONDecoder().decode(T.self, from: Data(json.utf8))) ?? value
    }

    /// The made-up names the report shows: the shared fixtures' repos, ids and paths are already acme-web and acme-api;
    /// this rewrites the thread names, branches and answers that still name Shepherd's own work.
    static func acme(_ hosts: [FixtureHostData]) -> [FixtureHostData] {
        var hosts = hosts
        for index in hosts.indices {
            hosts[index].state = rewritten(hosts[index].state)
            hosts[index].threads = rewritten(hosts[index].threads)
            if let reply = hosts[index].reply { hosts[index].reply = { request in reply(request).map { rewritten($0) } } }
        }
        return hosts
    }

    /// A thread named the way people name them, on a branch to match: the header's title and branch chip compete for the width.
    static func longTitle(_ hosts: [FixtureHostData]) -> [FixtureHostData] {
        var hosts = hosts
        hosts[0].state.agents[0].name = "Stop the pay button jumping when the promo code field opens"
        hosts[0].state.agents[0].worktreeBranch = "fix/pay-button-jump-on-promo-open"
        hosts[0].state.agents[0].checkout = AgentCheckout(branch: "fix/pay-button-jump-on-promo-open", changedFiles: 2)
        return hosts
    }

    static func window() -> UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.keyWindow
    }

    /// Lets the screen settle, then records the layout the posture produced and the window it is in.
    static func settled(_ app: MobileApp, _ surface: String) async {
        try? await Task.sleep(for: .seconds(2))
        // The software keyboard (the palette and the sheet focus a field) would cover half the shot.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        try? await Task.sleep(for: .seconds(1))
        let size = window()?.bounds.size ?? .zero
        let traits = window()?.traitCollection.horizontalSizeClass == .regular ? "regular" : "compact"
        FixtureCheck.report("FIXTURE CHECK ok: \(surface): \(app.navigator.layout == .pad ? "split view" : "phone shell"), "
                            + "window \(Int(size.width))×\(Int(size.height)) pt, \(traits) width")
    }

    /// Files over the thread: the tree opened to a folder and a file read in the editor.
    static func openFiles(_ app: MobileApp) async {
        let model = ThreadFilesStores.shared.model(for: FilesPadFixture.ref, hosts: app.hosts)
        await FixtureCheck.wait("the Files tree", seconds: 20) { model.phase == .loaded }
        for folder in ["src", "src/components"] { await model.toggle(folder) }
        await model.open(FilesPadFixture.checkout)
    }

    // MARK: Survival

    /// Studio's thread with a terminal tab, acme-web's Files tree and the answers New thread asks for.
    static func surviveHosts() -> [FixtureHostData] {
        var hosts = TerminalFixture.hosts()
        let terminal = hosts[0].reply
        let files = FilesPadFixture.hosts()[0].reply
        let creation = NewThreadFixtures.hosts()[0].reply
        hosts[0].models = NewThreadFixtures.models
        hosts[0].reply = { request in terminal?(request) ?? files?(request) ?? creation?(request) }
        return acme(hosts)
    }

    static let draftEdit = "// edited on the Duo, not saved yet\n"
    static let sheetText = "Show the order total under the promo field instead of “pending”, and add a test for it."

    /// An unsaved edit in the Files editor, a terminal and a half-filled New thread sheet, then the Duo folds shut and opens
    /// again. One line per object and stage, `FIXTURE CHECK survival <object> (<stage>): kept|lost`; none of them fails the run.
    static func survive(_ app: MobileApp, widths: (shut: CGFloat, open: CGFloat)? = nil) async {
        let navigator = app.navigator
        let ref = FilesFixture.ref
        let path = FilesPadFixture.checkout
        guard navigator.layout == .pad else {
            FixtureCheck.report("FIXTURE CHECK ok: not run, this needs regular width: the Duo posed open (-f open) or s3-survive-window")
            return
        }

        // Set up: the terminal on its tab, then Files with an edit over the file, then the sheet over both.
        await TerminalFixture.show(ref, in: app)
        let session = MobileTerminals.shared.session(host: ref.host, id: TerminalFixture.shellSession)
        await FixtureCheck.wait("terminal surface mounted", seconds: 10) { session.surface?.window != nil }
        let terminalView = session.surface.map(ObjectIdentifier.init)
        let model = ThreadFilesStores.shared.model(for: ref, hosts: app.hosts)
        navigator.open(.sidePane(.files(ref)))
        await FixtureCheck.wait("the Files tree", seconds: 20) { model.phase == .loaded }
        for folder in ["src", "src/components"] { await model.toggle(folder) }
        await model.open(path)
        guard let original = model.edits[path]?.text else { FixtureCheck.fail("The file did not open in the editor") }
        model.setText(draftEdit + original, for: path)
        await FixtureCheck.wait("the editor shows the edit", seconds: 10) { visibleEditorShowsCheckout() }
        navigator.present(NewThreadFixtures.compose)
        await NewThreadFixtures.form { $0.prompt = sheetText }
        await FixtureCheck.wait("the sheet shows its text", seconds: 10) { shows(sheetText) }
        FixtureCheck.report("FIXTURE CHECK ok: set up, editor, terminal and sheet open on \(layout(navigator))")

        func report(_ object: String, _ stage: String, _ kept: Bool, _ detail: String) {
            // `FIXTURE CHECK FAILED` would fail the run and drop the PNG; a lost object is a finding, not a failure.
            FixtureCheck.report("FIXTURE CHECK survival \(object) (\(stage)): \(kept ? "kept" : "lost"), \(detail)")
        }
        func look(_ stage: String, editorVisible: Bool) async {
            try? await Task.sleep(for: .seconds(2))
            // The sheet first, as it stands: a kept sheet would cover the pane below, so it is recorded and then dismissed.
            let form = NewThreadModel.active
            report("sheet", stage, navigator.presented != nil && form?.prompt == sheetText,
                   "presented: \(navigator.presented != nil), form \(form == nil ? "gone" : "present"), prompt \(form?.prompt.count ?? 0) of \(sheetText.count) characters, "
                   + "text on screen: \(shows(sheetText))")
            let edit = model.edits[path]
            // Once the window is regular again, dismiss the sheet and expose the Files pane, then look at the editor a person
            // would see: a model that kept the edit is not enough if the pane is blank, covered or clipped.
            var onScreen = true
            if editorVisible {
                navigator.dismissPresented()
                navigator.sidePane.show(.files)
                try? await Task.sleep(for: .seconds(1)) // a sheet or pane the switch just removed is gone by now
                let deadline = Date().addingTimeInterval(10)
                while !visibleEditorShowsCheckout(), Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
                onScreen = visibleEditorShowsCheckout()
            }
            report("editor", stage, edit?.isDirty == true && edit?.text.hasPrefix(draftEdit) == true && onScreen,
                   "the unsaved edit \(edit?.isDirty == true ? "is" : "is not") in the file's model\(editorVisible ? ", visible editor shows Checkout.tsx with the edit, uncovered and unclipped: \(onScreen)" : "")")
            report("terminal", stage, session.surface.map(ObjectIdentifier.init) == terminalView,
                   "its session \(session.surface == nil ? "has no view" : session.surface.map(ObjectIdentifier.init) == terminalView ? "keeps the same view" : "got a new view")")
        }

        for (pose, closed) in [("closed", true), ("open", false)] {
            if let widths, let framed = FixtureWindows.shared.framed {
                // A window's edge dragged across the compact line.
                let width = closed ? widths.shut : widths.open
                framed.frame = CGRect(x: ((framed.windowScene?.coordinateSpace.bounds.width ?? width) - width) / 2, y: 0,
                                      width: width, height: framed.frame.height)
            } else {
                print("FIXTURE POSE \(pose)")
                fflush(stdout)
            }
            // Without a hinge to move (a run without -f) the layout never changes.
            let deadline = Date().addingTimeInterval(20)
            while navigator.layout != (closed ? .phone : .pad), Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
            guard navigator.layout == (closed ? .phone : .pad) else {
                FixtureCheck.report("FIXTURE CHECK ok: not run, the layout never became \(pose) (the Duo needs -f open)")
                return
            }
            await look(pose, editorVisible: !closed)
            FixtureCheck.report("FIXTURE CHECK ok: \(pose), \(layout(navigator))")
        }

        // The terminal's own tab, then back to the editor: its view is the one it had, drawn again.
        navigator.sidePane.show(.terminal)
        let mounting = Date().addingTimeInterval(10)
        while session.surface?.window == nil, Date() < mounting { try? await Task.sleep(for: .milliseconds(100)) }
        let same = session.surface.map(ObjectIdentifier.init) == terminalView
        report("terminal", "open, on its tab", session.surface?.window != nil && same,
               "\(session.surface?.window != nil ? "mounted" : "not mounted"), \(same ? "the same view" : "a new view")")
        navigator.sidePane.show(.files)
        try? await Task.sleep(for: .seconds(1))
    }

    static func layout(_ navigator: MobileNavigator) -> String {
        "\(navigator.layout == .pad ? "split view" : "phone shell"), tab \(navigator.sidePane.tab.rawValue), pane \(navigator.sidePane.isOpen ? "open" : "closed"), "
            + "pad path \(navigator.padPath.count), home path \(navigator.homePath.count)"
    }

    /// Whether the Files editor (the text view labelled "File contents") that a person sees in the fixture's window holds
    /// Checkout.tsx's code under the unsaved edit, and is drawn in full: not hidden, not clipped by an ancestor or the window,
    /// and not covered by another view (a sheet, a pane). Another window's editor does not count.
    static func visibleEditorShowsCheckout() -> Bool {
        guard let window = FixtureWindows.shared.framed ?? window(), !window.isHidden else { return false }
        func visible(_ view: UIView) -> Bool {
            if view.isHidden || view.alpha < 0.01 { return false }
            if let text = view as? UITextView, text.accessibilityLabel == "File contents" {
                guard text.text.hasPrefix(draftEdit), text.text.contains("export function Checkout") else { return false }
                // Clip the editor's frame by every ancestor, then by the window.
                var shown = text.bounds
                var current: UIView = text
                while let parent = current.superview {
                    shown = parent.convert(shown, from: current)
                    if parent.clipsToBounds || parent === window { shown = shown.intersection(parent.bounds) }
                    current = parent
                }
                let full = text.convert(text.bounds, to: window)
                guard !shown.isNull, shown.width >= full.width - 1, shown.height >= full.height - 1 else { return false }
                // Covered: whatever is hit at the corners and centre of the editor must be the editor.
                let probes = [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.9, y: 0.1), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.1, y: 0.9), CGPoint(x: 0.9, y: 0.9)]
                return probes.allSatisfy { fraction in
                    let point = CGPoint(x: full.minX + full.width * fraction.x, y: full.minY + full.height * fraction.y)
                    let hit = window.hitTest(point, with: nil)
                    return hit === text || hit?.isDescendant(of: text) == true
                }
            }
            return view.subviews.contains(where: visible)
        }
        return visible(window)
    }

    /// Whether any text field, text view or label on screen holds `text`.
    static func shows(_ text: String) -> Bool {
        func visit(_ view: UIView) -> Bool {
            if (view as? UITextView)?.text?.contains(text) == true || (view as? UITextField)?.text?.contains(text) == true
                || (view as? UILabel)?.text?.contains(text) == true { return true }
            return view.subviews.contains(where: visit)
        }
        return UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).contains(where: visit)
    }
}
