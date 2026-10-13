import Foundation
import Observation
import ShepherdProtocol

/// Tabs are transient thread state. The original session anchors the collection without a cycle.
enum BrowserTabSource { case user, agent, link }
enum BrowserTabNotice { case popup, cap }

@MainActor @Observable
final class BrowserTabs {
    static let maxTabs = 8
    @ObservationIgnored private weak var root: BrowserSession?
    private var rootOpen = true
    private var closed = false
    private var additional: [BrowserSession] = []
    private var selectedID: UUID
    private var agentTargetID: UUID
    var notice: BrowserTabNotice?
    private(set) var openedPage: BrowserSession?
    @ObservationIgnored var operationTail: Task<Void, Never>?
    @ObservationIgnored var operationEpoch = 0

    init(root: BrowserSession) {
        self.root = root
        selectedID = root.tabID
        agentTargetID = root.tabID
    }

    var pages: [BrowserSession] { (rootOpen ? root.map { [$0] } ?? [] : []) + additional }
    var selectedPage: BrowserSession {
        // A mounted pane can observe cleanup before its thread leaves the view graph.
        pages.first { $0.tabID == selectedID } ?? pages.first ?? root!
    }
    var agentTarget: BrowserSession? { pages.first { $0.tabID == agentTargetID } }
    var agentPage: BrowserSession? { pages.first { $0.agentOverlay != nil } }
    var canAdd: Bool { !closed && pages.count < Self.maxTabs }

    func page(_ id: UUID) -> BrowserSession? { pages.first { $0.tabID == id } }

    @discardableResult
    func newTab() -> BrowserSession? { add(source: .user, select: true) }

    @discardableResult
    func add(source: BrowserTabSource, select: Bool) -> BrowserSession? {
        guard canAdd, let root else { notice = .cap; return nil }
        let page = root.makeTab(source: source)
        page.tabGroup = self
        additional.append(page)
        if select { self.select(page.tabID) }
        else { page.tabUnseen = true }
        if source == .agent { openedPage = page }
        return page
    }

    func select(_ id: UUID) {
        guard let page = page(id) else { return }
        selectedPage.parkOffscreen()
        selectedID = id
        page.tabUnseen = false
        if openedPage?.tabID == id { openedPage = nil }
    }

    func selectForAgent(_ id: UUID) -> Bool {
        guard page(id) != nil else { return false }
        agentTargetID = id
        return true
    }

    func close(_ id: UUID) {
        guard let page = page(id) else { return }
        let index = pages.firstIndex { $0.tabID == id } ?? 0
        if pages.count == 1 {
            // Keep the browser's empty state and its thread-level remote claim alive.
            _ = add(source: .user, select: true)
        }
        page.closePage()
        if page === root { rootOpen = false }
        else { additional.removeAll { $0.tabID == id } }
        if selectedID == id { selectedID = pages[min(index, pages.count - 1)].tabID }
        selectedPage.tabUnseen = false
        if openedPage?.tabID == id { openedPage = nil }
        // Closing the agent's tab does not silently retarget tools to the user's page.
    }

    func closeOthers() {
        let keep = selectedPage.tabID
        for page in pages where page.tabID != keep { close(page.tabID) }
    }

    func dismissNotice() { notice = nil; openedPage = nil }
    func showOpenedPage() { if let openedPage { select(openedPage.tabID) } }

    func handBack() { for page in pages { page.handBackPage() } }
    func closeAll() {
        closed = true
        operationEpoch &+= 1
        for page in pages { page.closePage() }
        additional.removeAll()
    }

    /// Serial across the thread, including targeted tools and tab mutations.
    func perform(_ request: BrowserRequest, origin: BrowserOrigin) async -> BrowserOutcome {
        let previous = operationTail
        let epoch = operationEpoch
        let work = Task { @MainActor in
            await previous?.value
            guard epoch == self.operationEpoch else {
                return BrowserOutcome.failure(code: "cancelled", message: "The request was cancelled before it started.")
            }
            return await self.run(request, origin: origin)
        }
        operationTail = Task { _ = await work.value }
        return await work.value
    }

    private func run(_ request: BrowserRequest, origin: BrowserOrigin) async -> BrowserOutcome {
        if let problem = BrowserRequestCheck.problem(with: request) { return .failure(code: "invalid", message: problem) }
        let epoch = operationEpoch
        switch request {
        case .tabs:
            var lines = [BrowserReport.notice]
            for page in pages {
                // Validate and report one snapshot. DNS can suspend while the user navigates.
                let url = page.currentURL
                let title = page.tabTitle
                let address = page.pageURLString ?? "about:blank"
                let isTarget = page === agentTarget
                if case .host(let guarder) = origin, await guarder.pageRefusal(url) != nil {
                    lines.append("\(page.tabID.uuidString) [private page]")
                } else {
                    lines.append("\(page.tabID.uuidString)\(isTarget ? " [agent target]" : "") \(title) \(address)")
                }
                guard epoch == operationEpoch else { return .failure(code: "cancelled", message: "The browser request was cancelled.") }
            }
            return .text(lines.joined(separator: "\n"))
        case .newTab(let url, let note):
            if let url, case .failure(let why) = BrowserURLPolicy.agentURL(url) {
                return .failure(code: "refused_url", message: why.message)
            }
            if let url, case .host(let guarder) = origin,
               let refusal = await guarder.refusal(for: .open(url: url, note: note), page: nil, historyTarget: nil) { return refusal }
            guard epoch == operationEpoch else { return .failure(code: "cancelled", message: "The browser request was cancelled.") }
            guard let page = add(source: .agent, select: false) else {
                return .failure(code: "too_many_tabs", message: "This thread has 8 tabs. Close a tab before opening another.")
            }
            agentTargetID = page.tabID
            guard let url else { return .text("Created tab \(page.tabID.uuidString).") }
            let outcome = await page.performPage(.open(url: url, note: note), origin: origin)
            return withTabID(outcome, page: page)
        case .selectTab(let id):
            guard let id = UUID(uuidString: id), selectForAgent(id) else { return missingTab() }
            return .text("Agent target is tab \(id.uuidString). The user's selected tab did not change.")
        case .closeTab(let id):
            guard let id = UUID(uuidString: id), let page = page(id) else { return missingTab() }
            guard !page.userHasControl else { return .failure(code: "taken_over", message: BrowserAgentPresence.takenOverMessage) }
            let url = page.currentURL
            let navigation = page.navigationSerial
            if case .host(let guarder) = origin, let refusal = await guarder.pageRefusal(url) { return refusal }
            guard epoch == operationEpoch, self.page(id) === page, !page.tabClosed else {
                return .failure(code: "cancelled", message: "The tab changed while the close request was being checked.")
            }
            guard page.currentURL == url, page.navigationSerial == navigation else {
                return .failure(code: "page_changed", message: "The page navigated while the close request was being checked. List tabs again.")
            }
            guard !page.userHasControl else { return .failure(code: "taken_over", message: BrowserAgentPresence.takenOverMessage) }
            close(id)
            return .text("Closed tab \(id.uuidString).")
        case .tab(let id, let inner):
            guard let id = UUID(uuidString: id), let page = page(id) else { return missingTab() }
            guard !inner.isTabManagement else { return .failure(code: "invalid", message: "Only page actions accept a tab target.") }
            agentTargetID = id
            let outcome = await page.performPage(inner, origin: origin)
            if case .open = inner, case .result = outcome { page.tabSource = .agent }
            return outcome
        default:
            guard let page = agentTarget else {
                return .failure(code: "no_tab", message: "The agent's tab was closed. Use browser_new_tab or browser_select_tab.")
            }
            if case .open(let url, let note) = request, page.tabSource == .user, page.hasPage, !page.userHasControl {
                // The first agent navigation must not replace a page the user opened by hand.
                return await run(.newTab(url: url, note: note), origin: origin)
            }
            let outcome = await page.performPage(request, origin: origin)
            if case .open = request, case .result = outcome { page.tabSource = .agent }
            return outcome
        }
    }

    private func missingTab() -> BrowserOutcome { .failure(code: "no_tab", message: "No such tab in this thread. Call browser_tabs.") }
    private func withTabID(_ outcome: BrowserOutcome, page: BrowserSession) -> BrowserOutcome {
        if case .result(let text, let image) = outcome { return .result(text: "Tab: \(page.tabID.uuidString)\n" + text, image: image) }
        return outcome
    }
}
