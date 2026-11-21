import Foundation
import Observation
import ShepherdCore
import ShepherdProtocol

/// What the iPhone and iPad's Settings ▸ Spaces ▸ Organize draws and sends for a host's spaces (`spaces.lifecycle.v1`): the order the
/// host keeps them in, and the rules of renaming, moving and removing one. The words are the Mac's own (Remove Space…).
public enum SpaceLifecyclePresentation {
    /// The spaces the host shows a device, in the order it keeps them (the Mac's sidebar order). Never a reserved space.
    public static func spaces(in state: ShepherdState) -> [Space] { state.spaces.filter { !$0.hidden } }

    /// The name to send for `text`: trimmed, or nil when it is empty or already `current`'s.
    public static func renamed(_ text: String, from current: String) -> String? {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == current ? nil : name
    }

    /// One place up: before the space above it. Nil for the first.
    public static func moveUp(_ id: SpaceID, in spaces: [Space]) -> RemoteSpaceLifecycle? {
        guard let index = spaces.firstIndex(where: { $0.id == id }), index > 0 else { return nil }
        return .move(before: spaces[index - 1].id)
    }

    /// One place down: before the space two below it, or last. Nil for the last.
    public static func moveDown(_ id: SpaceID, in spaces: [Space]) -> RemoteSpaceLifecycle? {
        guard let index = spaces.firstIndex(where: { $0.id == id }), index < spaces.count - 1 else { return nil }
        return .move(before: index + 2 < spaces.count ? spaces[index + 2].id : nil)
    }

    /// Hide from the sidebar, or bring it back.
    public static func toggleTitle(of space: Space) -> String { space.sidebarHidden ? "Show in Sidebar" : "Hide from Sidebar" }

    /// How many threads removing the space stops (the Mac counts the same).
    public static func threads(in state: ShepherdState, of space: Space) -> Int { state.agents.count { $0.spaceID == space.id } }

    public static let removeTitle = "Remove space"
    public static let removeButton = "Remove space"

    /// Remove Space…'s sentence on the Mac (`SpaceDeleteDialog`).
    public static func removeMessage(name: String, threads: Int) -> String {
        "Removes \(name) from the sidebar and stops its \(threads) agent\(threads == 1 ? "" : "s"). "
            + "The local folder and all its files are kept. Saved conversations and space history remain. Child spaces stay registered."
    }

    /// A refusal as words: the host's own, with what a space gone from under the person means.
    public static func problem(_ error: Error) -> String {
        if case RemoteHostClientError.rejected("no_such_space", _) = error { return "That space is no longer on this host." }
        return settingsProblem(error)
    }
}

/// A space on one host. Hosts of a fleet share space IDs, so the ID alone does not say which Mac an action is for.
public struct SpaceLifecycleTarget: Equatable, Sendable {
    public var host: UUID
    public var space: SpaceID

    public init(host: UUID, space: SpaceID) {
        self.host = host
        self.space = space
    }
}

/// The Rename and Remove Space… dialogs of Organize, each bound to the host that opened it. They end when Organize shows another host, and
/// answer only through the host that asked: an answer to Rename or Remove on one Mac never reaches another with the same space ID.
@MainActor
@Observable
public final class SpaceLifecycleDialogs {
    public struct Rename: Equatable, Sendable {
        public var target: SpaceLifecycleTarget
        public var name: String

        public init(target: SpaceLifecycleTarget, name: String) {
            self.target = target
            self.name = name
        }
    }

    /// The space being renamed with the name typed so far.
    public var rename: Rename?
    /// The space waiting on Remove Space…'s answer.
    public var removal: SpaceLifecycleTarget?

    public init() {}

    /// Organize shows `host` now: a dialog opened for any other host is over.
    public func keep(for host: UUID?) {
        if rename?.target.host != host { rename = nil }
        if removal?.host != host { removal = nil }
    }

    /// Organize shows the first of `hosts` it would show: as `keep(for:)`, for when the hosts change (one forgotten, one gone).
    public func keep(shownIn hosts: [SettingsHost]) {
        keep(for: SettingsHost.shown(in: hosts)?.id)
    }

    /// The target of Remove Space… to send, when `presented` is still the pending confirmation and on the host Organize shows. The store is
    /// shared by every window, so a confirmation another Mac replaced, or a host since changed, answers nothing.
    public func confirmRemoval(_ presented: SpaceLifecycleTarget, shown host: UUID?) -> SpaceLifecycleTarget? {
        removal == presented && presented.host == host ? presented : nil
    }

    /// The rename to send, on the same terms, with the name typed so far.
    public func confirmRename(_ presented: SpaceLifecycleTarget, shown host: UUID?) -> Rename? {
        guard let rename, rename.target == presented, presented.host == host else { return nil }
        return rename
    }

    /// Typing in the Rename dialog `presented` opened: written only while it is still the pending one, so a stale dialog never edits another's draft.
    public func type(_ name: String, into presented: SpaceLifecycleTarget) {
        if rename?.target == presented { rename?.name = name }
    }

    /// The Rename dialog `presented` closed: ends only that one, never another host's that has since replaced it.
    public func dismissRename(_ presented: SpaceLifecycleTarget) {
        if rename?.target == presented { rename = nil }
    }

    /// The same for Remove Space….
    public func dismissRemoval(_ presented: SpaceLifecycleTarget) {
        if removal == presented { removal = nil }
    }

    /// What Organize installs on the Rename or Remove dialog it presents for `presented`. Every callback acts on that target only and
    /// re-checks it against the pending confirmation and the host shown when it fires, so a stale dialog never touches another's
    /// draft or confirmation and never sends. `name` is the space's current name, for Rename.
    public struct Callbacks {
        public let type: (String) -> Void
        public let dismissRename: () -> Void
        public let dismissRemoval: () -> Void
        public let rename: () -> Void
        public let remove: () -> Void
    }

    public func callbacks(for presented: SpaceLifecycleTarget, name: String?, shown: @escaping () -> UUID?,
                          send: @escaping (RemoteSpaceLifecycle, SpaceLifecycleTarget) -> Void) -> Callbacks {
        Callbacks(
            type: { [self] in type($0, into: presented) },
            dismissRename: { [self] in dismissRename(presented) },
            dismissRemoval: { [self] in dismissRemoval(presented) },
            rename: { [self] in
                if let rename = confirmRename(presented, shown: shown()), let name,
                   let new = SpaceLifecyclePresentation.renamed(rename.name, from: name) {
                    send(.rename(name: new), rename.target)
                }
            },
            remove: { [self] in
                if let target = confirmRemoval(presented, shown: shown()) { send(.remove, target) }
            })
    }

    /// The host `target` is on, whatever Organize shows now; nil once the device no longer holds it. Its `client` is nil while it is offline.
    public static func host(of target: SpaceLifecycleTarget, in hosts: [SettingsHost]) -> SettingsHost? {
        hosts.first { $0.id == target.host }
    }
}
