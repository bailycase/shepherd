import AppIntents
import Foundation
import ShepherdUI

// The intents a glance surface's buttons run. They run in the app (`allowedExecutionTargets:
// .main`), which owns the hosts' connections and tokens; the widget extension only draws the
// buttons. Each needs an unlocked device: the host's token is readable only then (`HostTokens`),
// and an answer can start real work.

/// What a button asks the app to do.
enum GlanceCommand: Sendable {
    /// `confirms`: a yes-or-no question, answered "Yes" or "No".
    case answer(host: String, agent: String, dialogID: String, session: SHGlance.Session, option: String, confirms: Bool)
    case stop(host: String, agent: String, session: SHGlance.Session)
    case open(URL)
}

/// The app's handler, set at launch. Nil in the widget extension, which never runs these.
@MainActor
enum GlanceActions {
    static var handler: ((GlanceCommand) async throws -> Void)?

    static func run(_ command: GlanceCommand) async throws {
        guard let handler else { throw GlanceFailure("Open Shepherd and try again.") }
        try await handler(command)
    }
}

/// Why a button's action did not land, in the words the system shows.
struct GlanceFailure: Error, CustomLocalizedStringResourceConvertible {
    let message: String

    init(_ message: String) { self.message = message }

    var localizedStringResource: LocalizedStringResource { "\(message)" }
}

/// Picks one of the options a thread's question offers.
struct AnswerQuestionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Answer a Shepherd question"
    static let isDiscoverable = false
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }
    static var supportedModes: IntentModes { .background }
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @Parameter(title: "Host") var host: String
    @Parameter(title: "Thread") var agent: String
    @Parameter(title: "Question") var dialogID: String
    @Parameter(title: "Session") var piSessionID: String
    @Parameter(title: "Generation") var generation: String
    @Parameter(title: "Answer") var option: String
    @Parameter(title: "Yes or no", default: false) var confirms: Bool

    init() {}

    init(item: SHGlance.Item, option: String) {
        host = item.host
        agent = item.agent
        dialogID = item.dialogID ?? ""
        piSessionID = item.session?.piSessionID ?? ""
        generation = item.session?.generation ?? ""
        self.option = option
        confirms = item.confirms
    }

    func perform() async throws -> some IntentResult {
        try await GlanceActions.run(.answer(host: host, agent: agent, dialogID: dialogID,
                                            session: SHGlance.Session(piSessionID: piSessionID, generation: generation),
                                            option: option, confirms: confirms))
        return .result()
    }
}

/// Stops a thread's turn, asking nothing.
struct StopTurnIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop a Shepherd thread"
    static let isDiscoverable = false
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }
    static var supportedModes: IntentModes { .background }
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @Parameter(title: "Host") var host: String
    @Parameter(title: "Thread") var agent: String
    @Parameter(title: "Session") var piSessionID: String
    @Parameter(title: "Generation") var generation: String

    init() {}

    init(item: SHGlance.Item) {
        host = item.host
        agent = item.agent
        piSessionID = item.session?.piSessionID ?? ""
        generation = item.session?.generation ?? ""
    }

    func perform() async throws -> some IntentResult {
        try await GlanceActions.run(.stop(host: host, agent: agent,
                                          session: SHGlance.Session(piSessionID: piSessionID, generation: generation)))
        return .result()
    }
}

/// Where a Control Center control opens Shepherd.
enum GlanceDestination: String, AppEnum {
    case newThread, needsYou

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Destination"
    static let caseDisplayRepresentations: [GlanceDestination: DisplayRepresentation] = [
        .newThread: "New thread",
        .needsYou: "Needs you",
    ]

    var link: GlanceLink { self == .newThread ? .newThread : .needsYou }
}

/// Opens Shepherd at a new thread or at what needs you.
struct OpenShepherdIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Shepherd"
    static var supportedModes: IntentModes { .foreground }
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @Parameter(title: "Destination") var destination: GlanceDestination

    init() {}

    init(_ destination: GlanceDestination) { self.destination = destination }

    func perform() async throws -> some IntentResult {
        try await GlanceActions.run(.open(destination.link.url))
        return .result()
    }
}
