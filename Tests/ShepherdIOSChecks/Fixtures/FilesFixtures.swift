import Foundation
import SwiftUI
import UIKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// Files (DuoSidePaneTabs, Files card): a remote thread's folder over `files.v1`. The pane has no route of its own yet (the side
// pane mounts it), so these screens present `ThreadFilesScreen` over the thread, as a push on compact width would show it.
// `files-tree` opens two folders, `files-file` reads a file in place, `files-old-host` is a host without the capability.
extension FixtureCatalog {
    static var files: [FixtureScreen] {
        let thread = MobileRoute.thread(FilesFixture.ref)
        return [
            FixtureScreen(name: "files-tree", hosts: FilesFixture.hosts(), routes: [thread], prepare: { app in
                let model = FilesFixture.present(app)
                await model.loadIfNeeded()
                await model.toggle("Widgets")
                await model.toggle("Intents")
            }),
            FixtureScreen(name: "files-file", hosts: FilesFixture.hosts(), routes: [thread], prepare: { app in
                let model = FilesFixture.present(app)
                await model.loadIfNeeded()
                await model.toggle("Widgets")
                await model.open("Widgets/NeedsYouWidget.swift")
            }),
            FixtureScreen(name: "files-old-host", hosts: FilesFixture.hosts(capable: false), routes: [thread], prepare: { app in
                _ = FilesFixture.present(app)
            }),
        ]
    }
}

enum FilesFixture {
    static let ref = FixtureData.ref(FixtureData.preview)

    static let listings: [String: ThreadFileListing] = [
        "": ThreadFileListing(entries: [
            ThreadFileEntry(name: "Intents", kind: .directory), ThreadFileEntry(name: "Sources", kind: .directory),
            ThreadFileEntry(name: "Tests", kind: .directory), ThreadFileEntry(name: "Widgets", kind: .directory),
            ThreadFileEntry(name: "AGENTS.md", kind: .file, size: 3_310), ThreadFileEntry(name: "render.py", kind: .file, size: 1_204),
        ]),
        "Widgets": ThreadFileListing(entries: [ThreadFileEntry(name: "NeedsYouWidget.swift", kind: .file, size: 1_018),
                                               ThreadFileEntry(name: "WorkingCountWidget.swift", kind: .file, size: 744)]),
        "Intents": ThreadFileListing(entries: [ThreadFileEntry(name: "StartThreadIntent.swift", kind: .file, size: 512)]),
    ]

    static let widget = """
    import SwiftUI
    import WidgetKit

    /// The threads waiting on you, newest first.
    struct NeedsYouWidget: Widget {
        let kind = "NeedsYou"

        var body: some WidgetConfiguration {
            StaticConfiguration(kind: kind, provider: NeedsYouProvider()) { entry in
                NeedsYouView(entry: entry)
            }
            .configurationDisplayName("Needs you")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        }
    }

    """

    static func hosts(capable: Bool = true) -> [FixtureHostData] {
        var hosts = FixtureData.hosts()
        if capable {
            hosts[0].reply = { request in
                switch request {
                case .agentQuery(let id, _, .files(let path, _)):
                    guard let listing = listings[path] else { return .error(id: id, code: "not_found", message: "No such file or folder") }
                    return .agentResult(id: id, result: .files(listing))
                case .agentQuery(let id, _, .fileRead(let path)):
                    guard path == "Widgets/NeedsYouWidget.swift" else { return .error(id: id, code: "not_found", message: "No such file or folder") }
                    return .agentResult(id: id, result: .fileData(Data(widget.utf8)))
                default: return nil
                }
            }
        } else {
            hosts[0].capabilities = hosts[0].defaultCapabilities.filter { $0 != RemoteProtocol.filesCapability }
        }
        return hosts
    }

    /// Presents Files over the thread, full screen in its own navigation stack, and returns its tree.
    @MainActor static func present(_ app: MobileApp) -> ThreadFilesModel {
        let root = NavigationStack { ThreadFilesScreen(thread: ref) }.environment(app.hosts)
        let controller = UIHostingController(rootView: root)
        // Over, not instead of, the window's root: a removed root unregisters the window and the hosts disconnect.
        controller.modalPresentationStyle = .overFullScreen
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.keyWindow
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        top?.present(controller, animated: false)
        return ThreadFilesStores.shared.model(for: ref, hosts: app.hosts)
    }
}
