import SwiftUI
import ShepherdCore
import ShepherdSessions
import ShepherdRemote

enum DirectoryCompletion {
    static func component(for query: String, matches: [String]) -> String {
        guard let first = matches.first else { return query }
        guard matches.count > 1 else { return first }

        let candidates = matches.map { Array($0.lowercased()) }
        let sharedCount = (0..<(candidates.map(\.count).min() ?? 0)).prefix { index in
            candidates.dropFirst().allSatisfy { $0[index] == candidates[0][index] }
        }.count
        let sharedPrefix = String(first.prefix(sharedCount))
        return sharedPrefix.count > query.count ? sharedPrefix : query
    }
}

/// The same directory listing the host serves remotely, for this Mac — so
/// local and remote space pickers are one UI with two listing sources.
enum LocalDirectoryLister {
    static func list(path: String) throws -> RemoteHostClient.DirListing {
        let fm = FileManager.default
        let resolved = path.isEmpty
            ? fm.homeDirectoryForCurrentUser.path
            : (path as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: resolved, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw RemoteHostClientError.rejected(code: "no_such_directory", message: "\(resolved) is not a directory")
        }
        let names = ((try? fm.contentsOfDirectory(atPath: resolved)) ?? [])
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .filter { name in
                var sub: ObjCBool = false
                let full = (resolved as NSString).appendingPathComponent(name)
                return fm.fileExists(atPath: full, isDirectory: &sub) && sub.boolValue
            }
        let parent = resolved == "/" ? nil : (resolved as NSString).deletingLastPathComponent
        return RemoteHostClient.DirListing(path: resolved, parent: parent, dirs: names)
    }
}

/// Directory browser used by every space/cwd picker — local and remote. The
/// listing source is a closure, so the same UI browses this Mac or a host
/// over the wire. Editable path field (⏎ jumps), hidden-dirs toggle,
/// click to descend, `..` to go up.
struct RemoteDirectoryPicker: View {
    var title = "Choose Directory"
    var actionTitle = "Choose"
    let hostName: String
    /// Where browsing begins; empty = the machine's home directory. A cwd
    /// picker starts at the current value, not home.
    var startPath: String = ""
    /// Fetch a listing: empty path = the host's home directory.
    let list: (String) async throws -> RemoteHostClient.DirListing
    let choose: (String) -> Void
    let cancel: () -> Void

    @State private var path = ""
    @State private var parent: String?
    @State private var dirs: [String] = []
    @State private var loading = true
    @State private var errorText: String?
    @State private var showHidden = false
    /// Editable path field: typing filters the listing live; ⏎ chooses.
    @State private var pathDraft = ""
    /// Partial last path component typed so far, used as a listing filter.
    @State private var filter = ""
    @FocusState private var pathFocused: Bool

    /// Hidden dirs shown only on request (or when the typed filter asks for
    /// them), narrowed with shell-like fuzzy matching. Prefix matches sort
    /// first, followed by subsequence matches in directory-name order.
    private var visibleDirs: [String] {
        let visible = dirs.filter { !$0.hasPrefix(".") }
        let all = (showHidden || filter.hasPrefix("."))
            ? visible + dirs.filter { $0.hasPrefix(".") }
            : visible
        guard !filter.isEmpty else { return all }
        return all
            .filter { fuzzyMatches(filter, in: $0) }
            .sorted { lhs, rhs in
                let leftPrefix = lhs.lowercased().hasPrefix(filter.lowercased())
                let rightPrefix = rhs.lowercased().hasPrefix(filter.lowercased())
                if leftPrefix != rightPrefix { return leftPrefix }
                return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(title) on \(hostName)")
                    .font(Fonts.mono(13.5, .semibold))
                    .foregroundStyle(Tokens.textPrimary)
                // The path is editable: typing filters the listing to what's
                // under the typed path, and ⏎ chooses it in one go.
                TextField("", text: $pathDraft)
                    .textFieldStyle(.plain)
                    .font(Fonts.mono(11))
                    .foregroundStyle(Tokens.textSecondary)
                    .focused($pathFocused)
                    .onChange(of: pathDraft) { draftChanged() }
                    .onSubmit { submit() }
                    .onKeyPress(.tab) {
                        completePath()
                        return .handled
                    }
            }
            .padding(EdgeInsets(top: 16, leading: 20, bottom: 10, trailing: 20))

            Rectangle().fill(Tokens.separator).frame(height: 1)

            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let parent {
                        row(label: "..", isUp: true) { load(parent) }
                    }
                    ForEach(visibleDirs, id: \.self) { name in
                        row(label: name, isUp: false) {
                            load((path as NSString).appendingPathComponent(name))
                        }
                    }
                    if !loading, visibleDirs.isEmpty {
                        Text("no subdirectories")
                            .font(Fonts.mono(10.5))
                            .foregroundStyle(Tokens.textDim)
                            .padding(12)
                    }
                }
            }
            .frame(height: 260)
            .background(Tokens.workspaceBg)

            Rectangle().fill(Tokens.separator).frame(height: 1)

            HStack(spacing: 10) {
                Text(errorText ?? (loading ? "loading…" : "\(visibleDirs.count) directories"))
                    .font(Fonts.mono(10.5))
                    .foregroundStyle(errorText == nil ? Tokens.textTertiary : Tokens.statusBlocked)
                    .lineLimit(1)
                Spacer(minLength: 12)
                Toggle("hidden", isOn: $showHidden)
                    .toggleStyle(.checkbox)
                    .font(Fonts.mono(10.5))
                    .foregroundStyle(Tokens.textTertiary)
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(actionTitle) { submit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Tokens.accentButton)
                    .disabled(path.isEmpty || loading)
            }
            .padding(EdgeInsets(top: 10, leading: 20, bottom: 16, trailing: 20))
        }
        .frame(width: 480)
        .background(Tokens.workspaceBg)
        .onAppear { load(startPath) }
    }

    private func row(label: String, isUp: Bool, action: @escaping () -> Void) -> some View {
        RemoteDirRow(label: label, isUp: isUp, action: action)
    }

    /// Live-sync the listing with the field: everything before the last "/"
    /// is the directory to list, everything after filters its entries.
    private func draftChanged() {
        let draft = pathDraft.trimmingCharacters(in: .whitespaces)
        if draft == path { filter = ""; return }  // programmatic update from load
        guard let slash = draft.lastIndex(of: "/") else {
            filter = draft
            return
        }
        let base = draft == "/" ? "/" : String(draft[..<slash])
        filter = String(draft[draft.index(after: slash)...])
        if base != path { load(base, keepDraft: true) }
    }

    /// Tab completes a unique match fully. Ambiguous matches advance only to
    /// their shared prefix, keeping every remaining option visible.
    private func completePath() {
        guard !loading, !filter.isEmpty, !visibleDirs.isEmpty else { return }
        let component = DirectoryCompletion.component(for: filter, matches: visibleDirs)
        guard component != filter else { return }
        pathDraft = (path as NSString).appendingPathComponent(component)
    }

    private func fuzzyMatches(_ query: String, in candidate: String) -> Bool {
        let candidateCharacters = Array(candidate.lowercased())
        var candidateIndex = 0
        for character in query.lowercased() {
            guard let match = candidateCharacters[candidateIndex...].firstIndex(of: character) else {
                return false
            }
            candidateIndex = match + 1
        }
        return true
    }

    /// One ⏎ chooses: an exact or unique match under the current listing, or
    /// the listed directory itself when nothing is typed after it.
    private func submit() {
        guard !path.isEmpty else { return }
        if filter.isEmpty { choose(path); return }
        let matches = visibleDirs
        if let exact = matches.first(where: { $0.lowercased() == filter.lowercased() }) ?? (matches.count == 1 ? matches[0] : nil) {
            choose((path as NSString).appendingPathComponent(exact))
        } else {
            errorText = "no matching directory"
        }
    }

    private func load(_ target: String, keepDraft: Bool = false) {
        loading = true
        errorText = nil
        Task {
            do {
                let listing = try await list(target)
                path = listing.path
                if !keepDraft {
                    pathDraft = listing.path
                    filter = ""
                }
                parent = listing.parent
                dirs = listing.dirs
                loading = false
            } catch {
                // A bogus initial path (stale cwd) falls back to home;
                // a failed jump (typo) keeps the current listing and
                // restores the draft to where you actually are.
                if path.isEmpty, !target.isEmpty {
                    load("")
                    return
                }
                errorText = "\(error)"
                pathDraft = path
                loading = false
            }
        }
    }
}

private struct RemoteDirRow: View {
    let label: String
    let isUp: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 10.5))
                .foregroundStyle(isUp ? Tokens.textDim : Tokens.textTertiary)
            Text(label)
                .font(Fonts.mono(12))
                .foregroundStyle(isUp ? Tokens.textDim : Tokens.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: Metrics.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? Tokens.rowHover : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
    }
}
