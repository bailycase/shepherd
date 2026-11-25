import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

// The pieces every Issues & PRs screen shares: the full-width switch, a row, a tag, the repo
// picker, and Activity's line and comment cards.

/// A list row (MobileIPList, MobileIssueList): the title over "#31 · baily · 2h", the state's word
/// and a chevron. The word is quiet unless the row needs you (changes requested, failed).
/// `chevron` is the phone's; the iPad's plain list marks the chosen row instead.
struct ForgeRowView: View, Equatable {
    let row: ForgeRow
    let selected: Bool
    var chevron = true

    var body: some View {
        let sh = Color.sh
        HStack(alignment: .center, spacing: SH.Space.l) {
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(row.title)
                    .font(.shSans(MobileLayout.touchBodyFont, .medium))
                    .foregroundStyle(sh.textPrimary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text(row.byline)
                    .font(.shSans(MobileLayout.touchDetailFont))
                    .foregroundStyle(sh.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(row.word)
                .font(.shSans(MobileLayout.touchDetailFont, row.tone == .attention ? .medium : .regular))
                .foregroundStyle(wordColor)
                .lineLimit(1)
                .fixedSize()
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.shSans(MobileLayout.touchDetailFont, .medium))
                    .foregroundStyle(sh.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, MobileLayout.gutter)
        .padding(.vertical, SH.Space.m + SH.Space.xxs)
        .frame(maxWidth: .infinity, minHeight: MobileLayout.touchRowHeight, alignment: .leading)
        .background(selected ? sh.bgSelected : .clear, in: RoundedRectangle(cornerRadius: chevron ? 0 : MobileLayout.touchCardRadius))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.title), \(row.word)")
        .accessibilityValue(row.byline)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    /// Attention in its orange, a failure in red; everything else set back.
    private var wordColor: Color {
        switch row.tone {
        case .attention: Color.sh.lanternText
        case .failed: Color.sh.failed
        case .running, .done, .idle, .merged: Color.sh.textTertiary
        }
    }
}

/// A label tag ("bug", "ledger"): the word in a capsule on the selected tint.
struct ForgeTag: View {
    let text: String
    var mono = false

    var body: some View {
        Text(text)
            .font(mono ? .shMono(MobileLayout.touchDetailFont - 1) : .shSans(MobileLayout.touchDetailFont, .medium))
            .foregroundStyle(Color.sh.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, SH.Space.l)
            .padding(.vertical, SH.Space.xs + SH.Space.xxs)
            .background(Color.sh.bgSelected, in: Capsule())
            .fixedSize()
    }
}

/// The repository picker ("All"): the hosts' repositories, under each host's name when there are
/// several, and Refresh.
struct ForgeRepoPicker: View {
    let store: ForgeStore

    var body: some View {
        let sh = Color.sh
        Menu {
            ForgeRepoMenuItems(store: store)
            Divider()
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await store.loadRepos(); await store.loadLists() }
            }
        } label: {
            Text(store.allRepos ? "All" : store.repo?.repo.name ?? "Repository")
                .font(.shSans(MobileLayout.touchBodyFont, .medium))
                .foregroundStyle(sh.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, SH.Space.m)
                .frame(minHeight: SH.Height.touch)
                .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .disabled(store.repos.isEmpty)
        .accessibilityLabel("Repository")
        .accessibilityValue(store.allRepos ? "All repositories" : store.repo?.repo.nameWithOwner ?? "none")
    }
}

/// The repositories to pick: All, then each host's, checked when chosen.
struct ForgeRepoMenuItems: View {
    let store: ForgeStore

    var body: some View {
        let hostIDs = store.repos.reduce(into: [UUID]()) { if !$0.contains($1.host) { $0.append($1.host) } }
        if store.browseHost != nil {
            Button {
                store.repoID = ForgeStore.allID
                store.clearSearch()
            } label: {
                if store.allRepos { Label("All repositories", systemImage: "checkmark") } else { Text("All repositories") }
            }
            Divider()
        }
        if hostIDs.count > 1 {
            ForEach(hostIDs, id: \.self) { host in
                Section(store.hostName(host)) { choices(store.repos.filter { $0.host == host }) }
            }
        } else {
            choices(store.repos)
        }
    }

    private func choices(_ repos: [ForgeRepoChoice]) -> some View {
        ForEach(repos) { choice in
            Button {
                store.repoID = choice.id
                store.clearSearch()
            } label: {
                if choice.id == store.repo?.id {
                    Label(choice.repo.nameWithOwner, systemImage: "checkmark")
                } else {
                    Text(choice.repo.nameWithOwner)
                }
            }
        }
    }
}

/// Activity's quiet line ("agent pushed 1 commit  12m"), a row of the activity card.
struct ForgeActivityLine: View {
    let actor: String
    let text: String
    let age: String

    var body: some View {
        let sh = Color.sh
        HStack(spacing: SH.Space.m) {
            Text("\(actor) \(text)")
                .font(.shSans(MobileLayout.touchBodyFont, .medium))
                .foregroundStyle(sh.textPrimary)
                .lineLimit(2)
            Spacer(minLength: SH.Space.m)
            Text(age).font(.shSans(MobileLayout.touchDetailFont)).foregroundStyle(sh.textTertiary)
        }
        .padding(.horizontal, MobileLayout.gutter)
        .frame(maxWidth: .infinity, minHeight: MobileLayout.touchRowHeight, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// A comment (MobilePRDetail, MobileIssue): the author in semibold, the line it is on, its age,
/// then the text. GitHub's text, shown as plain text.
struct ForgeCommentCard: View {
    let author: String
    let location: String?
    let body_: String
    let age: String

    init(author: String, location: String?, body: String, age: String) {
        self.author = author
        self.location = location
        body_ = body
        self.age = age
    }

    var body: some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: SH.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
                Text(author).font(.shSans(MobileLayout.touchBodyFont, .semibold)).foregroundStyle(sh.textPrimary)
                if let location { place(location) }
                Spacer(minLength: SH.Space.m)
                Text(age).font(.shSans(MobileLayout.touchDetailFont)).foregroundStyle(sh.textTertiary)
            }
            Text(body_)
                .font(.shSans(MobileLayout.touchBodyFont))
                .lineSpacing(SH.Space.xxs + SH.Space.xxs)
                .foregroundStyle(sh.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.horizontal, MobileLayout.gutter)
        .padding(.vertical, SH.Space.l + SH.Space.xxs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// "ledger/outbox.go · line 103": the path in mono, the rest in words.
    private func place(_ location: String) -> some View {
        let parts = location.components(separatedBy: " \u{00B7} ")
        return (Text(parts[0]).font(.shMono(MobileLayout.touchDetailFont - 1))
            + Text(parts.dropFirst().isEmpty ? "" : " \u{00B7} " + parts.dropFirst().joined(separator: " \u{00B7} "))
            .font(.shSans(MobileLayout.touchDetailFont)))
            .foregroundStyle(Color.sh.textSecondary)
            .lineLimit(1)
            .truncationMode(.head)
    }
}

/// Activity, oldest first, as one card of rows.
struct ForgeActivityList: View {
    let items: [ForgeActivityItem]

    var body: some View {
        ReviewLazyCard(items) { item in
            VStack(spacing: 0) {
                switch item.kind {
                case .line(let actor, let text): ForgeActivityLine(actor: actor, text: text, age: item.age)
                case .comment(let author, let location, let body): ForgeCommentCard(author: author, location: location, body: body, age: item.age)
                }
            }
        }
    }
}

/// A read that failed, with Retry.
struct ForgeErrorState: View {
    let error: ForgeError
    let retry: () -> Void

    var body: some View {
        SHEmptyState(Text(Self.title(error)), message: error.message) {
            if error.code != .unsupported {
                Button("Try again", action: retry).buttonStyle(.sh(.secondary))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, SH.Space.xxl)
    }

    static func title(_ error: ForgeError) -> String {
        switch error.code {
        case .ghMissing: "GitHub CLI isn't installed"
        case .signedOut: "GitHub CLI isn't signed in"
        case .unsupported: "Update Shepherd on the Mac"
        case .unreachable: "Couldn't reach the host"
        case .notFound: "Not found on GitHub"
        case .rateLimited: "GitHub is rate limiting"
        case .timedOut: "GitHub took too long"
        case .invalid, .failed: "Couldn't read GitHub"
        }
    }
}

extension ForgeTone {
    /// The agent state of the same name; nil for `merged`, which has none.
    var state: AgentState? { AgentState(rawValue: rawValue) }

    /// Dots and glyphs. Merged has no status role, so it takes the keyword hue (GitHub's purple).
    @MainActor var color: Color { state?.color ?? Color.sh.synKeyword }
    /// The word.
    @MainActor var textColor: Color { state?.textColor ?? Color.sh.synKeyword }
    /// A tag's fill; neutral where the state has none.
    @MainActor var tint: Color { state?.tint ?? Color.sh.bgSelected }
}
