import Foundation
import Observation
import ShepherdCore

struct ProjectCookieScope: Hashable {
    var projectID: SpaceID
    var hostID: UUID?
    var endpointID: UUID?
}

@MainActor @Observable final class ProjectCookiesModel {
    enum Removal: Equatable { case all, site(String) }
    typealias Read = @MainActor (ProjectCookieScope) async throws -> [BrowserCookieSite]
    typealias Clear = @MainActor (ProjectCookieScope, String?) async throws -> Void
    var filter = "" { didSet { derive() } }
    private(set) var sites: [BrowserCookieSite] = []
    private(set) var visible: [BrowserCookieSite] = []
    private(set) var scope: ProjectCookieScope?
    private(set) var loading = false
    private(set) var clearing = false
    var pending: Removal?
    var error: String?
    var notice: String?
    @ObservationIgnored private let read: Read
    @ObservationIgnored private let clear: Clear
    @ObservationIgnored private var revision = 0
    var total: Int { sites.reduce(0) { $0 + $1.count } }
    var countText: String {
        guard scope != nil, error == nil else { return "Unavailable" }
        return loading ? "Loading…" : "\(sites.count) \(sites.count == 1 ? "site" : "sites") · \(total) \(total == 1 ? "cookie" : "cookies")"
    }

    init(read: @escaping Read, clear: @escaping Clear) { self.read = read; self.clear = clear }

    func load(_ target: ProjectCookieScope?, force: Bool = false) async {
        if clearing {
            guard scope != target else { return }
            revision += 1; scope = target; loading = target != nil; pending = nil; sites = []; notice = nil; error = nil; derive()
            return
        }
        guard force || scope != target else { return }
        revision += 1; let token = revision
        scope = target; sites = []; pending = nil; notice = nil; error = nil; derive()
        guard let target else { loading = false; error = "This space is no longer available on the selected host."; return }
        loading = true
        do {
            let result = try await read(target)
            guard token == revision, !Task.isCancelled else { return }
            sites = sorted(result); derive()
        } catch { if token == revision { self.error = "Could not read space cookies on this Mac. Try again." } }
        if token == revision { loading = false }
    }

    func ask(_ removal: Removal) { guard !loading, !clearing, scope != nil, error == nil else { return }; pending = removal }

    func confirm(_ target: ProjectCookieScope?) async {
        guard let target, target == scope else { pending = nil; return }
        guard let pending, !clearing, !loading else { return }
        let site: String? = if case .site(let site) = pending { site } else { nil }
        let token = revision
        clearing = true; error = nil; notice = nil
        var deleted = false
        do {
            try await clear(target, site); deleted = true
            // WebKit can acknowledge deletion before its readback catches up.
            for attempt in 0..<20 {
                let result = try await read(target)
                guard token == revision, target == scope else { break }
                sites = sorted(result); derive()
                let removed = site.map { site in !result.contains { $0.site == site } } ?? result.isEmpty
                if removed {
                    notice = site.map { "Cleared cookies for \($0) in this space on this Mac." } ?? "Cleared all cookies for this space on this Mac."
                    break
                }
                if attempt == 19 { notice = "Cookies cleared. Open pages may have created new cookies."; break }
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            if token == revision {
                sites = []; derive()
                self.error = deleted ? "Cookies cleared, but the list could not be refreshed. Try again." : "Could not clear browser cookies on this Mac. Try again."
            }
        }
        clearing = false; self.pending = nil
        if token != revision { await load(scope, force: true) }
    }

    func invalidateForDisappear() {
        pending = nil
        if !clearing { revision += 1; loading = false }
    }

    private func sorted(_ values: [BrowserCookieSite]) -> [BrowserCookieSite] {
        values.sorted { $0.count != $1.count ? $0.count > $1.count : $0.site < $1.site }
    }

    private func derive() {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        visible = query.isEmpty ? sites : sites.filter { $0.site.localizedCaseInsensitiveContains(query) }
    }
}

private enum ProjectCookiesScopeError: Error { case changed }

extension ShepherdViewModel {
    func cookieScope(for row: ProjectsRow) -> ProjectCookieScope? {
        let spaces: [Space]
        let hostID: UUID?
        if row.host.id == "local" { spaces = state.spaces; hostID = nil }
        else {
            guard let id = UUID(uuidString: row.host.id),
                  let connection = remoteHosts.connections.first(where: { $0.id == id && $0.endpointID == row.host.endpointID }) else { return nil }
            spaces = connection.state.spaces; hostID = id
        }
        guard let space = spaces.first(where: { space in
            !space.hidden && !space.holdsDesigns && (row.project.projectID.map { space.id == $0 } ?? (space.path == row.project.directory))
        }) else { return nil }
        return ProjectCookieScope(projectID: space.id, hostID: hostID, endpointID: row.host.endpointID)
    }

    private func cookieScopeExists(_ scope: ProjectCookieScope) -> Bool {
        let spaces: [Space]
        if let hostID = scope.hostID {
            guard let host = remoteHosts.connections.first(where: { $0.id == hostID && $0.endpointID == scope.endpointID }) else { return false }
            spaces = host.state.spaces
        } else { spaces = state.spaces }
        return spaces.contains { $0.id == scope.projectID && !$0.hidden && !$0.holdsDesigns }
    }

    var projectCookies: ProjectCookiesModel {
        if let madeProjectCookies { return madeProjectCookies }
        let model = ProjectCookiesModel(read: { [weak self] scope in
            guard let self, cookieScopeExists(scope) else { throw ProjectCookiesScopeError.changed }
            return await browsers.cookieSites(projectID: scope.projectID, hostID: scope.hostID)
        }, clear: { [weak self] scope, site in
            guard let self, cookieScopeExists(scope) else { throw ProjectCookiesScopeError.changed }
            await browsers.clearCookies(projectID: scope.projectID, hostID: scope.hostID, site: site)
        })
        madeProjectCookies = model
        return model
    }
}
