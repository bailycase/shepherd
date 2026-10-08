import Foundation
import SwiftUI
import Testing
import ShepherdSessions
import ShepherdProtocol
import ShepherdTestSupport
@testable import ShepherdApp

@Suite("Child project previews", .serialized, .mainActorExclusive, .enabled(if: Preview.enabled))
@MainActor
struct ChildProjectPreviewTests {
    @Test(arguments: ["empty", "new", "existing", "error", "busy", "long"])
    func dialog(state: String) async throws {
        let scratch = try ScratchServer()
        defer { scratch.stop() }
        var waiting: CheckedContinuation<Void, Never>?
        let model = ChildProjectModel(parentPath: scratch.dir.path, parentName: state == "long" ? String(repeating: "Long parent project ", count: 8) : "Parent") { request in
            if state == "busy" { await withCheckedContinuation { waiting = $0 }; return }
            if case .child(let parent, let path, let name, let create) = request {
                _ = try await scratch.server.addChildProject(parentPath: parent, path: path, name: name, create: create)
            }
        }
        if state != "empty" { model.folder = "child" }
        if state == "existing" { model.create = false; model.folder = scratch.dir.appendingPathComponent("existing").path }
        if state == "long" {
            model.folder = String(repeating: "long-child-folder-", count: 8)
            model.displayName = String(repeating: "Long display name ", count: 8)
        }
        if state == "error" {
            try Data("existing file".utf8).write(to: scratch.dir.appendingPathComponent("child"))
            #expect(await model.submit() == false)
        }
        let task = state == "busy" ? Task { await model.submit() } : nil
        if task != nil { try await eventuallyOnMain("registration pending") { model.busy && waiting != nil } }
        try await Preview.renderMatrix("child-project-\(state)", size: CGSize(width: 760, height: 620)) {
            ChildProjectSheet(model: model, dismiss: {})
        }
        waiting?.resume()
        _ = await task?.value
    }
}
