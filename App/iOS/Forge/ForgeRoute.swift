import SwiftUI
import ShepherdUI
import ShepherdProtocol

/// Issues & PRs' screens (MobileIPList, MobileIssueList, MobilePRDetail, MobileIssue; iPadIPReview,
/// iPadIssue; DuoBookPR, DuoClosedIPList). iPhone pushes the list from Home and each item over it;
/// iPad pushes the list over the detail and shows the chosen item beside it.
enum ForgeRoute: Hashable, Codable {
    /// Every host's repositories, one at a time: Issues | Pull requests, search, sections.
    case list
    /// One pull request (iPhone; the iPad shows it beside the list).
    case pullRequest(host: UUID, ref: ForgeItemRef)
    /// One issue (iPhone; the iPad shows it beside the list).
    case issue(host: UUID, ref: ForgeItemRef)
    /// One file of a pull request's diff (iPhone; the iPad shows it beside the pull request).
    case file(host: UUID, ref: ForgeItemRef, path: String)

    var host: UUID? {
        switch self {
        case .list: nil
        case .pullRequest(let host, _), .issue(let host, _), .file(let host, _, _): host
        }
    }
}

struct ForgeDestination: View {
    let route: ForgeRoute

    var body: some View {
        switch route {
        case .list: ForgeListScreen()
        case .pullRequest(let host, let ref): ForgePullRequestScreen(key: ForgeItemKey(host: host, ref: ref))
        case .issue(let host, let ref): ForgeIssueScreen(key: ForgeItemKey(host: host, ref: ref))
        case .file(let host, let ref, let path): ForgeDiffScreen(key: ForgeItemKey(host: host, ref: ref), path: path)
        }
    }
}

/// How other screens reach Issues & PRs.
@MainActor
enum ForgeHooks {
    /// Opens one item: pushed on iPhone; on iPad the list opens with it chosen.
    static func open(_ key: ForgeItemKey, store: ForgeStore, navigator: MobileNavigator) {
        switch navigator.layout {
        case .phone:
            navigator.open(.forge(key.ref.kind == .pullRequest ? .pullRequest(host: key.host, ref: key.ref) : .issue(host: key.host, ref: key.ref)))
        case .pad:
            store.choose(key)
            store.reveal = key
            if navigator.padPath.last != .forge(.list) { navigator.open(.forge(.list)) }
        }
    }
}

extension MobileNavigator {
    /// Issues & PRs takes the whole window on iPad: half open, its list and item meet at the fold
    /// (DuoBookPR); or a pull request shows beside its diff (iPadPRChanges).
    var padShowsForgeWide: Bool {
        guard layout == .pad, padPath.last == .forge(.list) else { return false }
        return padFolded || padForgeDiff
    }
}

extension MobileRoute {
    /// Issues & PRs' screens, for the sidebar's row.
    var isForge: Bool {
        if case .forge = self { return true }
        return false
    }
}

extension MobileLayout {
    /// The iPad list beside an item (iPadIPReview).
    static let forgeListWidth: CGFloat = 340
    /// A pull request beside its diff (iPadPRChanges).
    static let forgeDetailBesideDiffWidth: CGFloat = 420
    /// The detail's readable measure on iPad.
    static let forgeDetailMaxWidth: CGFloat = 640
    /// The review and comment sheets' text box before it grows.
    static let forgeEditorMinHeight: CGFloat = 120
    /// An item's title (the boards' 22pt semibold).
    static let forgeItemTitle: CGFloat = 22
    /// A review or merge sheet's share of the screen, the page showing above it.
    static let forgeSheetFraction: CGFloat = 0.68
    /// The merge sheet's, taller for its banner and three switches (MobilePRMerge).
    static let forgeMergeSheetFraction: CGFloat = 0.78
    /// An Activity comment's author initial.
    static let forgeAvatar: CGFloat = 24
}

/// The glyphs Issues & PRs draws in more than one place (the iPad sidebar row, its pins, Home's
/// row, the empty list). Kept here rather than in `SHGlyph`, whose registry would flag the same
/// symbol's existing uses elsewhere.
enum ForgeGlyph {
    static let pullRequest = "arrow.triangle.pull"
    static let issue = "smallcircle.filled.circle"
}
