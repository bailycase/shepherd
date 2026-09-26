import SwiftUI
import AppKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

/// The New design page (DZStart; Designs' New design, New thread's "Start a design"): "What do
/// you want to design?", the brief in a 720pt composer with attach and Send only, and the
/// design system the boards are drawn in. Sending makes the design, starts its agent with the
/// brief, and opens its canvas.
///
/// P1 reads a design's system from its project, so the one card is the project (its menu picks
/// another); the Capture a page and From a screenshot starting points come later.
struct NewDesignPage: View {
    var vm: ShepherdViewModel
    let chrome: PageHeaderChrome
    @FocusState private var composing: Bool
    @State private var dropTargeted = false
    @State private var picking = false

    private var draft: NewDesignState { vm.newDesign }

    var body: some View {
        let _ = NWRenderProbe.tick("newDesign.page")
        VStack(spacing: 0) {
            NWDesignHeader("New design", style: .page, leadingInset: chrome.leadingInset, sidebar: chrome.showSidebar,
                           sidebarShortcut: KeybindingsStore.shared.display(.toggleSidebar),
                           designs: { vm.openDestination(.designs) })
            VStack(spacing: AppLayout.newDesignGap) {
                VStack(spacing: AppLayout.newDesignSubtitleSpacing) {
                    Text("What do you want to design?")
                        .font(.nwSans(AppLayout.newThreadHeadingSize, .semibold))
                        .tracking(AppLayout.newThreadHeadingTracking)
                        .foregroundStyle(Color.nw.textPrimary)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    Text("Describe the page or flow. The design agent draws it as HTML boards in your design system, "
                         + "and you refine it on the canvas.")
                        .font(.nw(.body))
                        .foregroundStyle(Color.nw.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: AppLayout.newDesignSubtitleWidth)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: NW.Space.m) {
                    composer
                    if let notice = draft.notice {
                        Text(notice).font(.nw(.caption)).foregroundStyle(Color.nw.failed)
                            .nwTransition(.content)
                    }
                }
                .frame(maxWidth: AppLayout.newDesignComposerWidth)
                startingPoints
                    .frame(maxWidth: AppLayout.newDesignComposerWidth)
            }
            .padding(.horizontal, AppLayout.newThreadSidePadding)
            .padding(.bottom, AppLayout.newDesignBottomExtra)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.nw.bgWindow)
        .nwAnimation(.content, value: draft.notice)
        .onChange(of: draft.focusRequest, initial: true) { composing = true }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            draft.attach(urls: urls)
        }
    }

    // MARK: Composer

    /// The composer's card, drawn focused, with attach and Send only.
    private var composer: some View {
        let blocker = draft.blocker(vm)
        return NWComposer(isFocused: true) {
            ForEach(draft.attachments.items) { attachment in
                NWAttachmentChip(attachment.name, thumbnail: attachment.thumbnail) {
                    draft.attachments.remove(attachment.id)
                }
                .nwTransition(.list, edge: .leading)
            }
        } field: {
            TextField(text: Binding(get: { draft.brief }, set: { draft.brief = $0 }),
                      prompt: Text("A checkout funnel dashboard for the product team…").foregroundStyle(Color.nw.textTertiary),
                      axis: .vertical) {
                Text("What do you want to design?")
            }
            .lineLimit(1...NWComposerMetrics.fieldMaxLines)
            .textFieldStyle(.plain)
            .font(Font.nw(.body))
            .foregroundStyle(Color.nw.textPrimary)
            .focused($composing)
            .frame(minHeight: AppLayout.newDesignFieldMinHeight, alignment: .topLeading)
            .onKeyPress(.return, phases: .down) { press in
                if press.modifiers.contains(.shift) { draft.brief += "\n"; return .handled }
                draft.send(vm)
                return .handled
            }
            .onPasteCommand(of: [.image, .fileURL]) { draft.attach($0) }
            .accessibilityLabel("What do you want to design?")
        } controls: {
            Button { picking = true } label: { Image(systemName: "paperclip") }
                .buttonStyle(.nwIcon(size: NWComposerMetrics.chipHeight))
                .disabled(draft.attachments.isFull)
                .help("Attach a screenshot or file")
                .accessibilityLabel("Attach a screenshot or file")
            Spacer(minLength: NW.Space.m)
            if draft.starting {
                ProgressView().progressViewStyle(.nwSpinner(color: Color.nw.textTertiary))
                    .frame(width: NWComposerMetrics.actionSize, height: NWComposerMetrics.actionSize)
                    .accessibilityLabel("Starting")
            } else {
                NWComposerActionButton(.send, enabled: blocker == nil) { draft.send(vm) }
                    .help(blocker ?? "Send (\(KeybindingsStore.shared.sendDisplay))")
            }
        }
        .nwAnimation(.list, value: draft.attachments.ids)
        .nwAnimation(.content, value: draft.starting)
        .onDrop(of: [.image, .fileURL], isTargeted: $dropTargeted) { providers in
            draft.attach(providers)
            return true
        }
    }

    // MARK: Starting points

    /// "DESIGN SYSTEM & STARTING POINT": the project the design is drawn in, chosen, at a third of
    /// the row. With more than one project its menu picks another.
    private var startingPoints: some View {
        VStack(alignment: .leading, spacing: AppLayout.newDesignCardsLabelGap) {
            Text("Design system & starting point").nwSectionLabel()
                .accessibilityAddTraits(.isHeader)
            GeometryReader { proxy in
                let width = (proxy.size.width - AppLayout.newDesignCardsGap * (AppLayout.newDesignCardsPerRow - 1))
                    / AppLayout.newDesignCardsPerRow
                HStack(spacing: AppLayout.newDesignCardsGap) {
                    if let space = vm.state.spaces.first(where: { $0.id == draft.space }) {
                        systemCard(space)
                            .frame(width: max(0, width))
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(height: AppLayout.newDesignCardHeight)
        }
    }

    @ViewBuilder private func systemCard(_ space: Space) -> some View {
        let card = NWDesignStartCard(symbol: "pencil.tip", title: space.name, line: "design system · \(space.name)",
                                     note: NewThreadRules.abbreviatedPath(space.path), chosen: true)
        let spaces = vm.visibleSpaces
        if spaces.count > 1 {
            Menu {
                ForEach(spaces) { option in
                    Button(option.name) { draft.choose(option.id) }
                }
            } label: { card }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .help("Draw it in another project")
        } else {
            card
        }
    }
}
