import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdRemote

/// New thread (MobileNewThread, DuoClosedNewThread, iPadNewThread boards): Cancel, the title and Send in the bar, then one raised
/// card holding the prompt and, under it, one row: Attach, "repo on host" and the model with its thinking level. Under the card,
/// "New worktree on shepherd · Where it runs… changes the repo, host and branch." opens Where it runs (MobileWorkspace). On iPhone
/// the repo, host and worktree choices are that sheet; on iPad the repo, host and model each open a popover from the row.
struct NewThreadScreen: View {
    let preferredHost: UUID?
    @Environment(MobileHosts.self) private var hosts
    @Environment(ThreadStores.self) private var threads
    @Environment(MobileNavigator.self) private var navigator
    @State private var model: NewThreadModel?

    var body: some View {
        Group {
            if let model {
                NewThreadForm(model: model, pad: navigator.layout == .pad)
            } else {
                Color.sh.bgWindow
            }
        }
        .background(Color.sh.bgWindow)
        .navigationTitle("New thread")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if navigator.layout == .phone {
                ToolbarItem(placement: .cancellationAction) {
                    Button { navigator.dismissPresented() } label: { Label("Cancel", systemImage: "xmark") }
                        .tint(Color.sh.textPrimary)
                }
            } else {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { navigator.dismissPresented() }
                        .tint(Color.sh.textPrimary)
                }
            }
            if let model {
                // The ink circle (the boards' `.gt-gl.pri`): a symbol with a title, so iPhone Duo's closed display stacks it in its column.
                ToolbarItem(placement: .confirmationAction) {
                    Button { model.start() } label: { Label("Send", systemImage: "arrow.up") }
                        .buttonStyle(.glassProminent)
                        .tint(Color.sh.primary)
                        .disabled(navigator.layout == .pad ? model.blocker != nil : !model.canSend)
                        .accessibilityLabel(model.starting ? "Starting thread" : navigator.layout == .pad ? "Start thread" : "Send")
                        .accessibilityHint(model.blocker?.message ?? "")
                }
                .visibilityPriority(.high)
            }
        }
        .onAppear {
            guard model == nil else { return }
            let model = NewThreadModel(hosts: hosts, threads: threads, navigator: navigator, preferredHost: preferredHost,
                                       context: navigator.selectedThread)
            self.model = model
            model.begin()
        }
    }
}

private struct NewThreadForm: View {
    @Bindable var model: NewThreadModel
    let pad: Bool
    @FocusState private var promptFocused: Bool
    /// Popovers widen with the text size, so a host's name still fits at accessibility sizes.
    @ScaledMetric(relativeTo: .body) private var popoverWidth = MobileLayout.newThreadPopoverWidth

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SH.Space.l) {
                card
                footnote
                status
            }
            .padding(.horizontal, MobileLayout.gutter)
            .padding(.top, SH.Space.m)
            .padding(.bottom, SH.Space.xl)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.sh.bgWindow)
        .onAppear { promptFocused = true }
        // A picker needs the room the keyboard takes, most of all an iPad popover.
        .onChange(of: model.panel) { _, panel in if panel != nil { promptFocused = false } }
        .sheet(isPresented: panel(.workspace)) {
            NewThreadWhereItRuns(model: model)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.sh.bgWindow)
        }
        .sheet(isPresented: pad ? .constant(false) : panel(.model)) {
            NavigationStack {
                NewThreadModelPicker(model: model, thinking: true) { model.panel = nil }
                    .navigationTitle(model.offersThinking ? "Model and thinking" : "Model")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        // A symbol, so iPhone Duo's closed display puts it in its column with the sheet's bars.
                        ToolbarItem(placement: .confirmationAction) {
                            Button { model.panel = nil } label: { Label("Done", systemImage: "checkmark") }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(Color.sh.bgWindow)
        }
        .shAnimation(.disclosure, value: model.attachments.count)
        .shAnimation(.content, value: model.errorText)
    }

    private var promptField: some View {
        TextField("What should the agent do?", text: $model.prompt, axis: .vertical)
            .font(.shSans(MobileLayout.newThreadPromptSize))
            .lineSpacing(SH.Space.xs)
            .foregroundStyle(Color.sh.textPrimary)
            .focused($promptFocused)
            .accessibilityLabel("Prompt")
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The raised card (the boards' `.gt-field`): images waiting to go, the prompt (a tap anywhere above the row types), the row.
    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: SH.Radius.xxl)
        return VStack(alignment: .leading, spacing: 0) {
            if !model.attachments.isEmpty { NewThreadAttachmentStrip(model: model) }
            promptField
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .contentShape(Rectangle())
                .onTapGesture { promptFocused = true }
            row.padding(.top, SH.Space.l)
        }
        .padding(EdgeInsets(top: SH.Space.xl, leading: SH.Space.xl, bottom: SH.Space.m, trailing: SH.Space.xl))
        .frame(maxWidth: .infinity, minHeight: MobileLayout.newThreadCardHeight, alignment: .topLeading)
        .shBorder(Color.sh.lineSubtle, radius: SH.Radius.xxl)
        .shLift(shape)
    }

    /// Attach, the repo on its host, and the model: one line that never wraps, the host's name giving way first.
    private var row: some View {
        HStack(spacing: SH.Space.s) {
            NewThreadAttachButton(model: model)
            workplace
            Spacer(minLength: SH.Space.s)
            modelChip
        }
        .padding(.horizontal, -SH.Space.m)
        .frame(minHeight: SH.Height.touch)
        .disabled(model.starting)
        .buttonStyle(.plain)
    }

    /// "shepherd on Studio ⌄". On iPhone one button opens Where it runs; on iPad the repo and the host each open a popover.
    @ViewBuilder private var workplace: some View {
        let repo = model.repoName ?? "Choose repo"
        let host = model.host?.name ?? "Choose host"
        HStack(spacing: SH.Space.xs) {
            Button { open(pad ? .repo : .workspace) } label: {
                HStack(spacing: SH.Space.s) {
                    Image(systemName: SHGlyph.repository.symbolName).font(.sh(.ui, weight: .regular)).accessibilityHidden(true)
                    Text(repo).fontWeight(.medium).foregroundStyle(Color.sh.textPrimary).lineLimit(1).truncationMode(.middle)
                }
                .frame(minHeight: SH.Height.touch)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Repo, \(repo)")
            .popover(isPresented: pad ? panel(.repo) : .constant(false), arrowEdge: .top) { repoPopover }
            Button { open(pad ? .host : .workspace) } label: {
                HStack(spacing: SH.Space.xs) {
                    Text("on \(host)").lineLimit(1).truncationMode(.tail)
                    SHChipChevron()
                }
                .frame(minHeight: SH.Height.touch)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Host, \(host)")
            .popover(isPresented: pad ? panel(.host) : .constant(false), arrowEdge: .top) { hostPopover }
        }
        .font(.sh(.ui, weight: .regular))
        .foregroundStyle(Color.sh.textSecondary)
        .padding(.horizontal, SH.Space.m)
    }

    /// "claude-opus ⌄", with the thinking level after it on iPad: opens the sheet (popover on iPad) that chooses both.
    private var modelChip: some View {
        let short = NewThreadRules.shortModel(model.defaults.model)
        return Button { open(.model) } label: {
            HStack(spacing: SH.Space.xs) {
                Text(short).lineLimit(1).truncationMode(.middle)
                if pad, model.offersThinking { Text(model.thinking.title).foregroundStyle(Color.sh.textTertiary).lineLimit(1) }
                SHChipChevron()
            }
            .font(.shSans(SHTouchComposerMetrics.chipSize))
            .foregroundStyle(Color.sh.textSecondary)
            .padding(.horizontal, SH.Space.m)
            .frame(minHeight: SH.Height.touch)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(model.offersThinking ? "Model and thinking" : "Model")
        .popover(isPresented: pad ? panel(.model) : .constant(false), arrowEdge: .top) {
            popover("Model") {
                NewThreadModelPicker(model: model, thinking: true) { model.panel = nil }
                    .frame(idealHeight: MobileLayout.newThreadPopoverHeight)
            }
        }
    }

    private func open(_ panel: NewThreadModel.Panel) {
        model.workspaceAnchor = nil
        model.panel = panel
    }

    private var repoPopover: some View {
        popover("Repo") {
            NavigationStack {
                ScrollView { NewThreadRepoList(model: model, carded: false) }
                    .background(Color.sh.bgRaised)
                    .navigationTitle("Repo")
                    .navigationBarTitleDisplayMode(.inline)
                    .navigationDestination(item: $model.folders) { NewThreadFolderScreen(model: model, browser: $0) }
            }
            .frame(idealHeight: MobileLayout.newThreadPopoverHeight)
        }
    }

    private var hostPopover: some View {
        popover("Run on") {
            VStack(alignment: .leading, spacing: 0) {
                Text("Run on")
                    .font(.sh(.ui))
                    .foregroundStyle(Color.sh.textPrimary)
                    .padding(.horizontal, SH.Space.xl)
                    .frame(minHeight: MobileLayout.rowHeight)
                    .accessibilityAddTraits(.isHeader)
                SHHairline()
                // Every host where there's room (iPadNewThread); with less, they scroll under the header.
                ScrollView { NewThreadHostList(model: model, carded: false) }
                    .scrollBounceBehavior(.basedOnSize)
            }
        }
    }

    private func popover<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(width: min(popoverWidth, MobileLayout.newThreadPopoverMaxWidth))
            // Its ideal height sizes the popover. With less room under its anchor the popover is
            // shorter and the content keeps its top: the header stays, the rest scrolls.
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color.sh.bgRaised)
            .presentationCompactAdaptation(.popover)
            .presentationBackground(Color.sh.bgRaised)
            .accessibilityLabel(title)
    }

    /// "New worktree on shepherd · Where it runs… changes the repo, host and branch." (the boards' `.gt-foot`): opens the worktree's settings.
    private var footnote: some View {
        let text = NewThreadRules.worktreeSummary(repo: model.space?.name, worktree: model.usesWorktree, noSpace: model.noSpace)
        return Button {
            model.workspaceAnchor = .worktree
            model.panel = pad ? .worktree : .workspace
        } label: {
            Text("\(text) \u{00B7} Where it runs\u{2026} changes the repo, host and branch.")
                .font(.sh(.ui, weight: .regular))
                .foregroundStyle(Color.sh.textTertiary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, SH.Space.xs)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(text)
        .accessibilityHint("Changes where the thread works")
        .popover(isPresented: pad ? panel(.worktree) : .constant(false), arrowEdge: .top) {
            popover("New worktree") {
                // A stack, so the Base row pushes the branch list.
                NavigationStack(path: $model.workspacePath) {
                    ScrollView {
                        NewThreadWorktreeCard(model: model)
                            .padding(MobileLayout.gutter)
                    }
                    .background(Color.sh.bgWindow)
                    .toolbar(.hidden, for: .navigationBar)
                    .newThreadPages(model)
                }
                .frame(idealHeight: MobileLayout.newThreadPopoverHeight)
            }
        }
    }

    /// What stops Start, or the host's error. Waiting on the host reads as progress.
    @ViewBuilder
    private var status: some View {
        if let error = model.errorText {
            SHBanner(.failed, title: "Couldn't start the thread", message: error) {
                switch model.blocker {
                case .defaultsFailed:
                    Button("Try again") { model.loadDefaults() }.buttonStyle(.sh(.secondary, size: .s))
                case .baseUnresolved:
                    Button("Resolve") { model.resolveBase(fetch: nil) }.buttonStyle(.sh(.secondary, size: .s))
                default:
                    EmptyView()
                }
            }
        } else if let blocker = model.blocker, blocker != .starting || !pad {
            HStack(spacing: SH.Space.s) {
                Text(blocker.message)
                    .shText(.caption)
                    .shShimmer(active: blocker.isPending)
                    .foregroundStyle(Color.sh.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if case .defaultsFailed = blocker {
                    Button("Try again") { model.loadDefaults() }.buttonStyle(.shLink)
                } else if case .baseUnresolved = blocker {
                    Button("Resolve") { model.resolveBase(fetch: nil) }.buttonStyle(.shLink)
                }
            }
        }
    }

    private func panel(_ panel: NewThreadModel.Panel) -> Binding<Bool> {
        Binding(get: { model.panel == panel }, set: { shown in
            if shown { model.panel = panel } else if model.panel == panel { model.panel = nil }
        })
    }
}
