import AppKit
import Foundation
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdUI
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp

/// A space's Hooks tab (HooksSpace board), from the space's own files through the real catalog.
extension ProjectsPreviewTests {
    @Test func detailsHooks() async throws {
        let world = try await ProjectsPreviewWorld(detail: true)
        defer { world.stop() }
        let project = try #require(world.vm.projects.rows.first { $0.project.name == "payments" && $0.host.id == "local" })
        let root = PiHome.canonical(project.project.directory)
        func write(_ relative: String, _ text: String) throws {
            let url = URL(fileURLWithPath: root).appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try FileManager.default.createDirectory(atPath: root + "/.git", withIntermediateDirectories: true)
        try write(".shepherd/hooks.json", #"{"hooks":{"PreToolUse":[{"matcher":"Edit|Write","hooks":[{"type":"command","command":"\"$CLAUDE_PROJECT_DIR\"/.shepherd/hooks/no-env.sh"}]}],"Stop":[{"hooks":[{"type":"command","command":"npm test --silent"}]}]}}"#)
        try write(".claude/settings.json", #"{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"git-guard push --ask-on main"}]}]}}"#)
        let hooks = world.vm.hooks
        await world.vm.projects.open(project)
        await world.vm.projects.navigate(.hooks)
        hooks.reload()
        try await eventuallyOnMain("the space's hooks to load") { hooks.snapshot?.entries.contains { $0.scope.root == root } == true && !hooks.loading }
        try await Preview.renderMatrix("projects-detail-hooks", size: CGSize(width: 1440, height: 900)) {
            SettingsView(vm: world.vm)
        }
    }
}
