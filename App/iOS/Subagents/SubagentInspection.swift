import SwiftUI
import Observation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// The iPad inspector beside a thread (iPadSteer, iPadSubagents boards): which thread it serves
/// and which run it shows (nil: the thread's list of runs). A card tapped in that thread switches
/// the run in place instead of opening another screen. Each window has its own
/// (`of(navigator)`), so an inspector opened in one iPad window leaves another's alone.
@MainActor
@Observable
final class SubagentInspection {
    private static let windows = NSMapTable<MobileNavigator, SubagentInspection>.weakToStrongObjects()

    /// The inspection of the window `navigator` belongs to.
    static func of(_ navigator: MobileNavigator) -> SubagentInspection {
        if let inspection = windows.object(forKey: navigator) { return inspection }
        let inspection = SubagentInspection()
        windows.setObject(inspection, forKey: navigator)
        return inspection
    }

    private(set) var thread: AgentRef?
    private(set) var runID: String?

    func show(_ thread: AgentRef, runID: String?) {
        if self.thread != thread { self.thread = thread }
        if self.runID != runID { self.runID = runID }
    }

    func close(_ thread: AgentRef) {
        guard self.thread == thread else { return }
        self.thread = nil
        runID = nil
    }

    /// The run inspected in `thread`, for its card's ring.
    func selected(in thread: AgentRef) -> String? {
        self.thread == thread ? runID : nil
    }
}

/// Opens a thread's runs the way the layout shows them: pushed on iPhone; on iPad in the
/// inspector beside the thread, switched in place when it is already open there.
@MainActor
enum SubagentOpening {
    static func open(_ route: SubagentsRoute, navigator: MobileNavigator) {
        let thread = route.thread
        let runID: String? = if case .run(_, let id) = route { id } else { nil }
        let inspection = SubagentInspection.of(navigator)
        if navigator.layout == .pad, inspection.thread == thread {
            inspection.show(thread, runID: runID)
            return
        }
        if navigator.layout == .pad {
            // The inspector's screen is the same thread with the inspector beside it: no slide.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { navigator.open(.subagents(route)) }
        } else {
            navigator.open(.subagents(route))
        }
    }
}

/// Keeps the thread's store polling while a subagents screen is up, through the thread's viewers
/// (`ThreadStores.viewers(for:)`) like the thread itself: it joins the loop the thread on
/// screen runs, and runs it whenever nothing else does (the thread under it on iPhone, which
/// stops it as it leaves the screen, or another window's).
struct SubagentThreadKeeper: ViewModifier {
    let ref: AgentRef
    @Environment(MobileHosts.self) private var hosts
    @Environment(ThreadStores.self) private var threads
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false

    private struct Key: Equatable {
        var session: UUID?
        var active: Bool
    }

    func body(content: Content) -> some View {
        let host = hosts.host(ref.host)
        let supported = host?.supports(RemoteProtocol.nativeThreadCapability) == true
        let key = Key(session: supported && host?.agent(ref.agent) != nil ? host?.session : nil, active: visible && scenePhase == .active)
        content
            .onAppear { visible = true }
            .onDisappear { visible = false }
            .task(id: key) {
                guard key.active, let session = key.session, let client = host?.connectedClient else { return }
                let agentID = ref.agent
                await threads.viewers(for: ref).run(connection: session) { request in
                    try await client.nativeThread(agentID: agentID, request: request)
                }
            }
    }
}

extension View {
    func keepsThreadLive(_ ref: AgentRef) -> some View {
        modifier(SubagentThreadKeeper(ref: ref))
    }
}
