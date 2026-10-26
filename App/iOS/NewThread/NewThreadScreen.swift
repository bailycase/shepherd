import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdRemote

/// New thread (MobileNewThread, iPadNewThread boards): the prompt, then chips for the repo,
/// host, model and thinking, Attach, where the thread works, and Start. On iPhone the repo and
/// host chips open Where it runs (MobileWorkspace); on iPad each chip opens its own popover.
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
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { navigator.dismissPresented() }
            }
            if navigator.layout == .pad, let model {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") { model.start() }
                        .fontWeight(.semibold)
                        .disabled(model.blocker != nil)
                        .accessibilityLabel("Start thread")
                }
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
        Group {
            if pad {
                // iPad board: the chips sit under the prompt, so their popovers open below them.
                ScrollView {
                    VStack(alignment: .leading, spacing: SH.Space.xl) {
                        promptField.lineLimit(MobileLayout.newThreadPadPromptLines...)
                        controls
                    }
                    .padding(.horizontal, MobileLayout.gutter)
                    .padding(.vertical, SH.Space.xl)
                }
            } else {
                ScrollView {
                    promptField
                        .padding(.horizontal, MobileLayout.gutter)
                        .padding(.top, SH.Space.xl)
                }
                .scrollDismissesKeyboard(.interactively)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    controls
                        .padding(.horizontal, MobileLayout.gutter)
                        .padding(.vertical, SH.Space.l)
                        .background(Color.sh.bgWindow)
                }
            }
        }
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
                NewThreadModelPicker(model: model) { model.panel = nil }
                    .navigationTitle("Model")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { model.panel = nil } } }
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

    private var controls: some View {
        VStack(alignment: .leading, spacing: SH.Space.l) {
            if !model.attachments.isEmpty { NewThreadAttachmentStrip(model: model) }
            chips
            HStack(spacing: SH.Space.s) {
                NewThreadAttachButton(model: model)
                    .padding(.leading, -SH.Space.l)
                worktreeSummary
                Spacer(minLength: SH.Space.s)
                if !pad { startButton }
            }
            status
        }
    }

    private var chips: some View {
        let repo = model.space?.name ?? "Choose repo"
        let host = model.host?.name ?? "Choose host"
        return SHFlowLayout(spacing: SHSelectorChipMetrics.spacing) {
            chip(repo, systemImage: "book.closed", name: "Repo", panel: pad ? .repo : .workspace, active: pad ? .repo : .workspace)
                .popover(isPresented: pad ? panel(.repo) : .constant(false), arrowEdge: .top) {
                    popover("Repo") {
                        NavigationStack {
                            ScrollView { NewThreadRepoList(model: model, carded: false) }
                                .background(Color.sh.bgRaised)
                                .navigationTitle("Repo")
                                .navigationBarTitleDisplayMode(.inline)
                                .navigationDestination(item: $model.folders) { NewThreadFolderScreen(model: model, browser: $0) }
                        }
                        .frame(height: MobileLayout.newThreadPopoverHeight)
                    }
                }
            chip(host, systemImage: "desktopcomputer", name: "Host", panel: pad ? .host : .workspace, active: pad ? .host : nil)
                .popover(isPresented: pad ? panel(.host) : .constant(false), arrowEdge: .top) {
                    popover("Run on") {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Run on")
                                .font(.sh(.ui))
                                .foregroundStyle(Color.sh.textPrimary)
                                .padding(.horizontal, SH.Space.xl)
                                .frame(minHeight: MobileLayout.rowHeight)
                                .accessibilityAddTraits(.isHeader)
                            SHHairline()
                            NewThreadHostList(model: model, carded: false)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            chip(NewThreadRules.shortModel(model.defaults.model), systemImage: "sparkle", name: "Model", panel: .model, active: .model)
                .popover(isPresented: pad ? panel(.model) : .constant(false), arrowEdge: .top) {
                    popover("Model") {
                        NewThreadModelPicker(model: model) { model.panel = nil }
                            .frame(height: MobileLayout.newThreadPopoverHeight)
                    }
                }
            if model.offersThinking {
                thinkingChip
                    .shTransition(.content)
            }
        }
        .shAnimation(.content, value: model.offersThinking)
        .buttonStyle(.shPressable(height: SHSelectorChipMetrics.height))
        .disabled(model.starting)
    }

    private func chip(_ label: String, systemImage: String, name: String, panel: NewThreadModel.Panel, active: NewThreadModel.Panel?) -> some View {
        Button {
            model.workspaceAnchor = nil
            model.panel = panel
        } label: {
            SHSelectorChip(label, systemImage: systemImage, active: active != nil && model.panel == active, accessibilityName: name)
        }
    }

    private var thinkingChip: some View {
        Menu {
            Picker("Thinking", selection: Binding(get: { model.thinking }, set: { model.setThinking($0) })) {
                ForEach(model.thinkingLevels, id: \.self) { level in
                    Text(level.title).tag(level)
                }
            }
        } label: {
            SHSelectorChip(model.thinking.title, systemImage: "lightbulb", mono: false, accessibilityName: "Thinking")
        }
        .menuStyle(.button)
    }

    private func popover<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(width: min(popoverWidth, MobileLayout.newThreadPopoverMaxWidth))
            .background(Color.sh.bgRaised)
            .presentationCompactAdaptation(.popover)
            .presentationBackground(Color.sh.bgRaised)
            .accessibilityLabel(title)
    }

    /// "New worktree on shepherd": opens the worktree's settings.
    private var worktreeSummary: some View {
        let text = NewThreadRules.worktreeSummary(repo: model.space?.name, worktree: model.usesWorktree)
        return Button {
            model.workspaceAnchor = .worktree
            model.panel = pad ? .worktree : .workspace
        } label: {
            HStack(spacing: SH.Space.s) {
                Image(systemName: SHGlyph.gitBranch.symbolName)
                    .font(.sh(.caption))
                    .accessibilityHidden(true)
                Text(text)
                    .font(.sh(.code))
                    .lineLimit(2)
            }
            .foregroundStyle(Color.sh.textTertiary)
            .frame(minHeight: SH.Height.touch)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(text)
        .accessibilityHint("Changes where the thread works")
        .popover(isPresented: pad ? panel(.worktree) : .constant(false), arrowEdge: .top) {
            popover("New worktree") {
                NewThreadWorktreeCard(model: model)
                    .padding(MobileLayout.gutter)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(Color.sh.bgWindow)
            }
        }
    }

    private var startButton: some View {
        let enabled = model.blocker == nil
        return Button { model.start() } label: {
            ZStack {
                Circle().fill(Color.sh.lantern)
                if model.starting {
                    ProgressView().progressViewStyle(SHSpinnerStyle(color: Color.sh.textOnLantern))
                } else {
                    Image(systemName: "arrow.up")
                        .font(.sh(.ui, weight: .semibold))
                        .foregroundStyle(Color.sh.textOnLantern)
                }
            }
            .frame(width: MobileLayout.newThreadStartSize, height: MobileLayout.newThreadStartSize)
        }
        .buttonStyle(.shPressable(height: MobileLayout.newThreadStartSize))
        // The style dims a blocked Start; while starting it stays lit with its spinner, and
        // a second tap does nothing (`start` needs no blocker).
        .disabled(!enabled && !model.starting)
        .allowsHitTesting(!model.starting)
        .accessibilityLabel(model.starting ? "Starting thread" : "Start thread")
        .accessibilityHint(model.blocker?.message ?? "")
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
        } else if let blocker = model.blocker, blocker != .starting {
            HStack(spacing: SH.Space.s) {
                if blocker.isPending { ProgressView().progressViewStyle(.shSpinner) }
                Text(blocker.message)
                    .shText(.caption)
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

