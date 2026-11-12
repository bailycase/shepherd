import Foundation
import os

/// Local Instruments signposts at the Mac app's interaction boundaries, to line up with
/// Instruments' rendering and hitch tracks. Fixed labels only: never prompt, project or file
/// text, names or identifiers, and nothing is uploaded or added to diagnostics. A signpost marks
/// when the app did something (a body evaluated, a task finished), not when a frame reached the
/// screen; read frames from Instruments' own tracks.
enum AppSignposts {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "Shepherd"
    /// Cold start: the server acquiring the workspace, the model being made, the first window content.
    static let launch = OSSignposter(subsystem: subsystem, category: "Launch")
    /// A thread coming on screen until its first caught-up render.
    static let thread = OSSignposter(subsystem: subsystem, category: "Thread")
    /// Input prepared off the main actor: attachments, inline Markdown, the Instructions tint.
    static let input = OSSignposter(subsystem: subsystem, category: "Input")
    /// The host's workspace pushes: "adopt" for one the view model took, "adopt skipped" for one left to a newer push.
    static let workspace = OSSignposter(subsystem: subsystem, category: "Workspace")
}

/// One thread view's "shown → first caught-up render" interval: begun by the first body
/// evaluation after the view becomes active, ended by the first one that draws the thread caught
/// up (a render, not a presented frame). Kept by reference: noting it never re-renders.
@MainActor
final class ThreadShownSignpost {
    private var interval: OSSignpostIntervalState?
    private var wasActive = false

    func render(active: Bool, settled: Bool) {
        if active, !wasActive, interval == nil {
            interval = AppSignposts.thread.beginInterval("thread shown to caught-up render")
        }
        wasActive = active
        if let interval, settled || !active {
            AppSignposts.thread.endInterval("thread shown to caught-up render", interval)
            self.interval = nil
        }
    }
}
