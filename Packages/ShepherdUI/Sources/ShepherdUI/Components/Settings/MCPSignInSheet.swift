import SwiftUI

/// What the OAuth sign-in sheet shows: its steps, and whether it's waiting, done, or failed.
public struct MCPSignInSheetModel: Equatable, Sendable {
    public enum Phase: Sendable { case waiting, done, failed }

    public struct Step: Equatable, Sendable, Identifiable {
        public enum State: Sendable { case pending, live, done, failed }
        public var id: String
        public var title: String
        public var note: String?
        public var state: State

        public init(id: String, title: String, note: String? = nil, state: State) {
            self.id = id
            self.title = title
            self.note = note
            self.state = state
        }
    }

    public var title: String
    public var subtitle: String
    public var steps: [Step]
    public var phase: Phase
    /// The technical reason behind a failure, shown by Details.
    public var details: String?

    public init(title: String, subtitle: String, steps: [Step], phase: Phase, details: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.steps = steps
        self.phase = phase
        self.details = details
    }
}

/// Sign in to a server with OAuth (MCPStates' MCPSignInSheet): found the sign-in server,
/// registered Shepherd, waiting in the browser; then done or failed.
public struct MCPSignInSheet: View {
    public struct Actions {
        public var copyLink: () -> Void
        public var openBrowser: () -> Void
        public var cancel: () -> Void
        public var done: () -> Void
        public var tryAgain: () -> Void

        public init(copyLink: @escaping () -> Void, openBrowser: @escaping () -> Void, cancel: @escaping () -> Void,
                    done: @escaping () -> Void, tryAgain: @escaping () -> Void) {
            self.copyLink = copyLink
            self.openBrowser = openBrowser
            self.cancel = cancel
            self.done = done
            self.tryAgain = tryAgain
        }

        public static let none = Actions(copyLink: {}, openBrowser: {}, cancel: {}, done: {}, tryAgain: {})
    }

    let model: MCPSignInSheetModel
    let actions: Actions
    @State private var showsDetails: Bool

    /// `detailsOpen` starts a failed sign-in with its details showing.
    public init(_ model: MCPSignInSheetModel, actions: Actions, detailsOpen: Bool = false) {
        self.model = model
        self.actions = actions
        _showsDetails = State(initialValue: detailsOpen)
    }

    public var body: some View {
        SHSettingsSheet(model.title, subtitle: model.subtitle, width: SHMCPMetrics.sheetWidth) {
            SHSheetSteps {
                ForEach(model.steps) { step in MCPSignInStepRow(step) }
            }
            if showsDetails, let details = model.details {
                SHSheetPre(details)
            }
        } status: {
            // The words at the foot's left: Copy link while it waits, Details after a failure.
            switch model.phase {
            case .waiting:
                Button("Copy link", action: actions.copyLink).buttonStyle(.sh(.ghost)).fixedSize()
            case .failed:
                if model.details != nil {
                    Button(showsDetails ? "Hide details" : "Details") { showsDetails.toggle() }.buttonStyle(.sh(.ghost)).fixedSize()
                }
            case .done:
                EmptyView()
            }
        } actions: {
            switch model.phase {
            case .waiting:
                Button("Cancel", action: actions.cancel).buttonStyle(.sh(.ghost)).keyboardShortcut(.cancelAction)
                Button("Open browser again", action: actions.openBrowser).buttonStyle(.sh(.secondary))
            case .done:
                Button("Done", action: actions.done).buttonStyle(.sh(.primary)).keyboardShortcut(.defaultAction)
            case .failed:
                Button("Close", action: actions.cancel).buttonStyle(.sh(.ghost)).keyboardShortcut(.cancelAction)
                Button("Try again", action: actions.tryAgain).buttonStyle(.sh(.primary)).keyboardShortcut(.defaultAction)
            }
        }
        .shAnimation(.disclosure, value: model)
    }
}

/// One step: its title (a note under it) and its state in words at the right: Done, Now, Next, Failed.
public struct MCPSignInStepRow: View {
    let step: MCPSignInSheetModel.Step

    public init(_ step: MCPSignInSheetModel.Step) {
        self.step = step
    }

    public var body: some View {
        let (state, word): (SHSheetStep.State, String) = switch step.state {
        case .done: (.done, "Done")
        case .live: (.now, "Now")
        case .pending: (.wait, "Next")
        case .failed: (.failed, "Failed")
        }
        SHSheetStep(step.title, note: step.note, word: word, state: state)
    }
}
