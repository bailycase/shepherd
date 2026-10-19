import Foundation
import Testing
@testable import ShepherdUI

/// A Markdown link to a local file resolves in the agent's folder, and only where that folder is on this device.
@Suite("Prose file links")
@MainActor
struct ProseFileLinkTests {
    @Test(arguments: [
        ("temporal/PLAN.md", "/work" as String?, "/work/temporal/PLAN.md" as String?),
        ("./temporal/PLAN.md", "/work", "/work/temporal/PLAN.md"),
        ("../other/a.swift", "/work/repo", "/work/other/a.swift"),
        ("docs/my%20plan.md", "/work", "/work/docs/my plan.md"),
        ("/tmp/a.md", "/work", "/tmp/a.md"),
        ("file:///tmp/a.md", "/work", "/tmp/a.md"),
        ("~/notes.md", "/work", FileManager.default.homeDirectoryForCurrentUser.appending(path: "notes.md").path),
        // Web and other schemes are not files.
        ("https://example.com/PLAN.md", "/work", nil),
        ("mailto:a@b.c", "/work", nil),
        // A remote agent's files are not here: never a same-named file on this device.
        ("temporal/PLAN.md", nil, nil),
        ("/tmp/a.md", nil, nil),
        ("file:///tmp/a.md", nil, nil),
        ("~/notes.md", nil, nil),
    ])
    func linksResolveOnlyWhereTheFilesAre(link: String, root: String?, path: String?) throws {
        let url = try #require(URL(string: link))
        let resolved = NWProseFileLinks.resolve(url, root: root.map { URL(fileURLWithPath: $0, isDirectory: true) })
        #expect(resolved?.path == path.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
    }

    @Test func aRemoteAgentsFileLinkIsOnlyWords() {
        let text = NWProseInline.styled("See [plan](temporal/PLAN.md) and [site](https://example.com).")
        let inert = NWProseFileLinks.inert(text)
        #expect(inert.runs.compactMap(\.link) == [URL(string: "https://example.com")!])
        #expect(NWProseFileLinks.hasLocalLink(text) && !NWProseFileLinks.hasLocalLink(inert))
        let actions = NWProseFileLinks(editorName: { _ in "" }, editors: { [] }, open: { _, _ in }, reveal: { _ in })
        #expect(NWProseFileLinks.targets(text, root: nil, actions: actions) == nil)
        #expect(NWProseFileLinks.targets(text, root: URL(fileURLWithPath: "/work"), actions: actions) == actions)
    }
}
