import SwiftUI
import ShepherdUI

/// The app's start: the session server acquires the workspace (ownership, state, Changes
/// records, design cleanup) off the main thread while the window is already up, and only once
/// it holds that authority is the model made, on the main actor, that restores agents and
/// writes the workspace. Nothing that acts on the workspace (the model, its menus, its views)
/// exists before then. A start that fails ends the app as it always has (`failed`).
@MainActor @Observable
final class ShepherdLaunch<Model: AnyObject> {
    private(set) var model: Model?
    @ObservationIgnored private let start: @Sendable () throws -> Void
    @ObservationIgnored private let makeModel: @MainActor () -> Model
    @ObservationIgnored private let failed: @MainActor (Error) -> Void
    @ObservationIgnored private var begun = false

    init(start: @escaping @Sendable () throws -> Void, makeModel: @escaping @MainActor () -> Model,
         failed: @escaping @MainActor (Error) -> Void) {
        self.start = start
        self.makeModel = makeModel
        self.failed = failed
    }

    /// Starts once. Returns the work so a test can wait for it.
    @discardableResult
    func begin() -> Task<Void, Never>? {
        guard !begun else { return nil }
        begun = true
        let start = start
        return Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                let interval = AppSignposts.launch.beginInterval("server start")
                defer { AppSignposts.launch.endInterval("server start", interval) }
                return Result { try start() }
            }.value
            guard let self else { return }
            switch result {
            case .success:
                let interval = AppSignposts.launch.beginInterval("model init")
                self.model = self.makeModel()
                AppSignposts.launch.endInterval("model init", interval)
            case .failure(let error):
                self.failed(error)
            }
        }
    }
}

/// What the window shows while the workspace is being opened: the window's own background, and,
/// only if it takes a while, a small progress line (so a quick start never flashes one).
struct LaunchSurface: View {
    @State private var slow: Bool

    /// `slow` starts with the progress line shown (previews).
    init(slow: Bool = false) { _slow = State(initialValue: slow) }

    var body: some View {
        ZStack {
            Color.sh.bgWindow
            if slow {
                HStack(spacing: SH.Space.s) {
                    ProgressView().controlSize(.small)
                    Text("Opening your workspace…").font(.sh(.ui, weight: .regular)).foregroundStyle(Color.sh.textSecondary)
                }
                .accessibilityElement(children: .combine)
                .transition(.opacity)
            }
        }
        .shAnimation(.content, value: slow)
        .task {
            guard !slow else { return }
            try? await Task.sleep(for: AppLayout.startingIndicatorDelay)
            guard !Task.isCancelled else { return }
            slow = true
        }
    }
}
