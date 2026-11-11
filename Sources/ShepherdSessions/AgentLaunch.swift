import Foundation
import ShepherdCore
import ShepherdProtocol

/// The app settings an agent's pi launch reads, as plain values: the app takes them from its
/// settings, and nothing here reads `AppSettings`.
public struct AgentLaunchSettings: Equatable, Sendable {
    public var codemode = false
    public var panes = true
    public var review = true
    public var subagentDisplay = true
    public var nativeSubagents = false
    public var childEnvironment: [String: String] = [:]
    public var goals = false
    /// Settings ▸ Agents ▸ Text generation model; "" for Automatic.
    public var textGenerationModel = ""
    public var designTool = false
    public var designReferences = false
    public var browser = true
    public var trimToolOutput = false
    public var deferTools = false

    public init() {}
}

/// How an agent's pi is launched: readying its home and conversation, and its `pi --mode rpc`
/// line with Shepherd's extensions.
public enum AgentLaunch {
    /// Before an agent's pi starts: readies Shepherd's pi home (`PiSetup.prepare`, which refuses
    /// a home that overlaps the user's own pi), adopts its conversation from the user's pi
    /// (`PiSessionFile.adopt`), then says whether the agent's pi session is still fresh, after
    /// seeding its header (`PiSessionFile.prepareForLaunch`). Off the caller's actor: at launch every
    /// restored agent does this at once, and a project directory holds hundreds of session files.
    public static func prepare(for agent: Agent, cwd: String, pi: PiSetup, codemode: Bool,
                               requiredHistoryEntryID: String? = nil) async -> (fresh: Bool, problem: PiHomeProblem?) {
        let sessionID = agent.effectivePiSessionID
        return await Task.detached(priority: .userInitiated) {
            if let problem = pi.prepare() { return (true, problem) }
            do { try pi.files.configureCodemode(codemode) }
            catch { return (true, PiHomeProblem("Shepherd couldn't configure codemode: \(error)")) }
            if let requiredHistoryEntryID {
                // Project follow-ups may restore this proven conversation, never seed/adopt a replacement.
                guard PiSessionFile.writableProjectDirectory(forCwd: cwd, sessionsRoot: pi.sessionsRoot) != nil,
                      let file = PiSessionFile.file(sessionID: sessionID, cwd: cwd, sessionsRoot: pi.sessionsRoot),
                      PiSessionFile.isOwnFile(file),
                      let preview = PiSessionPreview.snapshot(file: file, sessionID: sessionID),
                      preview.messages.contains(where: { $0.entryID == requiredHistoryEntryID }) else {
                    return (false, PiHomeProblem("The proven Project worker history is unavailable. Restore its original conversation before requesting a follow-up."))
                }
                return (false, nil)
            }
            // Its conversation from before Shepherd ran its own pi, copied in before any seeding.
            _ = PiSessionFile.adopt(sessionID: sessionID, cwd: cwd, sessionsRoot: pi.sessionsRoot, yourPi: pi.yourPi.resolve())
            return (PiSessionFile.prepareForLaunch(sessionID: sessionID, cwd: cwd, sessionsRoot: pi.sessionsRoot), nil)
        }.value
    }

    /// The command an agent gets when Shepherd won't start pi: it says why and exits, so the agent
    /// keeps its place with the reason (Thread › Can't start).
    public static func refusedCommand(_ problem: PiHomeProblem) -> SessionCommand {
        SessionCommand(argv: PiLaunch.refused(problem).argv, env: [:])
    }

    /// `pi --mode rpc` for an agent, with Shepherd's socket, status, panes, review, subagents,
    /// and namer extensions; an agent that draws a design gets the design tools instead of panes. Model and
    /// thinking flags go only to a fresh session.
    public static func rpcCommand(for agent: Agent, cwd: String, pi: PiSetup, settings: AgentLaunchSettings,
                                  sessionIsFresh: Bool, isAutomation: Bool = false,
                                  project: Project? = nil, worktreeOwningSpace: String? = nil,
                                  suggestFiles: [InstructionFile] = [], modelOverride: String? = nil,
                                  specKit: MissionSpecKitLaunch? = nil, inherited: SpaceInheritedDefaults? = nil,
                                  mcp: () throws -> MCPLaunch?) throws -> SessionCommand {
        try StatusExtension.command(
            home: pi.files,
            cwd: cwd,
            agentID: agent.id,
            piSessionID: agent.effectivePiSessionID,
            socketPath: ShepherdPaths.socketURL().path,
            extensionPath: try StatusExtension.installedPath(),
            panesExtensionPath: wantsPanes(for: agent, enabled: settings.panes) ? try PanesExtension.installedPath() : nil,
            reviewExtensionPath: wantsReview(for: agent, enabled: settings.review) ? try ReviewExtension.installedPath() : nil,
            subagentsExtensionPath: settings.subagentDisplay ? try SubagentsExtension.installedPath() : nil,
            childrenExtensionPath: agent.coordinatorFor == nil ? try ChildrenExtension.installedPath() : nil,
            nativeChildren: settings.nativeSubagents,
            childEnvironment: settings.childEnvironment,
            goalsEnabled: settings.goals,
            namerExtensionPath: try NamerExtension.installedPath(),
            needsName: !agent.nameIsFinal,
            textGenerationModel: settings.textGenerationModel,
            isAutomation: isAutomation,
            instructions: (try InstructionsExtension.installedPath(), ShepherdPaths.instructionsDirectory().path),
            suggestFiles: suggestFiles.map(\.fileName),
            design: try agent.designID.map { (try DesignExtension.installedPath(), $0, try DesignExtension.installedSkillDirectory()) },
            designTools: settings.designTool && agent.designID == nil && agent.coordinatorFor == nil && !isAutomation
                ? (try DesignExtension.installedPath(), try DesignExtension.installedSkillDirectory()) : nil,
            designReferences: wantsDesignReferences(for: agent, enabled: settings.designReferences, designTool: settings.designTool)
                ? (try DesignReferencesExtension.installedPath(), !agent.designGrants.isEmpty) : nil,
            mcp: agent.coordinatorFor == nil ? try mcp() : nil,
            worktreeOwningSpace: worktreeOwningSpace,
            browserExtensionPath: wantsBrowser(for: agent, enabled: settings.browser) ? try BrowserExtension.installedPath() : nil,
            contextExtensionPath: settings.trimToolOutput ? try ContextExtension.installedPath() : nil,
            projectContext: try project.map { (try ProjectContextExtension.installedPath(), try ProjectContextExtension.context($0), agent.coordinatorFor != nil) },
            specKit: specKit,
            deferTools: settings.deferTools,
            userHome: pi.userHome,
            // Use another model (an agent not signed in): its next start takes the model picked.
            // A child space's unset startup model and thinking follow its parent spaces (`inherited`).
            model: modelOverride ?? (sessionIsFresh ? agent.model ?? inherited?.model : nil),
            thinking: sessionIsFresh ? agent.thinkingLevel ?? inherited?.thinking.flatMap(ThinkingLevel.init(rawValue:)) : nil
        )
    }

    /// The panes extension (pane_*, agent_*, automation_*, notify) is for threads. A design's
    /// agent never gets it: its screen shows no panes, and it must not reach threads.
    public static func wantsPanes(for agent: Agent, enabled: Bool) -> Bool {
        enabled && agent.designID == nil && agent.coordinatorFor == nil
    }

    /// `review_diff` readies the side pane's Changes tab, which a design's screen has no room for and
    /// whose folder is no repository to review: a design's agent never gets it (docs/context-budget.md).
    public static func wantsReview(for agent: Agent, enabled: Bool) -> Bool {
        enabled && agent.designID == nil && agent.coordinatorFor == nil
    }

    /// The browser tools drive a thread's own Browser page: a design's agent never gets them (its
    /// screen has no Browser), and a native subagent never does either (it is launched with
    /// `--no-extensions` and none of Shepherd's variables).
    public static func wantsBrowser(for agent: Agent, enabled: Bool) -> Bool {
        enabled && agent.designID == nil && agent.coordinatorFor == nil
    }

    /// design_get and design_note are for threads: a design's agent never gets them (it reads its
    /// design with its own tools), and a thread gets them only while Settings ▸ Experiments ▸
    /// Design tool and Settings ▸ Pi ▸ Design references are both on. A running agent follows a
    /// change at its next start.
    public static func wantsDesignReferences(for agent: Agent, enabled: Bool, designTool: Bool) -> Bool {
        enabled && designTool && agent.designID == nil
    }

    /// An agent's working folder with `~` expanded, or the home folder when it is gone.
    public static func resolvedCwd(_ raw: String) -> String {
        let expanded = (raw as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue {
            return expanded
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }
}
