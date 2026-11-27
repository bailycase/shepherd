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

    @MainActor private var hooks: HooksModel? { model?.hooks }

    @MainActor private func show(_ body: (HooksModel) -> Void) {
        guard let model, let hooks else { return }
        model.settingsSection = .hooks
        model.showSettings = true
        hooks.tab = .hooks
        body(hooks)
    }

    /// Open hook: its editor, once the catalog has it.
    @MainActor func open(hash: String) { show { $0.open(hash: hash) } }
    /// The composer glyph: Settings › Hooks filtered to the thread's space.
    @MainActor func settings(spaceRoot: String?) { show { $0.spaceFilter = spaceRoot; $0.reload() } }
    /// A proposal's Edit…: Add hook, prefilled. Saving it calls `saved` (which answers the proposal); Cancel leaves it pending.
    @MainActor func edit(_ proposal: NativeHookProposal, scope: String, saved: @escaping @MainActor () -> Void) {
        let handler = HookHandler.command(proposal.command, timeout: proposal.timeout, statusMessage: proposal.statusMessage)
        let draft = HookDraft(event: proposal.event, matcher: proposal.matcher, handler: handler)
        show { $0.add(draft: draft, target: proposal.path(scope: scope), saved: saved) }
    }
    /// A hook row arrived: the files may have changed.
    @MainActor func refresh() { hooks?.reload() }
    @MainActor func indicator(cwd: String?) -> HookIndicator? { hooks?.indicator(forCwd: cwd) }
    @MainActor func ensure(cwd: String) { hooks?.ensure(cwd: cwd) }
    /// The home folder paths are shown from ("~/.shepherd/hooks.json").
    @MainActor var home: String { hooks.flatMap { $0.home.isEmpty ? nil : $0.home } ?? PiHome.environmentHome }
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
                    Text(row.verb).font(.sh(.ui, weight: .regular)).foregroundStyle(row.kind == .failed ? Color.sh.failed : Color.sh.textPrimary)
                        .lineLimit(1).layoutPriority(1)
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
                // The board's output box: a quiet `bgHover` tile at radius 8, mono 12 on 19pt lines in `textSecondary`,
                // the command's meta in `textTertiary`.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(row.lines.enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : line).shText(size: AppLayout.hookBoxSize, mono: true, lineHeight: AppLayout.hookBoxLine)
                            .foregroundStyle(Color.sh.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let meta = row.meta {
                        Text(meta).shText(size: AppLayout.hookBoxSize, mono: true, lineHeight: AppLayout.hookBoxLine)
                            .foregroundStyle(Color.sh.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .textSelection(.enabled)
                .padding(.horizontal, SH.Space.l).padding(.vertical, SH.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.sh.bgHover, in: RoundedRectangle(cornerRadius: SH.Radius.m))
                .padding(.leading, AppLayout.hookBoxIndent)
                .padding(.top, SH.Space.xs).padding(.bottom, SH.Space.s)
                .shTransition(.disclosure)
            }
            if case .openHook(let hash)? = row.link, let presenter {
                Button { presenter.open(hash: hash) } label: {
                    Text("Open hook").font(.sh(.ui, weight: .medium)).foregroundStyle(Color.sh.textPrimary)
                        .frame(minHeight: AppLayout.hookRowHeight).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
        let sh = Color.sh
        // The board's card (`hk-card`): a raised, lifted card at radius 12; the title with its event at the right, a row of
        // 13pt words per fact, the test in a quiet tile, and the three answers as words.
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: SH.Space.m) {
                Text("Proposed hook: \(proposal.name)").font(.sh(.ui, weight: .semibold)).foregroundStyle(sh.textPrimary).lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: SH.Space.m)
                Text(proposal.event).font(.sh(.caption)).foregroundStyle(sh.textTertiary)
            }
            .padding(.horizontal, AppLayout.hookCardInset).padding(.vertical, AppLayout.hookCardHeaderVertical)
            VStack(alignment: .leading, spacing: 0) {
                pair("When") { Text(HookEvent(rawValue: proposal.event)?.label ?? proposal.event).font(.sh(.ui)).foregroundStyle(sh.textPrimary) }
                pair("Matcher") { Text(proposal.matcher.isEmpty ? "always" : proposal.matcher).font(.sh(.code)).foregroundStyle(sh.textPrimary) }
                pair("Runs") { HookCommandText(text: proposal.command) }
                if let status = proposal.statusMessage, !status.isEmpty {
                    pair("While it runs") { Text(status).font(.sh(.ui)).foregroundStyle(sh.textPrimary) }
                }
                pair("Saved in") {
                    HStack(spacing: AppLayout.hookCardScopeGap) {
                        Menu {
                            ForEach(scopes, id: \.0) { value, title in Button(title) { scope = value } }
                        } label: {
                            HStack(spacing: SH.Space.xxs) {
                                Text(scopes.first { $0.0 == scope }?.1 ?? "").font(.sh(.ui)).foregroundStyle(sh.textPrimary)
                                Image(systemName: "chevron.down").font(.shSans(AppLayout.hookCardChevron, .semibold)).foregroundStyle(sh.textTertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                        .accessibilityLabel("Saved in")
                        Text(Self.shown(proposal.path(scope: scope), scope: scope)).font(.sh(.ui)).foregroundStyle(sh.textTertiary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            if let test = proposal.test {
                HStack(spacing: SH.Space.m) {
                    Text(proposal.testLead + test.summary).font(.sh(.ui)).foregroundStyle(test.ok ? sh.textSecondary : sh.lanternText).lineLimit(2)
                    Spacer(minLength: SH.Space.m)
                    if let meta = proposal.testMeta { Text(meta).font(.sh(.ui)).foregroundStyle(sh.textTertiary) }
                }
                .padding(.horizontal, SH.Space.l - SH.Space.xxs).padding(.vertical, AppLayout.hookCardTestVertical)
                .background(sh.bgHover, in: RoundedRectangle(cornerRadius: SH.Radius.m))
                .padding(.horizontal, AppLayout.hookCardInset).padding(.top, AppLayout.hookCardTestTop)
                .accessibilityElement(children: .combine)
            }
            HStack(spacing: SH.Space.xl) {
                Text("It runs with your permissions until you turn it off in Settings ▸ Hooks.")
                    .font(.sh(.caption)).foregroundStyle(sh.textTertiary).lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let presenter {
                    Button("Edit…") { presenter.edit(proposal, scope: scope) { answer(NativeHookProposal.addedInSettings) } }.buttonStyle(HookWordStyle(quiet: true))
                }
                Button(NativeHookProposal.notNow) { answer(NativeHookProposal.notNow) }.buttonStyle(HookWordStyle(quiet: true))
                // No default action: Return never adds a hook.
                Button("Add and turn on") { answer(proposal.addOption(scope: scope)) }.buttonStyle(HookWordStyle(quiet: false))
            }
            .disabled(!enabled)
            .padding(.horizontal, AppLayout.hookCardInset).padding(.top, AppLayout.hookCardFooterTop).padding(.bottom, AppLayout.hookCardFooterBottom)
        }
        .shCard(radius: AppLayout.hookCardRadius, lift: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Proposed hook: \(proposal.name)")
    }

    /// "payments/.shepherd/hooks.json", "~/.shepherd/hooks.json": the file as the board names it.
    static func shown(_ path: String, scope: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        return scope == "space" ? parts.suffix(3).joined(separator: "/") : "~/" + parts.suffix(2).joined(separator: "/")
    }

    private func pair<V: View>(_ key: String, @ViewBuilder value: () -> V) -> some View {
        HStack(alignment: .top, spacing: SH.Space.l) {
            Text(key).font(.sh(.ui)).foregroundStyle(Color.sh.textTertiary).frame(width: AppLayout.hookCardKeyWidth, alignment: .leading)
            value().frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, AppLayout.hookCardInset).padding(.vertical, AppLayout.hookCardRowVertical)
    }
}

/// A command the person is asked about: whole and selectable, scrolling past a few lines, never cut.
struct HookCommandText: View {
    let text: String
    /// In `textSecondary` (the ask's tile) rather than primary ink.
    var secondary = false
    @State private var height: CGFloat = 0

    var body: some View {
        // Its own height up to the cap, scrolling past it (as iOS's fitted scroll does).
        ScrollView {
            Text(text).font(.sh(.code)).foregroundStyle(secondary ? Color.sh.textSecondary : Color.sh.textPrimary).textSelection(.enabled)
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
        let sh = Color.sh
        // The board's ask card (`ask`): lifted, radius 14, a lantern dot before the title, the call in a quiet tile, the
        // hook's reason with its file after it, and Deny as a word beside the ink pill.
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: AppLayout.hookAskGap) {
                Circle().fill(sh.lanternText).frame(width: AppLayout.hookAskDot, height: AppLayout.hookAskDot)
                    .padding(.top, AppLayout.hookAskDotTop).accessibilityHidden(true)
                Text(NativeHookAsk.title).shText(size: AppLayout.hookAskTitleSize, weight: .semibold, lineHeight: AppLayout.hookAskTitleLine)
                    .foregroundStyle(sh.textPrimary).accessibilityAddTraits(.isHeader)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, AppLayout.hookAskInset).padding(.trailing, AppLayout.hookAskTitleTrailing)
            if !ask.call.isEmpty {
                HookCommandText(text: ask.call, secondary: true)
                    .padding(.horizontal, SH.Space.l).padding(.vertical, SH.Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(sh.bgHover, in: RoundedRectangle(cornerRadius: SH.Radius.m))
                    .padding(.horizontal, AppLayout.hookAskInset).padding(.top, AppLayout.hookAskBlockTop)
            }
            if !ask.reason.isEmpty {
                (Text(ask.reason + " ").foregroundStyle(sh.textSecondary)
                    + Text(HooksPresentation.tilde(ask.file, home: home)).foregroundStyle(sh.textTertiary))
                    .font(.sh(.ui)).lineLimit(4)
                    .help(ask.file)
                    .padding(.horizontal, AppLayout.hookAskInset).padding(.top, AppLayout.hookAskBlockTop)
            }
            HStack(spacing: AppLayout.hookAskButtonGap) {
                Text("The agent waits. Deny sends the hook’s reason to it.").font(.sh(.caption)).foregroundStyle(sh.textTertiary)
                    .padding(.leading, SH.Space.m)
                Spacer(minLength: SH.Space.m)
                Button(NativeHookAsk.deny) { answer(NativeHookAsk.deny) }.buttonStyle(HookAskButton(allow: false))
                // No default action: Return never allows the call.
                Button(NativeHookAsk.allow) { answer(NativeHookAsk.allow) }.buttonStyle(HookAskButton(allow: true))
            }
            .padding(.horizontal, AppLayout.hookAskFootInset).padding(.top, AppLayout.hookAskFootTop)
            .disabled(!enabled)
        }
        .padding(EdgeInsets(top: AppLayout.hookAskTop, leading: AppLayout.hookAskSides, bottom: AppLayout.hookAskBottom, trailing: AppLayout.hookAskSides))
        .shCard(radius: AppLayout.hookAskRadius, lift: true)
        .accessibilityElement(children: .contain)
    }
}

/// Deny (a word) and Allow once (an ink pill): 30pt tall.
private struct HookAskButton: ButtonStyle {
    let allow: Bool
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.sh(.ui, weight: allow ? .medium : .regular))
            .foregroundStyle(allow ? Color.sh.textOnPrimary : Color.sh.textSecondary)
            .padding(.horizontal, allow ? AppLayout.hookAskAllowPadding : AppLayout.hookAskDenyPadding)
            .frame(height: AppLayout.hookAskButtonHeight)
            .background { if allow { Capsule().fill(configuration.isPressed ? Color.sh.primaryPressed : Color.sh.primary) } }
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Rectangle())
    }
}

/// A proposal's answers as words: `quiet` ones in `textSecondary`, the one that adds in 500 `textPrimary`.
private struct HookWordStyle: ButtonStyle {
    let quiet: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.sh(.ui, weight: quiet ? .regular : .medium))
            .foregroundStyle(quiet ? Color.sh.textSecondary : Color.sh.textPrimary)
            .lineLimit(1).fixedSize()
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

/// The composer's hook glyph: hooks run in this thread's space. Opens Settings › Hooks for the space.
struct HookComposerGlyph: View {
    let indicator: HookIndicator
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            SHGlyph.hook.image
        }
        .buttonStyle(.shIcon(size: SHComposerMetrics.chipHeight))
        .help(indicator.help)
        .accessibilityLabel("Hooks")
        .accessibilityValue(indicator.help)
    }
}
