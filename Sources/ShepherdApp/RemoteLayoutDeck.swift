import AppKit
import ShepherdCore
import ShepherdRemote
import ShepherdUI
import SwiftUI

/// Which remote agents are pages of the remote deck, and which of them shows.
///
/// A page is an ordinary thread of a host that still has it, shown earlier in this window's session:
/// a design, a Project's coordinator or worker, an agent the host has not sent, and a removed
/// host never are, and draw over the deck instead (`RemoteDeckLayer`).
enum RemoteDeckPages {
    struct Plan: Equatable {
        /// In the order they were first shown.
        var pages: [RemoteAgentRef] = []
        /// The selected page, unless the host's utility tab for it is open over the deck.
        var visible: RemoteAgentRef?
    }

    static func pages(shown: [RemoteAgentRef], selected: RemoteAgentRef?, inspecting: RemoteAgentRef?,
                      states: [UUID: ShepherdState]) -> Plan {
        var workers: [UUID: Set<AgentID>] = [:]
        var plan = Plan()
        for ref in shown {
            guard let state = states[ref.hostID],
                  let agent = state.agents.first(where: { $0.id == ref.agentID }),
                  state.tabs.contains(where: { $0.id == agent.tabID }) else { continue }
            let hosted = workers[ref.hostID] ?? state.projectWorkerIDs
            workers[ref.hostID] = hosted
            if state.isSidebarThread(agent, workers: hosted) { plan.pages.append(ref) }
        }
        if let selected, selected != inspecting, plan.pages.contains(selected) { plan.visible = selected }
        return plan
    }
}

/// What one page of the remote deck draws, and whether it is the one on screen.
struct RemotePageModel: Equatable {
    let ref: RemoteAgentRef
    let isVisible: Bool
    let presentation: RemotePresentation
}

/// The remote threads of the workspace column: the deck of their pages, and the remote pane drawn
/// over it for whatever is no page (a design, a host's utility tab, a Project's worker).
///
/// It reads what the pages draw, so a host's push reruns this layer and nothing above it.
struct RemoteDeckLayer: View {
    var vm: ShepherdViewModel

    var body: some View {
        let selected = vm.selectedRemoteAgent
        let shown = vm.remoteDeckRefs
        if selected == nil, shown.isEmpty {
            EmptyView()
        } else {
            let resolver = RemoteLayoutModel.Resolver(vm: vm)
            let plan = RemoteDeckPages.pages(shown: shown, selected: selected, inspecting: vm.remoteInspectingAgent,
                                             states: resolver.states(of: shown))
            let models = plan.pages.compactMap { ref -> RemotePageModel? in
                let isVisible = ref == plan.visible
                return resolver.presentation(for: ref, isVisible: isVisible, page: true)
                    .map { RemotePageModel(ref: ref, isVisible: isVisible, presentation: $0) }
            }
            ZStack {
                if !models.isEmpty {
                    RemoteLayoutDeck(vm: vm, models: models)
                        .equatable()
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                }
                if let selected, plan.visible != selected {
                    RemoteAgentPane(vm: vm, ref: selected)
                        .id(selected)
                }
            }
        }
    }
}

/// Every mounted remote thread, each in a hosting view of its own, keyed by agent: the remote
/// counterpart of `AgentLayoutDeck`. A page mounts the first time it is shown in this deck and stays
/// while its host has the agent; a hidden page is an `isHidden` AppKit view that keeps its rows,
/// its scroll place and its draft, and suspends: its thread stops polling, its inspector stops
/// following and its terminals detach (`RemoteLayoutModel.isVisible`). Switching threads flips two
/// hosts' `isHidden`, never a remount.
struct RemoteLayoutDeck: View, Equatable {
    var vm: ShepherdViewModel
    /// Every page's values, in the order the pages were first shown.
    let models: [RemotePageModel]

    static func == (a: RemoteLayoutDeck, b: RemoteLayoutDeck) -> Bool {
        a.vm === b.vm && a.models == b.models
    }

    var body: some View {
        Deck(vm: vm, models: models)
    }

    /// One page's values, observed by its own hosting view alone.
    @MainActor @Observable final class Page {
        var model: RemotePageModel
        @ObservationIgnored let vm: ShepherdViewModel

        init(vm: ShepherdViewModel, model: RemotePageModel) {
            self.vm = vm
            self.model = model
        }
    }

    struct PageRoot: View {
        let page: Page

        var body: some View {
            let model = page.model
            RemoteAgentPaneContent(vm: page.vm, presentation: model.presentation)
                .equatable()
                // Nor draw its spinners and glows where no one sees them.
                .environment(\.shMotionPaused, !model.isVisible)
        }
    }

    typealias Host = DeckHost<PageRoot>

    final class Container: NSView {
        var pages: [RemoteAgentRef: (page: Page, host: Host)] = [:]
        override var isFlipped: Bool { true }

        /// The page on screen takes the bounds; a hidden one keeps its frame, except that one
        /// that has none takes the bounds once, so its first layout has a usable size.
        override func layout() {
            super.layout()
            for (_, entry) in pages where entry.page.model.isVisible || entry.host.frame.isEmpty {
                if entry.host.frame != bounds { entry.host.frame = bounds }
            }
        }

        /// The container takes no click of its own: what lands on no page goes to the layer beneath.
        override func hitTest(_ point: NSPoint) -> NSView? {
            let hit = super.hitTest(point)
            return hit === self ? nil : hit
        }

        /// The page on screen alone: VoiceOver never reaches a hidden one.
        override func accessibilityChildren() -> [Any]? {
            pages.values.filter { !$0.host.isHidden }.map(\.host)
        }
    }

    struct Deck: NSViewRepresentable {
        var vm: ShepherdViewModel
        let models: [RemotePageModel]

        func makeNSView(context: Context) -> Container { Container() }

        func updateNSView(_ container: Container, context: Context) {
            SHRenderProbe.tick("remoteDeck.update")
            var listed = Set<RemoteAgentRef>()
            var hiding: [Host] = []
            for model in models {
                listed.insert(model.ref)
                if let entry = container.pages[model.ref] {
                    if entry.page.model != model {
                        withTransaction(context.transaction) { entry.page.model = model }
                    }
                    if model.isVisible, entry.host.isHidden {
                        // The container first, then catch up before showing the page.
                        container.isHidden = false
                        if entry.host.frame != container.bounds { entry.host.frame = container.bounds }
                        entry.host.needsLayout = true
                        entry.host.isHidden = false
                        container.needsLayout = true
                    } else if !model.isVisible, !entry.host.isHidden {
                        hiding.append(entry.host)
                        container.needsLayout = true
                    }
                } else if model.isVisible {
                    // Only the page being shown mounts: a deck new to the session (a window
                    // reopened) never builds the pages shown before it, hidden.
                    container.isHidden = false
                    let page = Page(vm: vm, model: model)
                    let host = Host(rootView: PageRoot(page: page))
                    host.probe = .remote
                    host.frame = container.bounds
                    container.addSubview(host)
                    container.pages[model.ref] = (page, host)
                    container.needsLayout = true
                    SHRenderProbe.tick("remoteDeck.mount")
                    AppSignposts.thread.emitEvent("remote layout mounted")
                }
            }
            // After the page shown instead is in place.
            for host in hiding { hideDeckHost(host, in: container) }
            for (ref, entry) in container.pages where !listed.contains(ref) {
                entry.host.removeFromSuperview()
                container.pages[ref] = nil
                SHRenderProbe.tick("remoteDeck.unmount")
            }
            // With no page on screen the container takes no part in hit-testing or drawing.
            let shown = container.pages.values.contains { !$0.host.isHidden }
            if container.isHidden == shown { container.isHidden = !shown }
        }

        func sizeThatFits(_ proposal: ProposedViewSize, nsView: Container, context: Context) -> CGSize? {
            proposal.replacingUnspecifiedDimensions()
        }
    }
}
