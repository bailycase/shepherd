import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

// The pieces every Issues & PRs screen shares: the full-width switch, a row, a tag, the repo
// picker, and Activity's line and comment cards.

/// The boards' full-width switch (Issues | Pull requests; Summary | Changes | Checks): 44pt, each
/// segment with an optional count or status dot. Reads as a set of selectable buttons.
struct ForgeSegmented<Value: Hashable>: View {
    struct Option: Identifiable {
        let value: Value
        let title: String
        var count: Int? = nil
        var dot: ForgeTone? = nil
        var id: Value { value }
    }

    @Binding var selection: Value
    let options: [Option]

    var body: some View {
        let sh = Color.sh
        HStack(spacing: SH.Space.xxs) {
            ForEach(options) { option in
                let selected = option.value == selection
                Button { selection = option.value } label: {
                    HStack(spacing: SH.Space.s) {
                        Text(option.title)
                            .font(.sh(.ui, weight: selected ? .semibold : .medium))
                            .foregroundStyle(selected ? sh.textPrimary : sh.textSecondary)
                            .lineLimit(1)
                        if let count = option.count {
                            Text("\(count)").font(.sh(.micro, weight: .regular)).foregroundStyle(sh.textTertiary)
                        }
                        if let dot = option.dot {
                            Circle().fill(dot.color).frame(width: MobileLayout.statusDot, height: MobileLayout.statusDot)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: SH.Height.touch - 2 * SH.Space.xxs)
                    .background(selected ? sh.bgSelected : .clear, in: RoundedRectangle(cornerRadius: SH.Radius.m))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibility(option))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(SH.Space.xxs)
        .background(sh.bgSunken, in: RoundedRectangle(cornerRadius: SH.Radius.l))
        .shBorder(sh.lineSubtle, radius: SH.Radius.l)
    }

    private func accessibility(_ option: Option) -> String {
        var text = option.title
        if let count = option.count { text += ", \(count)" }
        if let dot = option.dot { text += ", \(dot.state?.label ?? "merged")" }
        return text
    }
}

/// A list row (MobileIPList): the state dot, the title over "#31 · baily · 2h", the word.
struct ForgeRowView: View, Equatable {
    let row: ForgeRow
    let selected: Bool

    var body: some View {
        let sh = Color.sh
        HStack(alignment: .top, spacing: SH.Space.l) {
            Circle().fill(row.tone.color)
                .frame(width: MobileLayout.statusDot, height: MobileLayout.statusDot)
                .padding(.top, SH.Space.s + SH.Space.xxs)
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(row.title)
                    .font(.sh(.body))
                    .foregroundStyle(sh.textPrimary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text(row.byline)
                    .font(.sh(.caption))
                    .foregroundStyle(sh.textTertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(row.word)
                .font(.sh(.caption, weight: .medium))
                .foregroundStyle(row.tone.textColor)
                .lineLimit(1)
                .fixedSize()
                .padding(.top, SH.Space.xxs)
        }
        .padding(.horizontal, SH.Space.l)
        .padding(.vertical, SH.Space.l)
        .frame(maxWidth: .infinity, minHeight: SH.Height.touch, alignment: .leading)
        .background(selected ? sh.bgSelected : .clear)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.title), \(row.word)")
        .accessibilityValue(row.byline)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

/// A state or label tag ("Open", "Merged", "bug"): the word on its tone's fill.
struct ForgeTag: View {
    let text: String
    let tone: ForgeTone

    var body: some View {
        Text(text)
            .font(.sh(.caption, weight: .medium))
            .foregroundStyle(tone.textColor)
            .lineLimit(1)
            .padding(.horizontal, SH.Space.m)
            .padding(.vertical, SH.Space.xxs)
            .background(tone.tint, in: RoundedRectangle(cornerRadius: SH.Radius.s))
            .fixedSize()
    }
}

/// The repository picker ("payments ▾"): the hosts' repositories, under each host's name when
/// there are several.
struct ForgeRepoPicker: View {
    let store: ForgeStore

    var body: some View {
        let sh = Color.sh
        let hostIDs = store.repos.reduce(into: [UUID]()) { if !$0.contains($1.host) { $0.append($1.host) } }
        Menu {
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
        } label: {
            HStack(spacing: SH.Space.xs) {
                Text(store.allRepos ? "All" : store.repo?.repo.name ?? "Repository")
                    .font(.sh(.ui, weight: .medium))
                    .foregroundStyle(sh.textPrimary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.sh(.micro, weight: .semibold))
                    .foregroundStyle(sh.textSecondary)
            }
            .padding(.horizontal, SH.Space.l)
            .frame(minHeight: SH.Height.controlL + SH.Space.xs)
            .background(sh.bgRaised, in: Capsule())
            .overlay(Capsule().strokeBorder(sh.lineStrong))
            .frame(minHeight: SH.Height.touch)
            .contentShape(Rectangle())
        }
        .disabled(store.repos.isEmpty)
        .accessibilityLabel("Repository")
        .accessibilityValue(store.allRepos ? "All repositories" : store.repo?.repo.nameWithOwner ?? "none")
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

/// Activity's quiet line ("agent pushed 1 commit  12m").
struct ForgeActivityLine: View {
    let actor: String
    let text: String
    let age: String

    var body: some View {
        let sh = Color.sh
        HStack(spacing: SH.Space.m) {
            Image(systemName: "circle.and.line.horizontal")
                .font(.sh(.caption))
                .foregroundStyle(sh.textTertiary)
                .accessibilityHidden(true)
            (Text(actor).font(.sh(.ui, weight: .semibold)).foregroundStyle(sh.textPrimary)
                + Text(" " + text).font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textSecondary))
                .lineLimit(2)
            Spacer(minLength: SH.Space.m)
            Text(age).font(.sh(.caption)).foregroundStyle(sh.textTertiary)
        }
        .padding(.horizontal, SH.Space.l)
        .frame(maxWidth: .infinity, minHeight: SH.Height.touch, alignment: .leading)
        .shCard(radius: MobileLayout.cardRadius)
        .accessibilityElement(children: .combine)
    }
}

/// A comment card (MobilePRDetail, MobileIssue): the author's initial and name, its age, the
/// line it is on, the text. GitHub's text, shown as plain text.
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
        VStack(alignment: .leading, spacing: SH.Space.m) {
            HStack(spacing: SH.Space.m) {
                Text(author.prefix(1).uppercased())
                    .font(.sh(.micro))
                    .foregroundStyle(sh.textSecondary)
                    .frame(width: MobileLayout.forgeAvatar, height: MobileLayout.forgeAvatar)
                    .background(sh.bgSelected, in: Circle())
                    .accessibilityHidden(true)
                Text(author).font(.sh(.ui, weight: .semibold)).foregroundStyle(sh.textPrimary)
                Spacer(minLength: SH.Space.m)
                Text(age).font(.sh(.caption)).foregroundStyle(sh.textTertiary)
            }
            if let location {
                Text(location).font(.sh(.mono)).foregroundStyle(sh.textTertiary).lineLimit(1).truncationMode(.head)
            }
            Text(body_)
                .font(.sh(.body))
                .foregroundStyle(sh.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(SH.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .shCard(radius: MobileLayout.cardRadius)
        .accessibilityElement(children: .combine)
    }
}

/// Activity, oldest first.
struct ForgeActivityList: View {
    let items: [ForgeActivityItem]

    var body: some View {
        ForEach(items) { item in
            VStack(spacing: 0) {
                switch item.kind {
                case .line(let actor, let text): ForgeActivityLine(actor: actor, text: text, age: item.age)
                case .comment(let author, let location, let body): ForgeCommentCard(author: author, location: location, body: body, age: item.age)
                }
            }
        }
    }
}

/// A small caps-less section head inside a page ("Activity", "Comments").
struct ForgeSectionHead: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.sh(.caption))
            .foregroundStyle(Color.sh.textTertiary)
            .padding(.horizontal, SH.Space.xs)
            .padding(.top, SH.Space.xs)
            .accessibilityAddTraits(.isHeader)
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
