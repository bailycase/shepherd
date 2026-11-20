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
//   s3-header-<width>                                                                     the thread header's branch chip in
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
                              await NewThreadFixtures.form()
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
            FixtureScreen(name: "s3-browser", hosts: ResizeFixtures.acme(BrowserFixture.hosts(running: true)),
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
        ] + ResizeFixtures.headerWidths.map { width in
            FixtureScreen(name: "s3-header-\(Int(width))", hosts: ResizeFixtures.longTitle(FilesPadFixture.hosts()),
                          routes: [.thread(FilesPadFixture.ref), .sidePane(.files(FilesPadFixture.ref))],
                          prepare: { app in await files(app, "Thread header, \(Int(width)) pt window") }, frameWidth: width)
        } + [
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
    static let headerWidths: [CGFloat] = [680, 720, 800]

    /// The made-up names the report shows: every fixture host's repos are acme's.
    static func acme(_ hosts: [FixtureHostData]) -> [FixtureHostData] {
        var hosts = hosts
        let names = [FixtureData.shepherdSpace.id: "acme-web", FixtureData.horizonSpace.id: "acme-api"]
        for index in hosts.indices {
            for (spaceIndex, space) in hosts[index].state.spaces.enumerated() {
                guard let name = names[space.id] else { continue }
                hosts[index].state.spaces[spaceIndex].name = name
                hosts[index].state.spaces[spaceIndex].path = "/Users/dev/\(name)"
            }
            for (automationIndex, automation) in hosts[index].state.automations.enumerated() {
                hosts[index].state.automations[automationIndex].cwd = automation.cwd
                    .replacingOccurrences(of: "/Users/dev/Shepherd", with: "/Users/dev/acme-web")
                    .replacingOccurrences(of: "/Users/dev/horizon", with: "/Users/dev/acme-api")
            }
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

    /// Studio's thread with a terminal tab, a readable Files tree and the answers New thread asks for.
    static func surviveHosts() -> [FixtureHostData] {
        var hosts = acme(TerminalFixture.hosts())
        let terminal = hosts[0].reply
        let files = FilesFixture.hosts()[0].reply
        let creation = NewThreadFixtures.hosts()[0].reply
        hosts[0].models = NewThreadFixtures.models
        hosts[0].reply = { request in terminal?(request) ?? files?(request) ?? creation?(request) }
        return hosts
    }

    static let draftEdit = "// edited on the Duo, not saved yet\n"
    static var sheetText: String { NewThreadFixtures.prompt }

    /// An unsaved edit in the Files editor, a terminal and a half-filled New thread sheet, then the Duo folds shut and opens
    /// again. One line per object and stage, `FIXTURE CHECK survival <object> (<stage>): kept|lost`; none of them fails the run.
    static func survive(_ app: MobileApp, widths: (shut: CGFloat, open: CGFloat)? = nil) async {
        let navigator = app.navigator
        let ref = FilesFixture.ref
        let path = "Widgets/NeedsYouWidget.swift"
        guard navigator.layout == .pad else { FixtureCheck.fail("survive needs the Duo posed open (-f open) or a regular-width window") }

        // Set up: the terminal on its tab, then Files with an edit over the file, then the sheet over both.
        await TerminalFixture.show(ref, in: app)
        let session = MobileTerminals.shared.session(host: ref.host, id: TerminalFixture.shellSession)
        await FixtureCheck.wait("terminal surface mounted", seconds: 10) { session.surface?.window != nil }
        let terminalView = session.surface.map(ObjectIdentifier.init)
        let model = ThreadFilesStores.shared.model(for: ref, hosts: app.hosts)
        navigator.open(.sidePane(.files(ref)))
        await FixtureCheck.wait("the Files tree", seconds: 20) { model.phase == .loaded }
        await model.toggle("Widgets")
        await model.open(path)
        guard let original = model.edits[path]?.text else { FixtureCheck.fail("The file did not open in the editor") }
        model.setText(draftEdit + original, for: path)
        await FixtureCheck.wait("the editor shows the edit", seconds: 10) { shows(draftEdit) }
        navigator.present(NewThreadFixtures.compose)
        await NewThreadFixtures.form()
        await FixtureCheck.wait("the sheet shows its text", seconds: 10) { shows(sheetText) }
        FixtureCheck.report("FIXTURE CHECK ok: set up, editor, terminal and sheet open on \(layout(navigator))")

        func report(_ object: String, _ stage: String, _ kept: Bool, _ detail: String) {
            // `FIXTURE CHECK FAILED` would fail the run and drop the PNG; a lost object is a finding, not a failure.
            FixtureCheck.report("FIXTURE CHECK survival \(object) (\(stage)): \(kept ? "kept" : "lost"), \(detail)")
        }
        func look(_ stage: String, editorVisible: Bool) async {
            try? await Task.sleep(for: .seconds(2))
            let edit = model.edits[path]
            report("editor", stage, edit?.isDirty == true && edit?.text.hasPrefix(draftEdit) == true,
                   "the unsaved edit \(edit?.isDirty == true ? "is" : "is not") in the file's model\(editorVisible ? ", editor text on screen: \(shows(draftEdit))" : "")")
            report("terminal", stage, session.surface.map(ObjectIdentifier.init) == terminalView,
                   "its session \(session.surface == nil ? "has no view" : session.surface.map(ObjectIdentifier.init) == terminalView ? "keeps the same view" : "got a new view")")
            let model = NewThreadModel.active
            report("sheet", stage, navigator.presented != nil && model?.prompt == sheetText,
                   "presented: \(navigator.presented != nil), form \(model == nil ? "gone" : "present"), prompt \(model?.prompt.count ?? 0) of \(sheetText.count) characters, "
                   + "text on screen: \(shows(sheetText))")
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
            await FixtureCheck.wait("the \(pose) layout", seconds: 20) { navigator.layout == (closed ? .phone : .pad) }
            await look(pose, editorVisible: !closed)
            FixtureCheck.report("FIXTURE CHECK ok: \(pose), \(layout(navigator))")
        }

        // The terminal's own tab, then back to the editor: its view is the one it had, drawn again.
        navigator.sidePane.show(.terminal)
        let deadline = Date().addingTimeInterval(10)
        while session.surface?.window == nil, Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
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
