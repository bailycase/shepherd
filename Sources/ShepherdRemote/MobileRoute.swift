import Foundation
import ShepherdCore
import ShepherdProtocol

/// Every screen the app can show, iPhone and iPad alike. The shell knows only the top level: a
/// thread, and one case per track that wraps the track's own route value (the app maps it to a
/// destination view). A track adds screens by adding cases to its own
/// enum; it never edits this file or the shell.
///
/// Codable so the screenshot fixtures can name a screen in JSON.
public enum MobileRoute: Hashable, Codable, Sendable {
    case thread(AgentRef)
    case home(HomeRoute)
    case newThread(NewThreadRoute)
    case subagents(SubagentsRoute)
    case review(ReviewRoute)
    case search(SearchRoute)
    case settings(SettingsRoute)
    case terminal(TerminalRoute)
    case automations(AutomationsRoute)
    case designs(DesignsRoute)
    case padDesign(PadDesignRoute)
    case projects(ProjectsRoute)
    /// A side-pane tab's own screen on a phone (Files, Browser; SidePaneState.swift).
    case sidePane(SidePaneRoute)
    case browser(BrowserRoute)
    /// Issues & PRs (Forge/ForgeRoute.swift).
    case forge(ForgeRoute)

    /// Coarse screen kind only: associated values may contain private thread or file data.
    public var diagnosticScreen: String {
        switch self {
        case .thread: "thread"
        case .home: "home"
        case .newThread: "newThread"
        case .subagents: "subagents"
        case .review: "review"
        case .search: "search"
        case .settings: "settings"
        case .terminal: "terminal"
        case .automations: "automations"
        case .designs: "designs"
        case .padDesign: "padDesign"
        case .projects: "projects"
        case .sidePane: "sidePane"
        case .browser: "browser"
        case .forge: "forge"
        }
    }

    /// The thread a pushed screen belongs to (its runs, its review); nil for a thread itself
    /// and for screens of no one thread.
    public var thread: AgentRef? {
        switch self {
        case .subagents(let route): route.thread
        case .review(let route): route.thread
        case .terminal(let route): route.thread
        case .sidePane(let route): route.thread
        case .browser(let route): route.thread
        case .thread, .home, .newThread, .search, .settings, .automations, .designs, .padDesign, .projects, .forge: nil
        }
    }

    /// The host a route belongs to, so forgetting a host closes its screens.
    public var host: UUID? {
        switch self {
        case .thread(let ref): ref.host
        case .subagents(let route): route.thread.host
        case .review(let route): route.thread.host
        case .terminal(let route): route.thread.host
        case .sidePane(let route): route.thread.host
        case .browser(let route): route.thread.host
        case .automations(let route): route.host
        case .designs(let route): route.host
        case .padDesign(let route): route.host
        case .projects(let route): route.host
        case .forge(let route): route.host
        case .settings(.spaceConfiguration(let host, _, _, _)): host
        case .home, .newThread, .search, .settings: nil
        }
    }
}

/// One agent on one host: agent ids are only unique within the host that made them.
public struct AgentRef: Hashable, Codable, Sendable {
    public var host: UUID
    public var agent: AgentID

    public init(host: UUID, agent: AgentID) {
        self.host = host
        self.agent = agent
    }
}

/// The automations track's screens, pushed from the list (`.home(.automations)`) or presented.
public enum AutomationsRoute: Hashable, Codable, Sendable {
    /// One automation: its details, its runs, Run now and Stop (iPhone; the iPad shows it beside
    /// the list).
    case detail(host: UUID, automation: AutomationID)
    /// The form: a new automation (`automation` nil, on `host` or the first host that takes
    /// one), or an existing one's name, prompt, folder and switch. Presented.
    case edit(host: UUID?, automation: AutomationID?)

    public var host: UUID? {
        switch self {
        case .detail(let host, _): host
        case .edit(let host, _): host
        }
    }
}

/// The Browser's screens: a thread's page, pushed full screen at compact width (the side pane shows
/// `ThreadBrowserPane` in place).
public enum BrowserRoute: Hashable, Codable, Sendable {
    case page(AgentRef)

    public var thread: AgentRef {
        switch self {
        case .page(let ref): ref
        }
    }
}

/// A design on one host.
public struct PadDesignRef: Hashable, Codable, Sendable {
    public var host: UUID
    public var design: DesignID

    public init(host: UUID, design: DesignID) {
        self.host = host
        self.design = design
    }
}

/// The Design tool's screens on iPad (iPadDesign, iPadSplitView, iPadSidebar boards): the
/// Designs list the sidebar's row opens, and one design's canvas beside its chat. Only hosts
/// that offer `designs.v1` (their Design tool experiment on) have any.
public enum PadDesignRoute: Hashable, Codable, Sendable {
    /// Every connected host's designs.
    case list
    /// One design's canvas and chat.
    case design(PadDesignRef)

    public var host: UUID? {
        switch self {
        case .list: nil
        case .design(let ref): ref.host
        }
    }
}

/// The designs track's screens: a host's designs on the phone (MobileDesigns, MobileDesignBoard),
/// shown only for hosts that serve designs (`designs.v1`).
public enum DesignsRoute: Hashable, Codable, Sendable {
    /// Every host's designs and design systems (MobileDesigns), the Designs tab's root on iPhone.
    case list
    /// One design's boards (not drawn: a grid of its boards), from a tile, Recents or search.
    case design(HostDesignRef)
    /// One board full screen (MobileDesignBoard).
    case board(HostDesignRef, path: String)
    /// Every board of a design to jump to (the board's Boards), presented.
    case boards(HostDesignRef, current: String)
    /// A new design from a brief (not drawn), presented: Search's New design, the Designs screen's +.
    case newDesign(brief: String, host: UUID?)
    /// The hosts' design systems (Settings ▸ Design systems on iPhone).
    case systems
    /// One design system (not drawn): its colors, type and steps as the host read them.
    case system(host: UUID, namespace: String)

    /// The host it belongs to, so forgetting a host closes its screens.
    public var host: UUID? {
        switch self {
        case .design(let ref), .board(let ref, _), .boards(let ref, _): ref.host
        case .newDesign(_, let host): host
        case .system(let host, _): host
        case .list, .systems: nil
        }
    }
}

/// Issues & PRs' screens (MobileIPList, MobileIssueList, MobilePRDetail, MobileIssue; iPadIPReview,
/// iPadIssue; DuoBookPR, DuoClosedIPList). iPhone pushes the list from Home and each item over it;
/// iPad pushes the list over the detail and shows the chosen item beside it.
public enum ForgeRoute: Hashable, Codable, Sendable {
    /// Every host's repositories, one at a time: Issues | Pull requests, search, sections.
    case list
    /// One pull request (iPhone; the iPad shows it beside the list).
    case pullRequest(host: UUID, ref: ForgeItemRef)
    /// One issue (iPhone; the iPad shows it beside the list).
    case issue(host: UUID, ref: ForgeItemRef)
    /// One file of a pull request's diff (iPhone; the iPad shows it beside the pull request).
    case file(host: UUID, ref: ForgeItemRef, path: String)

    public var host: UUID? {
        switch self {
        case .list: nil
        case .pullRequest(let host, _), .issue(let host, _), .file(let host, _, _): host
        }
    }
}

/// Home's own screens (home track). On iPhone, Automations and More are tab roots
/// (`MobileRoute.isTabRoot`): opening one selects the Automations or Settings tab.
public enum HomeRoute: Hashable, Codable, Sendable {
    /// Everything waiting on you, across hosts.
    case needsYou
    /// Automations on every host (read-only in this release).
    case automations
    /// Fleet (what Hosts was): the Macs this device is paired with; on iPhone, the Settings tab.
    case more
}

/// New thread's screens (newthread track). Presented modally: `NewThreadHooks.open`.
public enum NewThreadRoute: Hashable, Codable, Sendable {
    /// The prompt with its repo, host, model and thinking chips; `host` preselects one.
    case compose(host: UUID?)
}

/// Projects' screens (the Mac's ProjectLead behavior on iPhone, iPad and iPhone Duo). A Project is
/// always owned by a paired host: every route names it through `LogicalProjectRef.home`.
public enum ProjectsRoute: Hashable, Codable, Sendable {
    case list
    /// The Project's conversation; on a wide window its tasks beside it.
    case project(LogicalProjectRef)
    /// The task list (pushed where the conversation has no room beside it).
    case tasks(LogicalProjectRef)
    /// One task's worker thread, read and steered through the owner.
    case task(LogicalProjectRef, ProjectTaskID)
    case files(LogicalProjectRef, path: String)
    case settings(LogicalProjectRef)
    /// Presented: New project on `host` (nil: the first owner that takes one).
    case create(host: UUID?)
    /// Presented: a new task for the Project's coordinator-free assignment.
    case assign(LogicalProjectRef)

    public var host: UUID? {
        let ref: LogicalProjectRef?
        switch self {
        case .list: return nil
        case .create(let host): return host
        case .project(let r), .tasks(let r), .task(let r, _), .files(let r, _), .settings(let r), .assign(let r): ref = r
        }
        if case .host(let id)? = ref?.home { return id }
        return nil
    }
}

/// Review's screens (review track): an agent's changes, one file's diff, and Commit.
public enum ReviewRoute: Hashable, Codable, Sendable {
    /// Working tree vs HEAD (or the PR): the file list, comments, Request changes and Commit;
    /// `file` picks one (the changes card's file, an edit line).
    case changes(AgentRef, file: String?)
    /// One file's diff.
    case diff(AgentRef, path: String)
    /// Commit from review on iPhone (Commit/): the message, the files, push or a pull request,
    /// run by the host. Presented; on iPad it is a popover beside Commit….
    case commit(AgentRef)
    /// The branch sheet the thread's ••• Branch opens (GitPhoneA, Thread/ThreadBranch.swift). Presented.
    case branch(AgentRef)

    public var thread: AgentRef {
        switch self {
        case .changes(let ref, _), .diff(let ref, _), .commit(let ref), .branch(let ref): ref
        }
    }
}

/// Search's screens (search track): threads and snippets across every host, the iPad palette,
/// and the agent actions' sheets.
public enum SearchRoute: Hashable, Codable, Sendable {
    /// iPhone (and an iPad window as narrow as one): the search screen, pushed.
    case search(query: String)
    /// iPad: the ⌘K palette over search and actions, presented.
    case palette(query: String)
    case rename(AgentRef)
    /// Move to Mac: the Macs of the thread's host's fleet, and what moving costs the turn.
    case moveToMac(AgentRef)
    /// Delete, or Delete Worktree Agent for a worktree agent.
    case delete(AgentRef)
    /// An action from a menu or the palette failed.
    case problem(title: String, message: String)
}

/// Settings' screens (home track). `open` shows them in the Settings tab on iPhone and over
/// the detail on iPad, where Settings' own pages show beside its list instead (`SettingsPage`).
public enum SettingsRoute: Hashable, Codable, Sendable {
    case root
    /// The Macs this device is paired with, their room and the Dispatches log; Add a Mac, and Forget.
    case fleet
    /// A host's form; nil adds one (Add a Mac). A paired host's form is no longer reachable: Fleet lists it.
    case host(UUID?)
    case appearance
    /// Sign-in, and what a host's new threads, text generation and image reading use.
    case models
    /// The queue, context, the threads a thread starts, and subagents; Profiles opens `subagents`.
    case agents
    /// How a host creates worktrees and handles them when the work is done (Git).
    case worktrees
    /// Every app on every host: its run, with Run, Stop and Restart (`apps.v2`); one app opens `app`.
    case apps
    /// One app's run and output; `id` is `AppRowValue.id`.
    case app(host: UUID, id: String)
    /// A host's MCP servers and its extensions, slash commands and daily updates.
    case tools
    /// Every slash command the host's pi lists, each with a switch. Opened from Tools.
    case slashCommands
    /// The fleet's subagent profiles; one profile's Markdown. Opened from Agents.
    case subagents
    case subagent(String)
    /// A host's spaces by folder. Older saved routes did not record the host.
    case spaces
    case space(String)
    /// Rename, hide, reorder and remove the host's spaces (`spaces.lifecycle.v1`). Opened from Spaces.
    case organizeSpaces
    case spaceConfiguration(host: UUID, directory: String, name: String, section: SpaceConfigurationSection? = nil)
    /// The root instructions every session Shepherd starts reads.
    case instructions
    /// One root instruction file in the editor.
    case instructionsFile(InstructionFile)
    /// Every host's agent skills: each on or off, their updates, and a search of skills.sh.
    case skills
    /// One installed skill: how the agent uses it, its version, which hosts have it, its files.
    case skill(String)
    /// A skill on skills.sh before it's installed: what it does, its files, and Install.
    case skillResult(DirectorySkill)
    /// Add skills from a repository, looking up the one given at once.
    case skillsRepo(String?)
    /// One host's hooks by event, each with its switch; Add and Edit open as a sheet.
    case hooks
    /// The files that host reads hooks from, and the Claude Code and Codex readers.
    case hookSources
    case experiments
    /// General: what to send, to which device, and from which hosts. Named for what it was; the
    /// thread menu's link to background alerts opens it.
    case notifications
    /// Advanced: whether this device sends crash and performance reports to Sentry.
    case diagnostics
    /// A suggested line waiting on a host: edit it, choose its file, add it or dismiss it.
    case suggestion(UUID)
}

public enum SpaceConfigurationSection: String, Identifiable, Codable, Sendable {
    case skills, extensions, prompts, agents, mcp
    public var id: Self { self }

    public var title: String {
        switch self {
        case .skills: "Skills"
        case .extensions: "Extensions"
        case .prompts: "Slash commands"
        case .agents: "Subagents"
        case .mcp: "MCP servers"
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        // Older window routes used the display titles as raw values.
        switch value {
        case "Skills": self = .skills
        case "Extensions": self = .extensions
        case "Slash commands": self = .prompts
        case "Subagents": self = .agents
        case "MCP servers": self = .mcp
        default:
            guard let section = Self(rawValue: value) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown space configuration section: \(value)")
            }
            self = section
        }
    }
}

/// Subagents' screens (subagents track): a thread's runs, and one run's transcript.
public enum SubagentsRoute: Hashable, Codable, Sendable {
    case list(AgentRef)
    case run(AgentRef, runID: String)

    public var thread: AgentRef {
        switch self {
        case .list(let ref), .run(let ref, _): ref
        }
    }
}

/// The terminal's screens (terminal track).
public enum TerminalRoute: Hashable, Codable, Sendable {
    /// iPhone: a thread's terminals, full screen; on regular width the side pane's Terminal tab.
    /// (The case keeps its stored name, so a saved route still restores.)
    case panes(AgentRef)

    public var thread: AgentRef {
        switch self {
        case .panes(let ref): ref
        }
    }
}

/// Files pushed on a phone: the pane's Files tab on regular width. (Browser has its own route,
/// `MobileRoute.browser`.)
public enum SidePaneRoute: Hashable, Codable, Sendable {
    case files(AgentRef)

    public var thread: AgentRef {
        switch self {
        case .files(let ref): ref
        }
    }

    public var tab: PadSidePaneTab { .files }
}

/// The phone's tabs (DuoClosedHome board). Codable as their case names, so a window saved
/// with only Home and Settings restores as it was.
public enum MobileTab: Hashable, Codable, CaseIterable, Sendable {
    case home, designs, projects, automations, settings
}

extension MobileTab {
    /// The tab a route belongs to on iPhone; nil for a screen that opens over whatever tab
    /// opened it (a thread and its screens, search, design systems).
    public static func owner(of route: MobileRoute) -> Self? {
        switch route {
        case .settings, .home(.more): .settings
        case .home(.automations), .automations: .automations
        case .home(.needsYou): .home
        case .designs(.systems), .designs(.system): nil
        case .designs, .padDesign: .designs
        case .projects: .projects
        case .thread, .subagents, .review, .terminal, .sidePane, .browser, .search, .newThread, .forge: nil
        }
    }

    /// Where `route` opens on iPhone when `current` is the selected tab: its own tab, else the
    /// current one. Settings keeps only its own screens and design systems (More's, now
    /// Settings'); a thread or search opened there goes to Home.
    public static func landing(of route: MobileRoute, from current: Self) -> Self {
        if let owner = owner(of: route) { return owner }
        if current == .settings, !route.isDesignSystems { return .home }
        return current
    }

    /// What iPad pushes for this tab's root when a compact window widens; nil for Home, whose
    /// root is the overview.
    var padRoot: MobileRoute? {
        switch self {
        case .home: nil
        case .designs: .padDesign(.list)
        case .projects: .projects(.list)
        case .automations: .home(.automations)
        case .settings: .settings(.root)
        }
    }
}

extension MobileRoute {
    /// A screen the phone shows as a tab's root rather than pushing it: opening it selects the
    /// tab and returns to its root.
    public var isTabRoot: Bool {
        switch self {
        case .settings(.root), .home(.more), .home(.automations), .designs(.list), .padDesign(.list), .projects(.list): true
        default: false
        }
    }

    fileprivate var isDesignSystems: Bool {
        switch self {
        case .designs(.systems), .designs(.system): true
        default: false
        }
    }
}

extension MobileRoute {
    /// The pane tab that shows this screen of a thread on regular width; nil for a screen that
    /// isn't one (a thread, Settings, a sheet's route).
    public var sidePaneTab: PadSidePaneTab? {
        switch self {
        case .review(.changes), .review(.diff): .changes
        case .terminal: .terminal
        case .subagents: .subagents
        case .sidePane(let route): route.tab
        case .browser: .browser
        default: nil
        }
    }

    /// The screen the phone pushes for a pane tab of `thread`.
    public static func paneScreen(_ tab: PadSidePaneTab, thread: AgentRef) -> MobileRoute {
        switch tab {
        case .changes: .review(.changes(thread, file: nil))
        case .files: .sidePane(.files(thread))
        case .terminal: .terminal(.panes(thread))
        case .subagents: .subagents(.list(thread))
        case .browser: .browser(.page(thread))
        }
    }
}
