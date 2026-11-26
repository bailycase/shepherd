import Foundation
import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

// Small values the sidebar's rows and lists are made of, shared by the Mac and the iPhone and iPad.

/// A design on a remote host.
public struct RemoteDesignRef: Hashable, Sendable {
    public var hostID: UUID
    public var designID: DesignID

    public init(hostID: UUID, designID: DesignID) {
        self.hostID = hostID
        self.designID = designID
    }
}

/// This Mac, as the destination pages name it among the hosts.
public enum PageHost {
    /// This Mac's id among the hosts' (remote ids are random UUIDs).
    public static let localID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    public static let localName = "This Mac"
}

/// A thread row's pull request: its badge, and the line its help and VoiceOver label gain.
public struct SidebarPullRequest: Equatable {
    public var badge: SHSidebarRow.Badge
    public var line: String

    public init(badge: SHSidebarRow.Badge, line: String) {
        self.badge = badge
        self.line = line
    }
}

extension SidebarListRow {
    public mutating func attach(_ pull: SidebarPullRequest) {
        pullRequest = pull.badge
        help += "\n" + pull.line
        accessibilityLabel += ", " + pull.line
    }
}

/// One Project as the sidebar draws it, in either mode.
public struct SidebarLogicalProject: Identifiable, Equatable {
    public let ref: LogicalProjectRef
    public let name: String
    /// The host that owns it, when it is not this Mac ("demo-mac").
    public let hostName: String?
    /// Real thread count and state only: nothing here is synthetic. Empty until the lifecycle
    /// reports tasks for the project.
    public var summary: String?
    public var needsYou = false
    /// Its open threads (not resolved), the Spaces mode's count.
    public var count = 0
    public var selected = false
    public var id: LogicalProjectRef { ref }

    public init(ref: LogicalProjectRef, name: String, hostName: String?, summary: String? = nil, needsYou: Bool = false,
                count: Int = 0, selected: Bool = false) {
        self.ref = ref
        self.name = name
        self.hostName = hostName
        self.summary = summary
        self.needsYou = needsYou
        self.count = count
        self.selected = selected
    }
}


/// A pin in the main sidebar's Pinned: its kind's glyph, title and one word, and the preview its
/// hover shows.
public struct SidebarForgePin: Equatable, Identifiable {
    /// A preview line: a glyph (nil draws a dot) and its words.
    public struct Line: Equatable {
        public let symbol: String?
        public let text: String
        public let tone: ForgeTone

        public init(symbol: String?, text: String, tone: ForgeTone) {
            self.symbol = symbol
            self.text = text
            self.tone = tone
        }
    }

    public let ref: ForgeItemRef
    public let title: String
    public let tag: String
    public let tagTone: ForgeTone?
    /// "Open", "Merged": nil until the host could read it.
    public let badge: (label: String, tone: ForgeTone)?
    public let lines: [Line]

    public var id: ForgeItemRef { ref }
    /// "payments #31".
    public var place: String { "\(ref.repoName) #\(ref.number)" }

    public static func == (a: Self, b: Self) -> Bool {
        a.ref == b.ref && a.title == b.title && a.tag == b.tag && a.tagTone == b.tagTone && a.badge?.label == b.badge?.label
            && a.badge?.tone == b.badge?.tone && a.lines == b.lines
    }

    public init(_ item: ForgePinnedItem, viewer: String?) {
        ref = item.pin.ref
        title = item.title
        let tag = ForgePresentation.pinnedTag(item, viewer: viewer)
        self.tag = tag.label
        tagTone = tag.tone
        var lines: [Line] = []
        if let pull = item.pullRequest {
            badge = ForgePresentation.badge(pull.state)
            switch pull.reviewDecision {
            case .changesRequested?: lines.append(Line(symbol: ForgeSymbol.comment, text: "Changes requested", tone: .failed))
            case .approved?: lines.append(Line(symbol: "checkmark", text: "Approved", tone: .done))
            case .reviewRequired?: lines.append(Line(symbol: ForgeSymbol.comment, text: "Waiting on review", tone: .idle))
            case nil: break
            }
            switch pull.checks {
            case .failing: lines.append(Line(symbol: "xmark", text: "Checks failing", tone: .failed))
            case .running: lines.append(Line(symbol: nil, text: "Checks running", tone: .running))
            case .passed: lines.append(Line(symbol: "checkmark", text: "Checks passed", tone: .done))
            case .none: break
            }
            if let thread = pull.thread { lines.append(Line(symbol: nil, text: "Thread: \(thread.title)", tone: thread.running ? .running : .idle)) }
        } else if let issue = item.issue {
            badge = ForgePresentation.badge(issue.state)
            lines.append(Line(symbol: nil, text: ForgePresentation.label(issue.progress), tone: ForgePresentation.tone(issue.progress)))
            if let thread = issue.thread { lines.append(Line(symbol: nil, text: "Thread: \(thread.title)", tone: thread.running ? .running : .idle)) }
        } else {
            badge = nil
        }
        self.lines = lines
    }
}


/// The glyphs Issues & PRs draws. The boards' octicons have no SF Symbol; these are the nearest.
public enum ForgeSymbol {
    public static let pullRequest = "arrow.triangle.pull"
    public static let issue = "smallcircle.circle"
    public static let merge = "arrow.triangle.merge"
    public static let comment = "text.bubble"
    public static let push = "circle.and.line.horizontal"
    public static let link = "link"
    public static let external = "arrow.up.right.square"
    public static let review = "checkmark.bubble"
    public static let filter = "line.3.horizontal.decrease"
    public static let edit = "pencil"

    public static func kind(_ kind: ForgeKind) -> String { kind == .pullRequest ? pullRequest : issue }
}


// MARK: Words

/// The status language's words for an agent row.
public enum AgentRow {
    /// A finished agent whose turn ended in an error reads failed; so does one restored idle
    /// with that failure remembered (`Agent.lastFailure`).
    public static func statusWord(_ status: AgentStatus, turnFailed: Bool = false) -> String {
        switch status {
        case .working: "running"
        case .blocked: "needs you"
        case .idle: turnFailed ? "failed" : "idle"
        case .done: turnFailed ? "failed" : "done"
        }
    }
}

/// An automation run's state, as its row and menu read it.
public enum AutomationRow {
    /// A run still starting (idle before its first turn settled) reads running; one that has
    /// settled reads done, or failed when its last turn ended in an error.
    public static func stateWord(_ agent: Agent?, run: AutomationRun?, turnFailed: Bool) -> String {
        guard let agent else { return "stopped" }
        return switch agent.status {
        case .blocked: "needs you"
        case .working, .idle, .done:
            if isLive(agent, run: run) { "running" } else { turnFailed ? "failed" : "done" }
        }
    }

    /// Its run is going (`AutomationRun.isLive`, the rule the host refuses Run Now by): the
    /// menu offers Stop rather than Run Now.
    public static func isLive(_ agent: Agent?, run: AutomationRun?) -> Bool {
        agent.map { AutomationRun.isLive(agentStatus: $0.status, run: run) } ?? false
    }

    public static func state(_ agent: Agent?, run: AutomationRun?, turnFailed: Bool) -> AgentState {
        guard let agent else { return .idle }
        if agent.status == .blocked { return .attention }
        if isLive(agent, run: run) { return .running }
        return turnFailed ? .failed : .done
    }
}


extension AgentState {
    /// An agent's reported status: working runs, blocked needs you (the app's own mapping, kept here for the rows' dots).
    init(sidebarStatus status: AgentStatus) {
        switch status {
        case .working: self = .running
        case .blocked: self = .attention
        case .done: self = .done
        case .idle: self = .idle
        }
    }
}
