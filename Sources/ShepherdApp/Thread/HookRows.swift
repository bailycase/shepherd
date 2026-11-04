import SwiftUI
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdUI

// Hooks in a thread (HookThreadScene board): each hook's row, the proposal card an agent's
// `hook_propose` asks with, and the panel a hook's `ask` puts in the composer's place.

/// What a thread's hook pieces open in Settings › Hooks. Weak, so a row never keeps the model.
struct HookPresenter: Equatable {
    weak var model: ShepherdViewModel?

    static func == (a: Self, b: Self) -> Bool { a.model === b.model }

    @MainActor private func show(_ body: (HooksModel) -> Void) {
        guard let model else { return }
        model.settingsSection = .hooks
        model.showSettings = true
        model.hooks.tab = .hooks
        body(model.hooks)
    }

    /// Open hook: its editor, once the catalog has it.
    @MainActor func open(hash: String) { show { $0.open(hash: hash) } }
    /// Review in Settings.
    @MainActor func review() { show { $0.openReview(root: nil) } }
    /// The composer glyph: Settings › Hooks filtered to the thread's space.
    @MainActor func settings(spaceRoot: String?) { show { $0.spaceFilter = spaceRoot; $0.reload() } }
    /// A proposal's Edit…: Add hook, prefilled.
    @MainActor func edit(_ proposal: NativeHookProposal, scope: String) {
        let handler = HookHandler.command(proposal.command, timeout: proposal.timeout, statusMessage: proposal.statusMessage)
        let draft = HookDraft(event: proposal.event, matcher: proposal.matcher, handler: handler)
        show { $0.add(draft: draft, target: proposal.path(scope: scope)) }
    }
    /// A hook row arrived: the files may have changed.
    @MainActor func refresh() { model?.hooks.reload() }
    @MainActor func indicator(cwd: String?) -> HookIndicator? { model?.hooks.indicator(forCwd: cwd) }
    @MainActor func ensure(cwd: String) { model?.hooks.ensure(cwd: cwd) }
    /// The home folder paths are shown from ("~/.shepherd/hooks.json").
    @MainActor var home: String { model?.hooks.home ?? PiHome.environmentHome }
}

extension EnvironmentValues {
    @Entry var hookPresenter: HookPresenter? = nil
}

extension HooksModel {
    /// Opens the hook's editor now, or when the load under way brings it.
    func open(hash: String) {
        if let entry = entry(hash: hash) { edit(entry) } else { pendingEdit = hash; reload() }
    }
}

extension NativeHookRow.Kind {
    @MainActor var glyph: Image {
        switch self {
        case .ran: SHGlyph.resolved.image
        case .denied: Image(systemName: "xmark")
        case .sentBack: Image(systemName: "arrow.uturn.backward")
        case .added: Image(systemName: "plus")
        case .failed: Image(systemName: "exclamationmark.triangle")
        case .context: Image(systemName: "doc.plaintext")
        case .asked: Image(systemName: "questionmark.circle")
        case .systemMessage: Image(systemName: "info.circle")
        }
    }

    @MainActor var color: Color {
        switch self {
        case .ran, .systemMessage: Color.sh.textTertiary
        case .denied: Color.sh.failed
        case .sentBack, .failed, .asked: Color.sh.lantern
        case .added, .context: Color.sh.running
        }
    }
}

/// One hook's row: its glyph, the verb, the event and what it looked at, then (open) a box with
/// what the hook said and the command's meta, and Open hook.
struct HookEventRow: View, Equatable {
    let row: NativeHookRow
    @State private var open = true
    @Environment(\.hookPresenter) private var presenter

    static func == (a: Self, b: Self) -> Bool { a.row == b.row }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { if row.hasBox { withSHAnimation(.disclosure) { open.toggle() } } } label: {
                HStack(spacing: SH.Space.m) {
                    row.kind.glyph.font(.shSans(AppLayout.hookGlyphSize - SH.Space.xxs, .medium)).foregroundStyle(row.kind.color)
                        .frame(width: AppLayout.hookGlyphSize, height: AppLayout.hookGlyphSize)
                    Text(row.verb).font(.sh(.ui, weight: .regular)).foregroundStyle(Color.sh.textPrimary).lineLimit(1).layoutPriority(1)
                    if !row.detail.isEmpty {
                        Text(row.detail).font(.sh(.code)).foregroundStyle(Color.sh.textTertiary).lineLimit(1).truncationMode(.tail)
                    }
                    if row.hasBox { HookChevron(open: open) }
                }
                .padding(.horizontal, SH.Space.s)
                .frame(height: AppLayout.hookRowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.shRow(focusColor: .sh.running))
            .padding(.leading, -SH.Space.s)
            .disabled(!row.hasBox)
            .accessibilityLabel(row.spoken)
            .accessibilityValue(row.hasBox ? (open ? "Expanded" : "Collapsed") : "")
            if open, row.hasBox {
                VStack(alignment: .leading, spacing: SH.Space.xxs) {
                    ForEach(Array(row.lines.enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : line).font(.sh(.code)).foregroundStyle(Color.sh.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let meta = row.meta {
                        Text(meta).font(.sh(.code)).foregroundStyle(Color.sh.textTertiary)
                            .padding(.top, row.lines.isEmpty ? 0 : SH.Space.xxs).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .textSelection(.enabled)
                .padding(.horizontal, SH.Space.l).padding(.vertical, SH.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.sh.bgSunken, in: RoundedRectangle(cornerRadius: SH.Radius.m))
                .shBorder(Color.sh.lineSubtle, radius: SH.Radius.m)
                .padding(.leading, AppLayout.hookBoxIndent)
                .padding(.top, SH.Space.xs).padding(.bottom, SH.Space.s)
                .shTransition(.disclosure)
            }
            if case .openHook(let hash)? = row.link, let presenter {
                Button("Open hook") { presenter.open(hash: hash) }
                    .buttonStyle(.shLink)
                    .padding(.leading, AppLayout.hookBoxIndent)
            }
        }
        .frame(maxWidth: AppLayout.proseMaxWidth, alignment: .leading)
        .onAppear { if row.kind == .added { presenter?.refresh() } }
    }
}

// MARK: Proposal card

/// A hook the agent proposes, in place of the question: what it runs and when, where it would be
/// saved, the test against a sample event, and Edit…, Not now, Add and turn on.
struct HookProposalCard: View {
    let proposal: NativeHookProposal
    let enabled: Bool
    let answer: (String) -> Void
    @State private var scope: String
    @Environment(\.hookPresenter) private var presenter

    init(proposal: NativeHookProposal, enabled: Bool, answer: @escaping (String) -> Void) {
        self.proposal = proposal
        self.enabled = enabled
        self.answer = answer
        _scope = State(initialValue: proposal.scope)
    }

    private var scopes: [(String, String)] {
        (proposal.scopes.space != nil && proposal.options.contains(NativeHookProposal.addToSpace) ? [("space", "This space")] : []) + [("mac", "This Mac")]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: SH.Space.m) {
                Image(systemName: "plus").font(.sh(.ui)).foregroundStyle(Color.sh.running).accessibilityHidden(true)
                Text("Proposed hook: \(proposal.name)").font(.sh(.headline)).foregroundStyle(Color.sh.textPrimary).lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: SH.Space.m)
                Text(proposal.event).font(.sh(.code)).foregroundStyle(Color.sh.textTertiary)
            }
            .padding(.horizontal, SH.Space.xl).padding(.vertical, SH.Space.l)
            SHHairline()
            VStack(alignment: .leading, spacing: SH.Space.l) {
                Grid(alignment: .leading, horizontalSpacing: SH.Space.l, verticalSpacing: SH.Space.s) {
                    pair("When") { Text(HookEvent(rawValue: proposal.event)?.label ?? proposal.event).font(.sh(.ui)).foregroundStyle(Color.sh.textPrimary) }
                    pair("Matcher") { HookMatcherChip(text: proposal.matcher.isEmpty ? "always" : proposal.matcher, any: proposal.matcher.isEmpty) }
                    pair("Runs") { HookCommandText(text: proposal.command) }
                    if let status = proposal.statusMessage, !status.isEmpty {
                        pair("While it runs") { Text(status).font(.sh(.ui)).foregroundStyle(Color.sh.textSecondary) }
                    }
                    pair("Saved in") {
                        HStack(spacing: SH.Space.l) {
                            SHSegmentedPicker("Saved in", selection: $scope, options: scopes, size: .s).fixedSize()
                            Text(Self.shown(proposal.path(scope: scope), scope: scope)).font(.sh(.code)).foregroundStyle(Color.sh.textTertiary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                if let test = proposal.test {
                    HStack(spacing: SH.Space.m) {
                        Image(systemName: test.ok ? "checkmark" : "exclamationmark.triangle").font(.sh(.caption))
                            .foregroundStyle(test.ok ? Color.sh.done : Color.sh.lanternText).accessibilityHidden(true)
                        Text(proposal.testLead + test.summary).font(.sh(.ui)).foregroundStyle(Color.sh.textPrimary).lineLimit(2)
                        Spacer(minLength: SH.Space.m)
                        if let meta = proposal.testMeta { Text(meta).font(.sh(.code)).foregroundStyle(Color.sh.textTertiary) }
                    }
                    .padding(.horizontal, SH.Space.l).padding(.vertical, SH.Space.m)
                    .background(Color.sh.bgSunken, in: RoundedRectangle(cornerRadius: SH.Radius.m))
                    .shBorder(Color.sh.lineSubtle, radius: SH.Radius.m)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.horizontal, SH.Space.xl).padding(.vertical, SH.Space.l)
            SHHairline()
            HStack(spacing: SH.Space.m) {
                Text("Adding it trusts this exact entry. If it changes later, here or in the file, it needs your review again.")
                    .font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary).lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let presenter {
                    Button("Edit…") { presenter.edit(proposal, scope: scope) }.buttonStyle(.sh(.ghost, size: .m))
                }
                Button(NativeHookProposal.notNow) { answer(NativeHookProposal.notNow) }.buttonStyle(.sh(.secondary, size: .m))
                // No default action: Return never trusts a hook.
                Button("Add and turn on") { answer(proposal.addOption(scope: scope)) }
                    .buttonStyle(.sh(.primary, size: .m))
            }
            .disabled(!enabled)
            .padding(.horizontal, SH.Space.xl).padding(.vertical, SH.Space.l)
        }
        .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Radius.l))
        .shBorder(Color.sh.lineStrong, radius: SH.Radius.l)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Proposed hook: \(proposal.name)")
    }

    /// "payments/.shepherd/hooks.json", "~/.shepherd/hooks.json": the file as the board names it.
    static func shown(_ path: String, scope: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        return scope == "space" ? parts.suffix(3).joined(separator: "/") : "~/" + parts.suffix(2).joined(separator: "/")
    }

    private func pair<V: View>(_ key: String, @ViewBuilder value: () -> V) -> some View {
        GridRow {
            Text(key).font(.sh(.ui)).foregroundStyle(Color.sh.textTertiary).frame(width: AppLayout.hookCardKeyWidth, alignment: .leading)
            value().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A command the person is asked to trust: whole and selectable, scrolling past a few lines, never cut.
struct HookCommandText: View {
    let text: String
    @State private var height: CGFloat = 0

    var body: some View {
        // Its own height up to the cap, scrolling past it (as iOS's fitted scroll does).
        ScrollView {
            Text(text).font(.sh(.code)).foregroundStyle(Color.sh.textPrimary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(height, AppLayout.hookCommandMaxHeight))
    }
}

// MARK: Ask panel

/// A hook's `ask` in the composer's place: the call, the hook's reason, Deny or Allow once.
struct HookAskPanel: View {
    let ask: NativeHookAsk
    let home: String
    let enabled: Bool
    let answer: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.l) {
            HStack(spacing: SH.Space.m) {
                Image(systemName: "questionmark.circle").font(.sh(.ui)).foregroundStyle(Color.sh.lantern).accessibilityHidden(true)
                Text(NativeHookAsk.title).font(.sh(.headline)).foregroundStyle(Color.sh.textPrimary).accessibilityAddTraits(.isHeader)
                Spacer(minLength: SH.Space.m)
                Text(HooksModel.tilde(ask.file, home: home)).font(.sh(.code)).foregroundStyle(Color.sh.textTertiary)
                    .lineLimit(1).truncationMode(.middle).help(ask.file)
            }
            if !ask.call.isEmpty {
                HookCommandText(text: ask.call)
                    .padding(.horizontal, SH.Space.l).padding(.vertical, SH.Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.sh.bgSunken, in: RoundedRectangle(cornerRadius: SH.Radius.m))
                    .shBorder(Color.sh.lineSubtle, radius: SH.Radius.m)
            }
            if !ask.reason.isEmpty {
                Text(ask.reason).font(.sh(.ui)).foregroundStyle(Color.sh.textSecondary).lineLimit(4)
            }
            HStack(spacing: SH.Space.m) {
                Text("The agent waits. Deny sends the hook’s reason to it.").font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                Spacer(minLength: SH.Space.m)
                Button(NativeHookAsk.deny) { answer(NativeHookAsk.deny) }.buttonStyle(.sh(.secondary, size: .l))
                // No default action: Return never allows the call.
                Button(NativeHookAsk.allow) { answer(NativeHookAsk.allow) }.buttonStyle(.sh(.primary, size: .l))
            }
            .disabled(!enabled)
        }
        .padding(SH.Space.xl)
        .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Radius.l))
        .shBorder(Color.sh.lantern, radius: SH.Radius.l)
        .accessibilityElement(children: .contain)
    }
}

/// The composer's hook glyph: hooks run in this thread's space, and a lantern dot while some
/// wait for review. Opens Settings › Hooks for the space.
struct HookComposerGlyph: View {
    let indicator: HookIndicator
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            SHGlyph.hook.image
                .overlay(alignment: .topTrailing) {
                    if indicator.needingReview > 0 {
                        Circle().fill(Color.sh.lantern).frame(width: AppLayout.hookComposerDot, height: AppLayout.hookComposerDot)
                            .offset(x: SH.Space.xxs, y: -SH.Space.xxs)
                    }
                }
        }
        .buttonStyle(.shIcon(size: SHComposerMetrics.chipHeight))
        .help(indicator.help)
        .accessibilityLabel("Hooks")
        .accessibilityValue(indicator.help)
    }
}
