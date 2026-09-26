import AppKit
import ShepherdCore
import ShepherdUI
import SwiftUI

/// Every mounted agent layout, each in a hosting view of its own (DESIGN.md › Performance).
///
/// In one view graph, every update in the visible layout (a scroll step, a keystroke, a streamed
/// reply) also walked the hidden ones, and a status report reran every layout's wrapper: each
/// hidden agent added about 0.4 M instructions to a scroll step and 1.2 M to a status report.
/// Here an update inside a layout runs that layout's graph alone, the deck itself updates only
/// when a layout's values change, and a hidden layout is an `isHidden` AppKit view: it keeps its
/// graph, its state and its surfaces, and takes no part in drawing, hit-testing, key equivalents
/// or accessibility. Switching agents flips two hosts' `isHidden`, never a remount.
struct AgentLayoutDeck: View, Equatable {
    var vm: ShepherdViewModel
    /// Every mounted layout's values, in mount order.
    let models: [AgentLayoutModel]
    /// The column's size when a live resize began: hidden layouts keep it until the drag ends.
    let frozenSize: CGSize?

    static func == (a: AgentLayoutDeck, b: AgentLayoutDeck) -> Bool {
        a.vm === b.vm && a.models == b.models && a.frozenSize == b.frozenSize
    }

    var body: some View {
        Deck(vm: vm, models: models, frozenSize: frozenSize)
    }

    /// One layout's values, observed by its own hosting view alone: a change set here reaches
    /// that layout, in the transaction it was made in. The environment needs no hand-off: a
    /// hosting view inside a SwiftUI hierarchy inherits it, and follows its changes.
    @MainActor @Observable final class Page {
        var model: AgentLayoutModel
        @ObservationIgnored let vm: ShepherdViewModel

        init(vm: ShepherdViewModel, model: AgentLayoutModel) {
            self.vm = vm
            self.model = model
        }
    }

    struct PageRoot: View {
        let page: Page

        var body: some View {
            let model = page.model
            AgentLayoutView(vm: page.vm, model: model)
                .equatable()
                // Nor draw its spinners and glows where no one sees them.
                .environment(\.nwMotionPaused, !model.isVisible)
        }
    }

    /// A layout's hosting view. It sizes nothing around it, and has no safe area of its own:
    /// the workspace's column decides both, as it did for the layouts in its own graph.
    final class Host: NSHostingView<PageRoot> {
        required init(rootView: PageRoot) {
            super.init(rootView: rootView)
            sizingOptions = []
            safeAreaRegions = []
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func layout() {
            NWRenderProbe.tick(isHidden ? "deck.hiddenLayout" : "deck.layout")
            super.layout()
        }
    }

    /// Holds every host, the visible one sized to the column and the hidden ones to the frozen
    /// size while a live resize lasts. Transparent where no layout is shown.
    final class Container: NSView {
        var pages: [TabID: (page: Page, host: Host)] = [:]
        var frozenSize: CGSize? {
            didSet { if frozenSize != oldValue { needsLayout = true } }
        }

        override var isFlipped: Bool { true }

        override func layout() {
            super.layout()
            for (_, entry) in pages {
                let frame = entry.page.model.isVisible ? bounds : CGRect(origin: .zero, size: frozenSize ?? bounds.size)
                if entry.host.frame != frame { entry.host.frame = frame }
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let hit = super.hitTest(point)
            return hit === self ? nil : hit
        }

        /// The visible layout alone: VoiceOver never reaches a hidden one.
        override func accessibilityChildren() -> [Any]? {
            pages.values.filter { !$0.host.isHidden }.map(\.host)
        }

        /// Hides `host`, giving up the keyboard first if it holds it, so the first responder
        /// never moves to whatever AppKit picks as the next key view. The layout shown instead
        /// claims focus as it always has (its focused pane, from its values).
        func hide(_ host: Host) {
            if let window, let responder = window.firstResponder as? NSView, responder.isDescendant(of: host) {
                window.makeFirstResponder(nil)
            }
            host.isHidden = true
        }
    }

    struct Deck: NSViewRepresentable {
        var vm: ShepherdViewModel
        let models: [AgentLayoutModel]
        let frozenSize: CGSize?

        func makeNSView(context: Context) -> Container { Container() }

        func updateNSView(_ container: Container, context: Context) {
            NWRenderProbe.tick("deck.update")
            var mounted = Set<TabID>()
            var hiding: [Host] = []
            for model in models {
                let id = model.tab.id
                mounted.insert(id)
                if let entry = container.pages[id] {
                    if entry.page.model != model {
                        withTransaction(context.transaction) { entry.page.model = model }
                    }
                    if model.isVisible, entry.host.isHidden {
                        entry.host.isHidden = false
                        container.needsLayout = true
                    } else if !model.isVisible, !entry.host.isHidden {
                        hiding.append(entry.host)
                        container.needsLayout = true
                    }
                } else {
                    let page = Page(vm: vm, model: model)
                    let host = Host(rootView: PageRoot(page: page))
                    host.isHidden = !model.isVisible
                    host.frame = model.isVisible ? container.bounds : CGRect(origin: .zero, size: frozenSize ?? container.bounds.size)
                    container.addSubview(host)
                    container.pages[id] = (page, host)
                    container.needsLayout = true
                }
            }
            // After the layout shown instead is in place.
            for host in hiding { container.hide(host) }
            for (id, entry) in container.pages where !mounted.contains(id) {
                entry.host.removeFromSuperview()
                container.pages[id] = nil
            }
            container.frozenSize = frozenSize
        }

        func sizeThatFits(_ proposal: ProposedViewSize, nsView: Container, context: Context) -> CGSize? {
            proposal.replacingUnspecifiedDimensions()
        }
    }
}
