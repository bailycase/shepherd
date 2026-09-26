import SwiftUI
import ShepherdUI
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

/// What the directory picker lists for a typed filter.
enum DirectoryFilter {
    /// Hidden dirs shown only on request (or when the typed filter asks for them), narrowed
    /// with shell-like fuzzy matching. Prefix matches sort first, followed by subsequence
    /// matches in directory-name order.
    static func visible(_ dirs: [String], filter: String, showHidden: Bool) -> [String] {
        let shown = dirs.filter { !$0.hasPrefix(".") }
        let all = (showHidden || filter.hasPrefix("."))
            ? shown + dirs.filter { $0.hasPrefix(".") }
            : shown
        guard !filter.isEmpty else { return all }
        let query = filter.lowercased()
        // Each name lowercased once, not once per comparison.
        return all
            .map { (name: $0, lowered: $0.lowercased()) }
            .filter { fuzzyMatches(query, in: $0.lowered) }
            .map { (name: $0.name, prefix: $0.lowered.hasPrefix(query)) }
            .sorted { lhs, rhs in
                if lhs.prefix != rhs.prefix { return lhs.prefix }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            .map(\.name)
    }

    /// `query`'s characters appear in `candidate` in order (both already lowercased).
    static func fuzzyMatches(_ query: String, in candidate: String) -> Bool {
        var remaining = candidate[...]
        for character in query {
            guard let match = remaining.firstIndex(of: character) else { return false }
            remaining = remaining[remaining.index(after: match)...]
        }
        return true
    }
}

/// The same directory listing the host serves remotely, for this Mac — so
/// local and remote space pickers are one UI with two listing sources.
enum LocalDirectoryLister {
    /// Lists off the main thread: a slow or network volume must not stall the sheet.
    static func load(path: String) async throws -> RemoteHostClient.DirListing {
        try await Task.detached(priority: .userInitiated) { try list(path: path) }.value
    }

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
    var title = "Choose directory"
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
    @State private var loadRequest = UUID()
    @FocusState private var pathFocused: Bool

    /// What the listing shows, apart from the typed filter.
    private struct Listing: Hashable {
        let path: String
        let showHidden: Bool
    }

    /// The listing as shown, derived when the directories, the typed filter, or the hidden
    /// toggle change, never per render: a big folder is thousands of names to filter and sort.
    @State private var visibleDirs: [String] = []

    var body: some View {
        let visible = visibleDirs
        NWDialog("\(title) on \(hostName)", width: AppLayout.directoryPickerWidth) {
            // The path is editable: typing filters the listing to what's
            // under the typed path, and ⏎ chooses it in one go.
            TextField("Path", text: $pathDraft)
                .focused($pathFocused)
                .nwField(focused: pathFocused, mono: true)
                .onChange(of: pathDraft) { draftChanged() }
                .onSubmit { submit() }
                .onKeyPress(.tab) {
                    completePath()
                    return .handled
                }
                .padding(.horizontal, NWDialogMetrics.inset)
                .padding(.bottom, NW.Space.l)

            NWHairline()
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let parent {
                        RemoteDirRow(label: "..", isUp: true) { load(parent) }
                    }
                    ForEach(visible, id: \.self) { name in
                        RemoteDirRow(label: name, isUp: false) {
                            load((path as NSString).appendingPathComponent(name))
                        }
                    }
                    // The host's first listing is on its way: placeholder rows, not an empty list.
                    if loading, dirs.isEmpty, parent == nil, errorText == nil {
                        NWLoadingRows()
                            .padding(.horizontal, NW.Space.m)
                    }
                    if !loading, visible.isEmpty {
                        Text("No subdirectories")
                            .font(.nw(.caption))
                            .foregroundStyle(Color.nw.textTertiary)
                            .padding(NW.Space.l)
                    }
                }
                .padding(NW.Space.s)
                // A new directory's listing (or the hidden ones) replaces the old as one
                // cross-fade, never row by row; the filter you type narrows it at once.
                .id(Listing(path: path, showHidden: showHidden))
                .nwTransition(.content)
            }
            .nwAnimation(.content, value: Listing(path: path, showHidden: showHidden))
            .frame(height: AppLayout.directoryListHeight)
            .background(Color.nw.bgSunken)
            NWHairline()
        } status: {
            NWDialogStatus(errorText ?? (loading ? "Loading…" : "\(visible.count) directories"), isError: errorText != nil)
        } actions: {
            Toggle("Show hidden", isOn: $showHidden)
                .toggleStyle(.nwSwitch)
                .font(.nw(.caption))
                .foregroundStyle(Color.nw.textSecondary)
                .padding(.trailing, NW.Space.s)
            Button("Cancel", action: cancel)
                .buttonStyle(.nw(.ghost))
                .keyboardShortcut(.cancelAction)
            Button(actionTitle) { submit() }
                .buttonStyle(.nw(.primary))
                .keyboardShortcut(.defaultAction)
                .disabled(path.isEmpty || loading)
        }
        .onAppear {
            pathFocused = true
            load(startPath)
        }
        .onChange(of: dirs) { refreshVisible() }
        .onChange(of: filter) { refreshVisible() }
        .onChange(of: showHidden) { refreshVisible() }
    }

    private func refreshVisible() {
        visibleDirs = DirectoryFilter.visible(dirs, filter: filter, showHidden: showHidden)
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
        // From the current inputs: the derived listing may not have caught up with the last key.
        let matches = DirectoryFilter.visible(dirs, filter: filter, showHidden: showHidden)
        guard !loading, !filter.isEmpty, !matches.isEmpty else { return }
        let component = DirectoryCompletion.component(for: filter, matches: matches)
        guard component != filter else { return }
        pathDraft = (path as NSString).appendingPathComponent(component)
    }

    /// One ⏎ chooses: an exact or unique match under the current listing, or
    /// the listed directory itself when nothing is typed after it.
    private func submit() {
        guard !path.isEmpty else { return }
        if filter.isEmpty { choose(path); return }
        let matches = DirectoryFilter.visible(dirs, filter: filter, showHidden: showHidden)
        if let exact = matches.first(where: { $0.lowercased() == filter.lowercased() }) ?? (matches.count == 1 ? matches[0] : nil) {
            choose((path as NSString).appendingPathComponent(exact))
        } else {
            errorText = "no matching directory"
        }
    }

    private func load(_ target: String, keepDraft: Bool = false) {
        loading = true
        errorText = nil
        let request = UUID()
        loadRequest = request
        Task {
            do {
                let listing = try await list(target)
                // Typing lists as it goes: only the newest request may land.
                guard loadRequest == request else { return }
                path = listing.path
                if !keepDraft {
                    pathDraft = listing.path
                    filter = ""
                }
                parent = listing.parent
                dirs = listing.dirs
                loading = false
            } catch {
                guard loadRequest == request else { return }
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

/// A directory in the listing: a real button, so it carries button traits and takes Space.
private struct RemoteDirRow: View {
    let label: String
    let isUp: Bool
    let action: () -> Void

    var body: some View {
        let _ = NWRenderProbe.tick("directory.row")
        Button(action: action) {
            HStack(spacing: NW.Space.m) {
                Image(systemName: isUp ? "arrow.turn.left.up" : "folder")
                    .font(.nw(.ui))
                    .foregroundStyle(isUp ? Color.nw.textTertiary : Color.nw.textSecondary)
                    .frame(width: NW.Space.xl)
                    .accessibilityHidden(true)
                Text(label)
                    .font(.nw(.ui))
                    .foregroundStyle(isUp ? Color.nw.textSecondary : Color.nw.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, NW.Space.m)
            .frame(minHeight: NW.Height.row)
            .contentShape(Rectangle())
        }
        .buttonStyle(.nwRow())
        .accessibilityLabel(isUp ? "Parent directory" : label)
    }
}
