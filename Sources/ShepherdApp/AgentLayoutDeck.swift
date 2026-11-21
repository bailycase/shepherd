import AppKit
import ShepherdCore
import ShepherdUI
import SwiftUI

/// Every mounted agent layout, each in a hosting view of its own.
///
/// In one view graph, every update in the visible layout (a scroll step, a keystroke, a streamed
/// reply) also walked the hidden ones, and a status report reran every layout's wrapper: each
/// hidden agent added about 0.4 M instructions to a scroll step and 1.2 M to a status report.
/// Here an update inside a layout runs that layout's graph alone, the deck itself updates only
/// when a layout's values change, and a hidden layout is an `isHidden` AppKit view: it keeps its
/// graph, its state and its surfaces, and takes no part in drawing, hit-testing, key equivalents
/// or accessibility. Switching agents flips two hosts' `isHidden`, never a remount.
struct AgentLayoutDeck: View, Equatable {
    private let vm: ShepherdViewModel?
    /// Every mounted layout's values, in the stable (space, tab) order.
    let models: [AgentLayoutModel]
    /// Hidden terminal layouts keep this size until a live resize or wide side pane ends.
    let frozenSize: CGSize?

    init(vm: ShepherdViewModel, models: [AgentLayoutModel], frozenSize: CGSize?) {
        self.vm = vm
        self.models = models
        self.frozenSize = frozenSize
    }

    #if DEBUG
    init(scrollFixtureModels: [AgentLayoutModel]) {
        vm = nil
        models = scrollFixtureModels
        frozenSize = nil
    }
    #endif

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
        @ObservationIgnored let vm: ShepherdViewModel?

        init(vm: ShepherdViewModel?, model: AgentLayoutModel) {
            self.vm = vm
            self.model = model
        }
    }

    struct PageRoot: View {
        let page: Page

        var body: some View {
            let model = page.model
            content(model)
                // Nor draw its spinners and glows where no one sees them.
                .environment(\.shMotionPaused, !model.isVisible)
                // Nor take the window's drag: a hidden thread lays out nothing for it, so its two changes (the start and the end) would
                // only rebuild its rows (`ThreadView.eagerCount`).
                .transformEnvironment(\.liveResizing) { if !model.isVisible { $0 = false } }
                // Nor run a spring there: a hidden layout is laid out again on every frame of one (the
                // composer's ring letting go of focus as the layout is hidden), for no one.
                .transaction { if !model.isVisible { $0.disablesAnimations = true } }
        }

        @ViewBuilder private func content(_ model: AgentLayoutModel) -> some View {
            if let vm = page.vm {
                AgentLayoutView(vm: vm, model: model).equatable()
            } else {
                #if DEBUG
                if let fixturePage = MacScrollValidationTrace.current?.deckPage { fixturePage(model) }
                #endif
            }
        }
    }

    typealias Host = DeckHost<PageRoot>

    /// Hidden thread-only layouts retain their size until reveal. Hidden terminal layouts
    /// take the final column size after a resize so their PTY grid stays correct.
    final class Container: NSView {
        var pages: [TabID: (page: Page, host: Host)] = [:]
        var frozenSize: CGSize? {
            didSet { if frozenSize != oldValue { needsLayout = true } }
        }
        override var isFlipped: Bool { true }

        override func layout() {
            super.layout()
            for (_, entry) in pages {
                let model = entry.page.model
                if model.isVisible || entry.host.frame.isEmpty {
                    if entry.host.frame != bounds { entry.host.frame = bounds }
                } else if model.tab.layout.leaves.contains(where: { $0.isReview != true && $0.id != model.thread?.paneID }) {
                    let frame = CGRect(origin: .zero, size: frozenSize ?? bounds.size)
                    if entry.host.frame != frame {
                        entry.host.frame = frame
                        entry.host.needsLayout = true
                    }
                }
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let hit = super.hitTest(point)
            return hit === self ? nil : hit
        }

        /// The drag over, the hidden layouts that held their passes back take them, one at a time (`DeckCatchUp`).
        override func viewDidEndLiveResize() {
            super.viewDidEndLiveResize()
            DeckCatchUp.run(pages.values.map(\.host)) { [weak self] in self?.window?.inLiveResize == true }
        }

        /// The visible layout alone: VoiceOver never reaches a hidden one.
        override func accessibilityChildren() -> [Any]? {
            pages.values.filter { !$0.host.isHidden }.map(\.host)
        }
    }

    struct Deck: NSViewRepresentable {
        let vm: ShepherdViewModel?
        let models: [AgentLayoutModel]
        let frozenSize: CGSize?

        func makeNSView(context: Context) -> Container { Container() }

        func updateNSView(_ container: Container, context: Context) {
            SHRenderProbe.tick("deck.update")
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
                        // Catch up before showing, without resizing any other hidden layout.
                        if entry.host.frame != container.bounds { entry.host.frame = container.bounds }
                        entry.host.needsLayout = true
                        entry.host.isHidden = false
                        // A thread whose rows were let go (`NativeThreadStores`) builds them in this pass, not a later one: left
                        // to a later pass, the running app committed a frame with the layout and an empty transcript for as
                        // long as the rows took to build. A layout that kept its rows has none to build and takes its usual pass.
                        if let thread = model.thread, vm?.threadStores.existing(for: thread.agentID)?.transcriptReleased == true {
                            entry.host.layoutSubtreeIfNeeded()
                            SHRenderProbe.tick("deck.flipLayout")
                        }
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
                    SHRenderProbe.tick("deck.mount")
                    AppSignposts.thread.emitEvent("layout mounted")
                }
            }
            // After the layout shown instead is in place.
            for host in hiding { hideDeckHost(host, in: container) }
            for (id, entry) in container.pages where !mounted.contains(id) {
                entry.host.removeFromSuperview()
                container.pages[id] = nil
                SHRenderProbe.tick("deck.unmount")
            }
            container.frozenSize = frozenSize
        }

        func sizeThatFits(_ proposal: ProposedViewSize, nsView: Container, context: Context) -> CGSize? {
            proposal.replacingUnspecifiedDimensions()
        }
    }
}

/// The probe names a deck's hosts tick as they lay out, so a second deck's passes stay out of the
/// first one's counts.
struct DeckProbe {
    let visible: StaticString
    let hidden: StaticString
    /// A hidden layout's pass held back through a live resize.
    let held: StaticString

    static let local = DeckProbe(visible: "deck.layout", hidden: "deck.hiddenLayout", held: "deck.heldLayout")
    static let remote = DeckProbe(visible: "remoteDeck.layout", hidden: "remoteDeck.hiddenLayout", held: "remoteDeck.heldLayout")
}

/// A layout's hosting view. It sizes nothing around it, and has no safe area of its own:
/// the workspace's column decides both, as it did for the layouts in its own graph.
final class DeckHost<Root: View>: NSHostingView<Root>, DeckCatchUpHost {
    var probe = DeckProbe.local
    /// SwiftUI has laid this host out in a window at a usable size. Until it has, no pass is held back: the first one gives
    /// the layout its size.
    private var laidOut = false
    /// A live resize began while the window was shown (`viewWillStartLiveResize`), and has not ended.
    private var windowResizing = false
    /// Passes this hidden host held back through a live resize: it still owes the one that catches it up.
    var owesPass = false

    required init(rootView: Root) {
        super.init(rootView: rootView)
        sizingOptions = []
        safeAreaRegions = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Hidden, a layout holds no focus and offers none. AppKit asks every hosting view under
    /// the window whether it accepts first responder when it recomputes the hidden title
    /// bar's drag regions and the key view loop, and SwiftUI answers by walking the layout's
    /// focusable items (a transcript's every link and button): with the fleet's layouts
    /// retained, that walk was a seventh of the main thread's hang time
    /// (docs/audit/2026-11-05). A hidden layout answers at once.
    override var acceptsFirstResponder: Bool { isHidden ? false : super.acceptsFirstResponder }
    override var needsPanelToBecomeKey: Bool { isHidden ? false : super.needsPanelToBecomeKey }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        windowResizing = true
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        windowResizing = false
    }

    /// A host that leaves the window mid-drag, or is never told the drag ended, holds nothing back from then on.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowResizing = false
    }

    func liveResizeEnded() { windowResizing = false }

    /// Whether the window is being resized by hand and this layout is out of sight, so it need not follow: SwiftUI marks every hosting
    /// view of the window's graphs for an update on each frame of the drag (`NSHostingView` watches its geometry in the window), and a
    /// hidden layout's pass was most of what a frame cost with a few of them mounted. The pass it owes comes once the drag ends
    /// (`DeckCatchUp`), or when the layout is shown: showing a host (`updateNSView` sets `needsLayout` before it un-hides it) is the
    /// backstop for a container that never gets `viewDidEndLiveResize`, for a shown host holds nothing back.
    private var holdsPass: Bool {
        isHidden && laidOut && (windowResizing || window?.inLiveResize == true)
    }

    override func layout() {
        if holdsPass {
            owesPass = true
            SHRenderProbe.tick(probe.held)
            // The pass that would clear it is the one not taken.
            needsLayout = false
            return
        }
        SHRenderProbe.tick(isHidden ? probe.hidden : probe.visible)
        // Even at fixed hidden bounds, AppKit needs this pass to remove transitioned views.
        // Avoid resize work by retaining host frames, never by skipping lifecycle callbacks.
        super.layout()
        owesPass = false
        if window != nil, !bounds.isEmpty { laidOut = true }
    }
}

/// A hosting view that can hold back the passes of a hidden layout through a live resize (`DeckHost`).
@MainActor
protocol DeckCatchUpHost: NSView {
    var owesPass: Bool { get set }
    /// The drag is over for this host, whether or not AppKit told it so itself.
    func liveResizeEnded()
}

/// The passes hidden layouts held back through a live resize, taken once it ends: one layout per turn of the main run loop, so no
/// frame carries them all, and the shown one's own relayout and the thread's tail growing back (`ThreadView.returnEagerTail`) go
/// first. A drag that begins again leaves what is left for its own end.
@MainActor
enum DeckCatchUp {
    static func run(_ hosts: [any DeckCatchUpHost], resizing: @escaping @MainActor () -> Bool) {
        for host in hosts { host.liveResizeEnded() }
        let owing = hosts.filter { $0.isHidden && $0.owesPass }
        guard !owing.isEmpty else { return }
        step(owing[...], resizing: resizing)
    }

    private static func step(_ hosts: ArraySlice<any DeckCatchUpHost>, resizing: @escaping @MainActor () -> Bool) {
        DispatchQueue.main.async {
            guard let host = hosts.first, !resizing() else { return }
            if host.isHidden, host.owesPass, host.superview != nil { host.needsLayout = true }
            step(hosts.dropFirst(), resizing: resizing)
        }
    }
}

/// Hides `host`, giving up the keyboard first if it holds it, so the first responder never moves
/// to whatever AppKit picks as the next key view. The layout shown instead claims focus as it
/// always has (its focused pane, from its values).
@MainActor
func hideDeckHost(_ host: NSView, in container: NSView) {
    if let window = container.window, let responder = window.firstResponder as? NSView, responder.isDescendant(of: host) {
        window.makeFirstResponder(nil)
    }
    host.isHidden = true
}
