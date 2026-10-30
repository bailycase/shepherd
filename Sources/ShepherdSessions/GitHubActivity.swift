import Foundation
import ShepherdCore

/// Recent activity on one repository, read in a single GraphQL call: the 20 issues and 20 pull
/// requests updated most recently, each with its latest labels, comments, reviews and merge.
/// Ordering by update time is what makes one query enough: labeling, commenting, reviewing,
/// pushing and merging all bump an item's `updatedAt`.
public struct GitHubItem: Hashable, Sendable {
    public enum Activity: Hashable, Sendable {
        case labeled(label: String, actor: String?)
        case comment(author: String?, association: String, body: String, url: String?)
        case review(author: String?, association: String, body: String, url: String?, state: String)
        case merged
    }

    public struct Event: Hashable, Sendable {
        public var id: String
        public var at: Date
        public var activity: Activity
    }

    public var repo: String
    public var number: Int
    public var isPullRequest: Bool
    public var title: String
    public var body: String
    public var url: String?
    public var createdAt: Date
    public var author: String?
    public var association: String
    public var labels: [String]
    /// A pull request's head commit.
    public var headOID: String?
    public var events: [Event]

    /// "owner/name#12": runs, windows and heads are per item.
    public var key: String { "\(repo)#\(number)" }
}

public enum GitHubActivity {
    static let query = """
    query($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) {
        issues(first: 20, orderBy: {field: UPDATED_AT, direction: DESC}) {
          nodes {
            number title body url createdAt authorAssociation author { login }
            labels(first: 20) { nodes { name } }
            timelineItems(last: 25, itemTypes: [LABELED_EVENT, ISSUE_COMMENT]) { nodes { ...Activity } }
          }
        }
        pullRequests(first: 20, orderBy: {field: UPDATED_AT, direction: DESC}) {
          nodes {
            number title body url createdAt authorAssociation author { login } headRefOid
            labels(first: 20) { nodes { name } }
            timelineItems(last: 25, itemTypes: [LABELED_EVENT, ISSUE_COMMENT, PULL_REQUEST_REVIEW, MERGED_EVENT]) { nodes { ...Activity } }
          }
        }
      }
    }
    fragment Activity on Node {
      __typename
      ... on LabeledEvent { id createdAt actor { login } label { name } }
      ... on IssueComment { id createdAt url body authorAssociation author { login } }
      ... on PullRequestReview { id submittedAt url body state authorAssociation author { login } }
      ... on MergedEvent { id createdAt }
    }
    """

    /// The `gh api graphql --input -` body for a repository ("owner/name").
    public static func request(repo: String) -> Data {
        let parts = repo.split(separator: "/", maxSplits: 1).map(String.init)
        let body: [String: Any] = ["query": query, "variables": ["owner": parts.first ?? "", "name": parts.last ?? ""]]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    public struct ResponseError: Error, Equatable, CustomStringConvertible {
        public var description: String
        /// The repository can't be read at all (missing, renamed, no access): pause, don't retry.
        public var permanent: Bool
    }

    /// Items from a GraphQL response. Missing optional fields read as empty.
    public static func parse(_ data: Data, repo: String) throws -> [GitHubItem] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ResponseError(description: "GitHub answered with something other than JSON.", permanent: false)
        }
        if let errors = root["errors"] as? [[String: Any]], !errors.isEmpty {
            let message = (errors.first?["message"] as? String) ?? "GitHub refused the query."
            let notFound = errors.contains { ($0["type"] as? String) == "NOT_FOUND" }
            throw ResponseError(description: notFound ? "Repository \(repo) wasn't found, or gh can't see it." : message,
                                permanent: notFound)
        }
        guard let repository = (root["data"] as? [String: Any])?["repository"] as? [String: Any] else {
            throw ResponseError(description: "Repository \(repo) wasn't found, or gh can't see it.", permanent: true)
        }
        func nodes(_ any: Any?) -> [[String: Any]] { ((any as? [String: Any])?["nodes"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? [] }
        func item(_ node: [String: Any], isPR: Bool) -> GitHubItem? {
            guard let number = node["number"] as? Int, let created = date(node["createdAt"]) else { return nil }
            let events: [GitHubItem.Event] = nodes(node["timelineItems"]).compactMap { activity in
                guard let id = activity["id"] as? String else { return nil }
                let login = ((activity["author"] ?? activity["actor"]) as? [String: Any])?["login"] as? String
                let association = activity["authorAssociation"] as? String ?? "NONE"
                let body = activity["body"] as? String ?? ""
                let url = activity["url"] as? String
                switch activity["__typename"] as? String {
                case "LabeledEvent":
                    guard let at = date(activity["createdAt"]),
                          let label = (activity["label"] as? [String: Any])?["name"] as? String else { return nil }
                    return .init(id: id, at: at, activity: .labeled(label: label, actor: login))
                case "IssueComment":
                    guard let at = date(activity["createdAt"]) else { return nil }
                    return .init(id: id, at: at, activity: .comment(author: login, association: association, body: body, url: url))
                case "PullRequestReview":
                    let state = activity["state"] as? String ?? ""
                    guard state != "PENDING", let at = date(activity["submittedAt"]) else { return nil }
                    return .init(id: id, at: at, activity: .review(author: login, association: association, body: body, url: url, state: state))
                case "MergedEvent":
                    guard let at = date(activity["createdAt"]) else { return nil }
                    return .init(id: id, at: at, activity: .merged)
                default: return nil
                }
            }
            return GitHubItem(
                repo: repo, number: number, isPullRequest: isPR, title: node["title"] as? String ?? "",
                body: node["body"] as? String ?? "", url: node["url"] as? String, createdAt: created,
                author: (node["author"] as? [String: Any])?["login"] as? String,
                association: node["authorAssociation"] as? String ?? "NONE",
                labels: nodes(node["labels"]).compactMap { $0["name"] as? String },
                headOID: node["headRefOid"] as? String, events: events)
        }
        return nodes(repository["issues"]).compactMap { item($0, isPR: false) }
            + nodes(repository["pullRequests"]).compactMap { item($0, isPR: true) }
    }

    private static func date(_ any: Any?) -> Date? {
        guard let text = any as? String else { return nil }
        return ISO8601DateFormatter().date(from: text)
    }

    /// The events these items hold for an automation's triggers, oldest first, each once
    /// (an occurrence that matches several triggers is credited to the first). `heads` is the
    /// last head commit seen per pull request; a changed one is a commits event at `now`.
    /// Nothing at or before `since` is returned.
    public static func events(in items: [GitHubItem], triggers: [GitHubTrigger], repoOf: (GitHubTrigger) -> String?,
                              gate: AutomationAuthorGate, since: Date, now: Date,
                              heads: [String: String]) -> [AutomationEvent] {
        var found: [String: AutomationEvent] = [:]
        for item in items {
            for (index, trigger) in triggers.enumerated() where repoOf(trigger)?.lowercased() == item.repo.lowercased() {
                for occurrence in occurrences(of: item, heads: heads, now: now) where occurrence.at > since {
                    guard found[occurrence.id] == nil, trigger.events.contains(occurrence.kind),
                          matches(trigger, item: item, occurrence: occurrence),
                          admits(gate, item: item, occurrence: occurrence) else { continue }
                    found[occurrence.id] = AutomationEvent(
                        id: occurrence.id, kind: occurrence.kind, repo: item.repo, number: item.number, title: item.title,
                        url: occurrence.url ?? item.url, author: occurrence.author ?? item.author,
                        body: occurrence.body ?? item.body, detail: occurrence.detail, triggerIndex: index,
                        occurredAt: occurrence.at.timeIntervalSince1970)
                }
            }
        }
        return found.values.sorted { ($0.occurredAt, $0.id) < ($1.occurredAt, $1.id) }
    }

    struct Occurrence {
        var id: String
        var kind: GitHubEventKind
        var at: Date
        var author: String?
        var association: String?
        var body: String?
        var url: String?
        var detail: String?
        /// For a labeled event: who added the label.
        var actor: String?
    }

    static func occurrences(of item: GitHubItem, heads: [String: String], now: Date) -> [Occurrence] {
        let pr = item.isPullRequest
        var list = [Occurrence(id: "\(item.key):opened", kind: pr ? .pullRequestOpened : .issueOpened, at: item.createdAt)]
        for event in item.events {
            switch event.activity {
            case .labeled(let label, let actor):
                list.append(Occurrence(id: "\(item.key):labeled:\(event.id)", kind: pr ? .pullRequestLabeled : .issueLabeled,
                                       at: event.at, detail: label, actor: actor))
            case .comment(let author, let association, let body, let url):
                list.append(Occurrence(id: "\(item.key):comment:\(event.id)", kind: pr ? .pullRequestComment : .issueComment,
                                       at: event.at, author: author, association: association, body: body, url: url))
            case .review(let author, let association, let body, let url, let state):
                guard pr else { continue }
                list.append(Occurrence(id: "\(item.key):review:\(event.id)", kind: .pullRequestReview, at: event.at,
                                       author: author, association: association, body: body, url: url,
                                       detail: state.lowercased().replacingOccurrences(of: "_", with: " ")))
            case .merged:
                guard pr else { continue }
                list.append(Occurrence(id: "\(item.key):merged", kind: .pullRequestMerged, at: event.at))
            }
        }
        if pr, let head = item.headOID, let previous = heads[item.key], previous != head {
            list.append(Occurrence(id: "\(item.key):commits:\(head)", kind: .pullRequestCommits, at: now, detail: head))
        }
        return list
    }

    static func matches(_ trigger: GitHubTrigger, item: GitHubItem, occurrence: Occurrence) -> Bool {
        if let number = trigger.number, number != item.number { return false }
        if let text = trigger.titleContains?.trimmingCharacters(in: .whitespaces), !text.isEmpty,
           !item.title.localizedCaseInsensitiveContains(text) { return false }
        if !trigger.authors.isEmpty {
            guard let author = item.author, trigger.authors.contains(where: { $0.caseInsensitiveCompare(author) == .orderedSame }) else { return false }
        }
        if !trigger.labels.isEmpty {
            let wanted = Set(trigger.labels.map { $0.lowercased() })
            switch occurrence.kind {
            case .issueLabeled, .pullRequestLabeled:
                guard let added = occurrence.detail, wanted.contains(added.lowercased()) else { return false }
            default:
                guard item.labels.contains(where: { wanted.contains($0.lowercased()) }) else { return false }
            }
        }
        return true
    }

    /// The author gate, enforced before anything reaches a model. Comments and reviews are gated
    /// on their own author; a label someone else added passes (only triagers can label), while a
    /// label the item's author applied (an issue template) is gated on that author; a merge
    /// passes (only writers merge); everything else is gated on the item's author.
    static func admits(_ gate: AutomationAuthorGate, item: GitHubItem, occurrence: Occurrence) -> Bool {
        switch occurrence.kind {
        case .issueComment, .pullRequestComment, .pullRequestReview:
            return gate.admits(occurrence.association ?? "NONE")
        case .issueLabeled, .pullRequestLabeled:
            if let actor = occurrence.actor, let author = item.author, actor.caseInsensitiveCompare(author) != .orderedSame {
                return true
            }
            return gate.admits(item.association)
        case .pullRequestMerged:
            return true
        case .issueOpened, .pullRequestOpened, .pullRequestCommits:
            return gate.admits(item.association)
        }
    }

    /// "owner/name" from a git remote URL (https, ssh or scp-like), nil for anything not GitHub.
    public static func repo(fromRemote url: String) -> String? {
        var text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://github.com/", "http://github.com/", "ssh://git@github.com/", "git@github.com:", "git://github.com/"]
        where text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
            if text.hasSuffix(".git") { text = String(text.dropLast(4)) }
            if text.hasSuffix("/") { text = String(text.dropLast()) }
            let parts = text.split(separator: "/")
            return parts.count == 2 ? text : nil
        }
        return nil
    }
}
