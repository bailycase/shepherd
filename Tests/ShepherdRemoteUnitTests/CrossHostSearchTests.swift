import Foundation
import Testing
import ShepherdCore
@testable import ShepherdRemote

/// Search across hosts: title ranking, highlighting, snippets, which agents are asked, the
/// derived rows, and the bounded fan-out.
@Suite("Cross-host search")
struct CrossHostSearchTests {
    static let studio = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    static let build = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    static let laptop = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!

    static func target(_ agent: String, _ title: String, host: UUID = studio, status: AgentStatus = .idle,
                       space: String? = "Shepherd", online: Bool = true, searchable: Bool = true) -> SearchTarget {
        let name = host == studio ? "Studio" : host == build ? "build-01" : "MacBook Air"
        return SearchTarget(host: host, hostName: name, agent: AgentID(rawValue: agent), title: title, status: status,
                            space: space, online: online, searchable: searchable && online)
    }

    static let targets = [
        target("a", "Dock review pane", status: .blocked),
        target("b", "Plan shepherd extensions", status: .working),
        target("c", "Fix remote subagent deletion", space: "horizon"),
        target("d", "Fix terminal output buffer", host: build),
        target("e", "Review old notes", host: laptop, online: false),
    ]

    static let hosts = [
        SearchHost(id: studio, name: "Studio", online: true, searchable: true, agentCount: 3),
        SearchHost(id: build, name: "build-01", online: true, searchable: true, agentCount: 1),
        SearchHost(id: laptop, name: "MacBook Air", online: false, searchable: false, agentCount: 1),
    ]

    // MARK: Ranking and highlighting

    @Test(arguments: [
        ("dock", "Dock review pane", 0),
        ("rev", "Dock review pane", 1),
        ("view", "Dock review pane", 2),
        ("drp", "Dock review pane", 3),
        ("zebra", "Dock review pane", nil),
        ("output", "Fix terminal output-buffer", 1),
    ] as [(String, String, Int?)])
    func titlesRankPrefixThenWordThenSubstringThenSubsequence(query: String, title: String, rank: Int?) {
        #expect(CrossHostSearch.rank(query: query, in: title) == rank)
    }

    @Test func everyOccurrenceIsHighlightedWhateverItsCase() {
        let segments = CrossHostSearch.segments("Review the REVIEW pane", highlighting: "review")
        #expect(segments == [
            SearchSegment("Review", highlighted: true), SearchSegment(" the "),
            SearchSegment("REVIEW", highlighted: true), SearchSegment(" pane"),
        ])
        #expect(CrossHostSearch.segments("no match", highlighting: "x") == [SearchSegment("no match")])
        #expect(CrossHostSearch.segments("", highlighting: "x").isEmpty)
    }

    @Test(arguments: [
        ("…the funnel rows can't\n  be joined…", "“…the funnel rows can't be joined…”"),
        ("plain text", "“…plain text…”"),
        ("  …  ", ""),
    ])
    func snippetsAreOneQuotedLineElidedAtBothEnds(raw: String, shown: String) {
        #expect(CrossHostSearch.snippet(raw) == shown)
    }

    // MARK: Which threads match, and which are asked

    @Test func titleMatchesComeBestFirstThenBySpaceOrHost() {
        let titles = CrossHostSearch.threadMatches("review", in: Self.targets).map(\.agent.rawValue)
        // "Review old notes" is a prefix match; "Dock review pane" a word prefix.
        #expect(titles == ["e", "a"])
        let byHost = CrossHostSearch.threadMatches("build-01", in: Self.targets).map(\.agent.rawValue)
        #expect(byHost == ["d"])
        #expect(CrossHostSearch.threadMatches("  ", in: Self.targets).isEmpty)
    }

    @Test func conversationsAreAskedOnlyOnSearchableHostsForLongQueriesAndNeverForTitleMatches() {
        #expect(CrossHostSearch.contentTargets("re", in: Self.targets).isEmpty)
        let asked = CrossHostSearch.contentTargets("review", in: Self.targets).map(\.agent.rawValue)
        #expect(asked == ["b", "c", "d"])
    }

    // MARK: Rows

    @Test func resultsListTitleMatchesThenSnippetsInTheHostsOrder() {
        let outcomes: [SearchTarget.ID: SearchOutcome] = [
            Self.targets[3].id: .found(snippet: "…a review of the buffer…"),
            Self.targets[1].id: .found(snippet: "…review the extension points…"),
            Self.targets[2].id: SearchOutcome.none,
        ]
        let results = CrossHostSearch.results("review", targets: Self.targets, hosts: Self.hosts, outcomes: outcomes)
        #expect(results.sections.map(\.kind) == [.threads, .conversations])
        #expect(results.sections[0].rows.map(\.target.agent.rawValue) == ["e", "a"])
        // Answers landed out of order; rows keep the hosts' order.
        #expect(results.sections[1].rows.map(\.target.agent.rawValue) == ["b", "d"])
        #expect(results.sections[1].rows[0].detail.contains(SearchSegment("review", highlighted: true)))
        #expect(results.sections[0].rows[1].detail.map(\.text).joined() == "Needs you · Shepherd")
        #expect(results.progress == SearchProgress(searched: 3, total: 3))
        #expect(results.notices == ["MacBook Air is offline · its conversations weren’t searched"])
    }

    @Test func aHostThatFailedIsNamedOnceAndItsProgressCompletes() {
        var build = Self.hosts
        build[2].agentCount = 0
        let outcomes: [SearchTarget.ID: SearchOutcome] = [Self.targets[3].id: .failed("request timed out")]
        let results = CrossHostSearch.results("review", targets: Self.targets, hosts: build, outcomes: outcomes)
        #expect(results.progress == SearchProgress(searched: 1, total: 3))
        #expect(results.progress.isSearching)
        #expect(results.notices == ["build-01 couldn’t search: request timed out"])
    }

    @Test func shortQueriesMatchTitlesOnlyAndNameNoHost() {
        let results = CrossHostSearch.results("fi", targets: Self.targets, hosts: Self.hosts, outcomes: [:])
        #expect(results.sections.map(\.kind) == [.threads])
        #expect(results.progress == SearchProgress())
        #expect(results.notices.isEmpty)
        #expect(CrossHostSearch.results("", targets: Self.targets, hosts: Self.hosts, outcomes: [:]) == .empty)
    }

    @Test func anOldHostIsAskedToUpdate() {
        let hosts = [SearchHost(id: Self.build, name: "build-01", online: true, searchable: false, agentCount: 1)]
        let targets = [Self.target("d", "Fix terminal output buffer", host: Self.build, searchable: false)]
        let results = CrossHostSearch.results("buffer", targets: targets, hosts: hosts, outcomes: [:])
        #expect(results.notices == ["Update Shepherd on build-01 to search its conversations"])
        #expect(results.progress.total == 0)
    }

    // MARK: Fan-out

    actor Recorder {
        var inFlight: [UUID: Int] = [:]
        var peak: [UUID: Int] = [:]
        var asked: [String] = []

        func enter(_ target: SearchTarget) {
            inFlight[target.host, default: 0] += 1
            peak[target.host] = max(peak[target.host] ?? 0, inFlight[target.host]!)
            asked.append(target.agent.rawValue)
        }

        func leave(_ target: SearchTarget) { inFlight[target.host, default: 0] -= 1 }
    }

    @MainActor final class Delivered {
        var outcomes: [SearchTarget.ID: SearchOutcome] = [:]
        var count = 0
    }

    static func many(_ count: Int, host: UUID) -> [SearchTarget] {
        (0..<count).map { target("\(host == studio ? "s" : "b")\($0)", "Thread \($0)", host: host) }
    }

    @Test @MainActor func eachHostHasAtMostItsLimitInFlightAndEveryAgentIsAnsweredOnce() async {
        let recorder = Recorder()
        let delivered = Delivered()
        let targets = Self.many(8, host: Self.studio) + Self.many(5, host: Self.build)
        await CrossHostSearch.fanOut(targets, perHost: 2, search: { target in
            await recorder.enter(target)
            await Task.yield()
            await recorder.leave(target)
            return target.agent.rawValue.hasSuffix("3") ? "…match…" : nil
        }, deliver: { id, outcome in
            delivered.outcomes[id] = outcome
            delivered.count += 1
        })
        #expect(delivered.count == targets.count)
        #expect(Set(delivered.outcomes.keys) == Set(targets.map(\.id)))
        #expect(await recorder.peak.values.allSatisfy { $0 <= 2 })
        #expect(delivered.outcomes[targets[3].id] == .found(snippet: "…match…"))
        #expect(delivered.outcomes[targets[0].id] == SearchOutcome.none)
    }

    struct Refused: Error, CustomStringConvertible {
        var description: String { "update required" }
    }

    @Test @MainActor func aFailingHostStopsBeingAskedWhileOthersContinue() async {
        let recorder = Recorder()
        let delivered = Delivered()
        let targets = Self.many(4, host: Self.build) + Self.many(3, host: Self.studio)
        await CrossHostSearch.fanOut(targets, perHost: 1, search: { target in
            await recorder.enter(target)
            await recorder.leave(target)
            if target.host == Self.build { throw Refused() }
            return nil
        }, deliver: { id, outcome in
            delivered.outcomes[id] = outcome
            delivered.count += 1
        })
        let asked = await recorder.asked
        #expect(asked.filter { $0.hasPrefix("b") } == ["b0"])
        #expect(asked.filter { $0.hasPrefix("s") }.count == 3)
        #expect(delivered.count == targets.count)
        for target in targets where target.host == Self.build {
            #expect(delivered.outcomes[target.id] == .failed("update required"))
        }
    }

    @Test @MainActor func aCancelledSearchDeliversNothing() async {
        let delivered = Delivered()
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await CrossHostSearch.fanOut(Self.many(3, host: Self.studio), search: { _ in "…x…" },
                                         deliver: { _, _ in delivered.count += 1 })
        }
        await task.value
        #expect(delivered.count == 0)
    }
}
