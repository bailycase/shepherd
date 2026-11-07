import AppKit
import Foundation
import Testing
@testable import ShepherdApp

/// The alert a launch shows when another Shepherd process (the background host, or another copy
/// of the app) owns the workspace, as AppKit lays it out, light and dark.
@Suite("Workspace in use", .enabled(if: Preview.enabled), .mainActorExclusive)
@MainActor
struct WorkspaceInUsePreviewTests {
    @Test func workspaceInUseAlert() throws {
        let directory = try #require(Preview.directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        for dark in [false, true] {
            let alert = WorkspaceInUseAlert.make()
            alert.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            alert.layout()
            let view = try #require(alert.window.contentView)
            view.appearance = alert.window.appearance
            view.layoutSubtreeIfNeeded()
            let content = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: content)
            // The panel's own background is drawn by its window frame, which a view capture leaves out.
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            alert.window.appearance?.performAsCurrentDrawingAppearance {
                NSColor.windowBackgroundColor.setFill()
                view.bounds.fill()
            }
            content.draw(in: view.bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("workspace-in-use-\(dark ? "dark" : "light").png"))
        }
    }
}
