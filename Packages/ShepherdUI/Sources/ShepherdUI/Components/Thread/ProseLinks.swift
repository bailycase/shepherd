import SwiftUI

/// Where a link in prose goes. One router per prose view makes its `OpenURLAction` once, so the
/// environment below it is the same on every pull: a body that wrote a fresh action told every
/// link, image chip and task chip under it that its environment had changed. A plain class,
/// because nothing observes it; the view assigns `root` and `outer` in its body, which
/// invalidates nothing.
@MainActor final class SHProseLinkRouter {
    /// The folder a relative file link resolves against (`shProseFileRoot`).
    var root: URL?
    /// The conversation's own opener, which the link reaches once resolved.
    var outer: OpenURLAction?
    /// What `Text` links and the buttons of images and task chips call; made once, weakly bound.
    private(set) var action = OpenURLAction { _ in .discarded }

    init() {
        action = OpenURLAction { [weak self] url in self?.open(url) ?? .discarded }
    }

    @discardableResult
    func open(_ url: URL) -> OpenURLAction.Result {
        guard let destination = SHProseLink.destination(url, root: root), let outer else { return .discarded }
        outer(destination)
        return .handled
    }
}

extension EnvironmentValues {
    /// The router of the prose view this is in: a class, compared by identity.
    @Entry var shProseLinkRouter: SHProseLinkRouter? = nil
}

private struct SHProseLinks: ViewModifier {
    @State private var router = SHProseLinkRouter()
    @Environment(\.shProseFileRoot) private var root
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        let _ = router.route(root: root, to: openURL)
        content
            .environment(\.openURL, router.action)
            .environment(\.shProseLinkRouter, router)
    }
}

private extension SHProseLinkRouter {
    func route(root: URL?, to outer: OpenURLAction) {
        self.root = root
        self.outer = outer
    }
}

extension View {
    /// Resolves the links in this prose against `shProseFileRoot` and hands them to the opener the
    /// view inherits: `Text` links through `\.openURL`, image and task-chip buttons through the router.
    func shProseLinks() -> some View { modifier(SHProseLinks()) }
}
