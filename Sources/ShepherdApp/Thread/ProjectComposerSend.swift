import SwiftUI
import ShepherdRemote
import ShepherdProtocol
import ShepherdCore
import ShepherdUI

/// How a Project's conversation composer sends (ProjectLead boards). The shared composer draws the same card; only
/// its send, placeholder, empty state and the strip over the card differ. `send` returns true when the Project
/// runtime accepted the message (queued, or delivered), so the draft clears only then; a refusal leaves the words in
/// the field.
struct ProjectComposerSend {
    /// "Ask Gamecards a question or start a task…", or the paused wording.
    var placeholder: String
    /// Sends the words and the images on the card. True only when the runtime accepted BOTH; then the composer clears the draft and
    /// exactly the images it submitted. A refusal or a lost connection keeps every word and every image.
    /// Whether the Project's owner carries images. The composer's paperclip, paste and drop all ask this, not the coordinator's thread.
    var carriesImages: Bool = true
    var send: (String, [NativeImage]) async -> Bool
    /// Why the last send was refused, for the composer's own failed line. nil when it has nothing to say.
    var refusal: () -> String? = { nil }
    /// The conversation's empty state (the Project overview) while it has no turns.
    var emptyState: (() -> AnyView)? = nil
    /// The strip over the card ("2 of 3 done · 1 needs you"), drawn only when there are tasks.
    var dock: (() -> AnyView)? = nil
    /// The person's own messages the runtime accepted but the native transcript does not show yet: held while paused, in flight, or
    /// not delivered. Drawn after the transcript as the thread's own pending bubble (70%) with its own one-line note.
    var held: () -> [ProjectHeldMessage] = { [] }
    /// Operations the owner itself recorded as worker events (a message with a `source`): the runtime's own wake-ups of the coordinator,
    /// which are not the person's words and which the boards never draw. Matched by the operation the native user message carries,
    /// never by its text.
    var runtimeOperations: Set<UUID> = []
    /// The column's width: a Project's conversation is 680pt (ProjectLead boards), not an ordinary thread's 820.
    var columnWidth: CGFloat = NWLeadMetrics.columnWidth
}

extension EnvironmentValues {
    /// Set by a Project's conversation around its thread; nil everywhere else.
    @Entry var projectComposerSend: ProjectComposerSend? = nil
}

extension EnvironmentValues {
    /// A Project's worker thread, opened in the Threads pane (ProjectLead-ThreadRunning): the day separator over its first turn and
    /// the board's placeholder ("Steer this thread…"). The thread's sends stay native; nil everywhere else.
    @Entry var projectWorkerThread: ProjectWorkerThreadStyle? = nil
}

/// Who wrote each message of a user turn, from the operation it carries (never its text). Consecutive user messages are one turn, so a
/// person's words can share it with the owner's assignment (a worker thread) or wake-ups (the coordinator).
struct ProjectUserOrigins: Equatable {
    var assignment: Set<UUID> = []
    var runtime: Set<UUID> = []

    enum Segment: Equatable {
        /// The coordinator's assignment: plain prose (ProjectLead-ThreadRunning).
        case assignment(String)
        /// The person's own messages: the ordinary bubbles, with their images and design references.
        case person(NativeTurn)
    }

    var isEmpty: Bool { assignment.isEmpty && runtime.isEmpty }

    /// Nothing in the turn is the person's or the assignment's: the owner's wake-ups only.
    func hides(_ turn: NativeTurn) -> Bool {
        !runtime.isEmpty && turn.messages.allSatisfy { $0.operationID.map(runtime.contains) == true }
    }

    /// The turn in order, one segment per run of one origin; wake-ups drop out.
    func segments(_ turn: NativeTurn) -> [Segment] {
        guard !isEmpty else { return [.person(turn)] }
        var result: [Segment] = []
        var person: [NativeThreadMessage] = []
        func flush() {
            if !person.isEmpty { result.append(.person(NativeTurn(id: turn.id, isUser: true, messages: person))) }
            person = []
        }
        for message in turn.messages {
            let operation = message.operationID
            if operation.map(runtime.contains) == true { continue }
            if operation.map(assignment.contains) == true {
                flush()
                result.append(.assignment(message.blocks.filter { $0.kind == .text }.map(\.text).joined(separator: "\n\n")))
            } else {
                person.append(message)
            }
        }
        flush()
        return result
    }
}

/// A user turn that mixes the owner's assignment with a person's words: the assignment as the board's plain prose, the person's
/// messages as their own bubbles, in the order sent.
struct ProjectUserSegments: View, Equatable {
    let segments: [ProjectUserOrigins.Segment]

    var body: some View {
        VStack(alignment: .leading, spacing: NWLeadMetrics.turnGap) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .assignment(let text): Prose(text: text, maxWidth: NWLeadMetrics.columnWidth).equatable()
                case .person(let turn): UserTurn(turn: turn).equatable()
                }
            }
        }
    }
}

struct ProjectWorkerThreadStyle: Equatable {
    var placeholder = "Steer this thread…"
    /// The operations that carried the coordinator's assignment: a user message with one of them is the coordinator's words (drawn as
    /// the board's plain prose), never a person's bubble. Any other user message here is the person's and stays a bubble.
    var assignmentOperations: Set<UUID> = []
    /// The pane's own thread column sits 16pt from the pane's left edge, and its composer card 16pt in and 32pt from the right
    /// (ProjectLead-ThreadRunning: prose x 1137...1584, card 1137...1568 in a pane 1121...1600).
    var gutter: CGFloat = NWLeadMetrics.paneThreadGutter
    var composerTrailing: CGFloat = NWLeadMetrics.paneComposerTrailing
}

/// How a Project's conversation draws a Project tool's typed result inline (ProjectLead-Started / -AddsSpace): a task card or the
/// offer to add a Space, resolved against the owner's CURRENT Project. nil draws the ordinary activity line. A reference is display
/// identity only: it authorizes nothing, and a card whose task or proposal is gone is not drawn at all.
struct ProjectActionCards {
    /// What the current Project says about each typed reference (the task or the pending proposal), so the transcript line is equal
    /// only while those answers are: a task that resolves, or goes, redraws it.
    var resolved: (NativeProjectAction) -> ProjectActionResolver.Card?
    /// The card for a resolved reference.
    var card: (ProjectActionResolver.Card) -> AnyView
    /// The owner still has a thread to start (a task `queued` or `reserved`): the conversation's live line says so.
    var startingThreads = false
}

/// What a Project thread's live line says, from typed state only: the owner's task phases for the coordinator and the worker's own
/// turn start for a worker. nil is "nothing Project-specific to say": the ordinary "Thinking…" stays.
enum ProjectRunStatus {
    /// The coordinator has just started a thread: the last thing its live turn did was a `project_assign` call whose result carries a
    /// typed task reference. The turn is still working (it is between tools), so the line says what it was doing, not "Thinking…".
    static func justAssigned(_ presentation: NativeTurnPresentation) -> Bool {
        guard case .activity(_, let bursts)? = presentation.items.last,
              let call = bursts.last?.calls.last else { return false }
        return call.name == "project_assign" && call.state == .done && call.projectAction?.taskID != nil
    }

    static func text(startingThreads: Bool, worker: Bool, startedAt: Double?, now: Date) -> String? {
        if startingThreads && !worker { return "Starting threads" }
        guard worker else { return nil }
        guard let startedAt else { return "Working" }
        return "Working · " + nativeDurationText(max(0, now.timeIntervalSince1970 - startedAt / 1000), live: true)
    }
}

/// The Project thread's live line. Its clock is the only one: the seconds come from this view's own once-a-second timeline.
struct ProjectLiveLine: View {
    var startedAt: Double?
    /// The coordinator's live turn ended its last call with a `project_assign` (`ProjectRunStatus.justAssigned`).
    var justAssigned = false
    @Environment(\.projectActionCards) private var cards
    @Environment(\.projectWorkerThread) private var worker

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let text = ProjectRunStatus.text(startingThreads: cards?.startingThreads == true || justAssigned, worker: worker != nil,
                                                startedAt: startedAt, now: context.date) {
                NWLeadStatusLine(text)
            } else {
                NWThinking.live()
            }
        }
    }
}

extension EnvironmentValues {
    @Entry var projectActionCards: ProjectActionCards? = nil
}

/// One accepted Project message the native transcript has not taken in. Its words are the person's own; the note is the state in
/// words. Nothing is retried for the person: an unknown or failed delivery says so, and sending the same words again is the
/// explicit retry (the runtime keeps one identity per exact text).
struct ProjectHeldMessage: Equatable, Identifiable {
    let id: UUID
    let text: String
    let note: String
}

/// Which Project messages still need a place in the conversation, from the Project's real `messages` and the transcript's real
/// consumed operation identities. A message is represented once the native thread has a user message carrying its operation ID, or
/// the native delivery ID the owner recorded for it. Worker reports (a `source`) are the runtime's own and are never drawn here.
enum ProjectHeldMessages {
    static func held(messages: [ProjectMessage], paused: Bool, consumed: Set<UUID>) -> [ProjectHeldMessage] {
        messages.compactMap { message in
            guard message.source == nil else { return nil }
            if consumed.contains(message.id) || message.nativeDeliveryID.map(consumed.contains) == true { return nil }
            let note: String
            switch message.phase {
            case .queued: note = paused ? "Sends when the project resumes" : "Waiting to send"
            case .delivering: note = "Sending"
            case .unknown: note = "Delivery unconfirmed. Send it again to retry."
            case .failed: note = "Not delivered. Send it again to retry."
            case .delivered: return nil
            }
            return ProjectHeldMessage(id: message.id, text: message.text, note: note)
        }
    }
}
