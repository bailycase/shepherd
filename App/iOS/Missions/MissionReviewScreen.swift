import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// A mission's actual changes on its host (iPadMissionReview; the phone's pushed review): each
/// repository's branch and files, a file's diff, Request changes, Re-run all checks, and Publish.
/// Publish asks first and approves exactly the review fingerprint the host's validation saw, which
/// the host checks again against the worktrees before it commits or pushes anything.
struct MissionReviewScreen: View {
    let host: UUID
    let id: MissionID
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator
    @State private var busy = false
    @State private var failure: String?
    @State private var changes = ""
    @State private var confirmingPublish = false

    private var mobileHost: MobileHost? { hosts.hosts.first { $0.id == host } }

    var body: some View {
        Group {
            if let mobileHost, let mission = mobileHost.missions.record(id) {
                content(mission, missions: mobileHost.missions, hostName: mobileHost.name)
            } else {
                SHEmptyState(Text("Mission gone"), message: "This mission is no longer on its host, or the host is offline.") { EmptyView() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.sh.bgWindow)
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: mobileHost?.missions.record(id)?.run?.reviewFingerprint) { await load() }
    }

    private func content(_ mission: Mission, missions: RemoteMissions, hostName: String) -> some View {
        let reviews = missions.reviews[id]
        let controls = RemoteMissionControls(mission)
        let fingerprint = reviews.flatMap { RemoteMissionControls.publishable(mission, reviews: $0) }
        let published = mission.run?.publicationApproval != nil
        return ScrollView {
            VStack(alignment: .leading, spacing: MobileLayout.blockSpacing) {
                if let failure {
                    SHBanner(.failed, title: failure) { Button("OK") { self.failure = nil }.buttonStyle(.sh(.secondary)) }
                }
                if let reviews {
                    if fingerprint == nil, mission.run?.phase != .done {
                        SHBanner(.attention, title: published ? "Repository contents no longer match the approved receipts."
                                 : "These changes moved after validation. Re-run all checks before publishing.") {
                            Button("Refresh") { Task { await load() } }.buttonStyle(.sh(.secondary)).disabled(busy)
                        }
                    }
                    ForEach(reviews) { repository in repositoryCard(repository, mission: mission) }
                } else {
                    HStack(spacing: SH.Space.s) {
                        ProgressView().progressViewStyle(.shSpinner)
                        Text("Reading the repositories' changes on \(hostName)…").shText(.caption).foregroundStyle(Color.sh.textTertiary)
                    }
                }
                if controls.changes {
                    VStack(alignment: .leading, spacing: SH.Space.s) {
                        SHListHeader("Request changes", count: nil)
                        TextField("What should change? It goes back to the planner, and validation runs again.", text: $changes, axis: .vertical)
                            .shText(.body).lineLimit(2...8)
                            .padding(SH.Space.m)
                            .background(Color.sh.bgSunken, in: RoundedRectangle(cornerRadius: SH.Radius.m))
                        HStack(spacing: SH.Space.m) {
                            Button("Send changes") { act(mission, .changes(text: changes)) { changes = "" } }
                                .buttonStyle(.sh(.secondary)).disabled(busy || changes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            if controls.revalidate {
                                Button("Re-run all checks", systemImage: "arrow.clockwise") { act(mission, .revalidate) }
                                    .buttonStyle(.sh(.ghost)).disabled(busy)
                            }
                        }
                    }
                }
                if let checkouts = mission.run?.checkouts, checkouts.contains(where: { $0.prURL != nil }) {
                    VStack(alignment: .leading, spacing: SH.Space.s) {
                        SHListHeader("Pull requests", count: nil)
                        ForEach(checkouts.filter { $0.prURL != nil }) { checkout in
                            if let url = checkout.prURL.flatMap(URL.init(string:)) {
                                Link(destination: url) {
                                    Label(name(mission, checkout.spaceID) + " · " + (url.lastPathComponent), systemImage: "arrow.up.right.square")
                                        .shText(.ui)
                                }
                            }
                        }
                    }
                }
            }
            .padding(MobileLayout.gutter)
            .frame(maxWidth: MobileLayout.missionDetailMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await load() }
        .safeAreaInset(edge: .bottom) {
            if let fingerprint, mission.run?.phase != .publishing {
                let count = reviews?.count ?? 0
                Button {
                    confirmingPublish = true
                } label: {
                    Text(published ? "Retry publication" : "Approve \(count) PR\(count == 1 ? "" : "s") · publish").frame(maxWidth: .infinity)
                }
                .buttonStyle(.sh(.primary)).disabled(busy)
                .padding(.horizontal, MobileLayout.gutter).padding(.vertical, SH.Space.m)
                .background(Color.sh.bgWindow)
                .overlay(alignment: .top) { SHHairline() }
                .confirmationDialog("Publish \(count) pull request\(count == 1 ? "" : "s") from \(hostName)?",
                                    isPresented: $confirmingPublish, titleVisibility: .visible) {
                    Button(published ? "Retry publication" : "Publish") { act(mission, .publish(fingerprint: fingerprint)) }
                } message: {
                    Text("\(hostName) commits exactly the changes reviewed here (\(fingerprint.prefix(12))…) in \((reviews ?? []).map(\.name).joined(separator: ", ")), pushes each mission branch and opens one pull request per repository. It never merges, deploys or force-pushes. If anything changed since validation, the host refuses.")
                }
            }
        }
    }

    private func repositoryCard(_ repository: RemoteMissionReview, mission: Mission) -> some View {
        VStack(alignment: .leading, spacing: MobileLayout.headerSpacing) {
            HStack(spacing: SH.Space.s) {
                SHListHeader(repository.name, count: repository.files.count)
                Spacer(minLength: SH.Space.s)
                Text(repository.branch).shText(.micro).foregroundStyle(Color.sh.textTertiary).lineLimit(1).truncationMode(.head)
            }
            SHListCard {
                if repository.files.isEmpty {
                    Text("No changes").shText(.caption).foregroundStyle(Color.sh.textTertiary).padding(SH.Space.l)
                }
                ForEach(repository.files) { file in
                    Button {
                        navigator.open(.missions(.file(host: host, mission: id, space: repository.spaceID, path: file.path)))
                    } label: {
                        HStack(spacing: SH.Space.m) {
                            Text(file.path).shText(.mono).foregroundStyle(Color.sh.textPrimary).lineLimit(1).truncationMode(.head)
                            Spacer(minLength: SH.Space.s)
                            if file.isBinary { Text("binary").shText(.micro).foregroundStyle(Color.sh.textTertiary) }
                            else { SHDiffStat(added: file.added, removed: file.removed) }
                        }
                        .padding(SH.Space.l)
                        .frame(maxWidth: .infinity, minHeight: MobileLayout.rowHeight, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.shRow(radius: 0))
                }
            }
        }
    }

    private func name(_ mission: Mission, _ space: SpaceID) -> String {
        mission.draft.plan?.lanes.first { $0.spaceID == space }?.name ?? "repository"
    }

    private func load() async {
        guard let missions = mobileHost?.missions, missions.available else { return }
        do { try await missions.loadReview(id) } catch { failure = RemoteMissions.describe(error) }
    }

    private func act(_ mission: Mission, _ action: RemoteMissionAction, done: @escaping () -> Void = {}) {
        guard !busy, let missions = mobileHost?.missions else { return }
        busy = true
        failure = nil
        let revision = mission.revision
        Task { @MainActor in
            defer { busy = false }
            do {
                try await missions.perform(id, revision: revision, action)
                done()
                await load()
            } catch { failure = RemoteMissions.describe(error) }
        }
    }
}

/// One reviewed file's diff, read from the host with its hunks.
struct MissionFileScreen: View {
    let host: UUID
    let id: MissionID
    let space: SpaceID
    let path: String
    @Environment(MobileHosts.self) private var hosts
    @State private var rows: [SHDiffRow]?
    @State private var failure: String?

    var body: some View {
        ScrollView([.vertical]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let failure {
                    SHBanner(.failed, title: failure) { EmptyView() }.padding(MobileLayout.gutter)
                } else if let rows {
                    ForEach(rows) { row in
                        switch row {
                        case .hunk(_, let header):
                            Text(header).shText(.mono).foregroundStyle(Color.sh.textTertiary)
                                .padding(.horizontal, SH.Space.l).padding(.vertical, SH.Space.s)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.sh.bgSunken)
                        case .line(let line):
                            SHTouchDiffLine(line).equatable()
                        case .fold:
                            EmptyView()
                        }
                    }
                } else {
                    ProgressView().progressViewStyle(.shSpinner).padding(MobileLayout.gutter)
                }
            }
        }
        .background(Color.sh.bgWindow)
        .navigationTitle((path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard let missions = hosts.hosts.first(where: { $0.id == host })?.missions else { return }
            do { rows = Self.rows(try await missions.file(id, space: space, path: path)) }
            catch { failure = RemoteMissions.describe(error) }
        }
    }

    /// The file's hunks as touch-diff rows, plain text (derived once per read, never in `body`).
    static func rows(_ file: DiffFile) -> [SHDiffRow] {
        file.hunks.flatMap { hunk -> [SHDiffRow] in
            [.hunk(id: hunk.id, header: hunk.header)] + hunk.lines.map { line in
                let kind: SHDiffLineKind = switch line.kind { case .added: .added; case .removed: .removed; case .context: .context }
                return .line(SHDiffLineContent(id: "\(hunk.id)#\(line.id)", key: line.id, kind: kind, oldNumber: line.oldLine,
                                               newNumber: line.newLine, text: AttributedString(line.text), source: line.text))
            }
        }
    }
}
