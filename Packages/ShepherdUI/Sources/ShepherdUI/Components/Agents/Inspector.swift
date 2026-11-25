import SwiftUI

/// The Mac inspector card's measures (GXSubagents' `.gsv-*`).
public enum SHInspectorMetrics {
    /// The title wraps up to this many lines, then truncates.
    public static let titleMaxLines = 3
    /// The Steer circle and its arrow (`.gsv-send`).
    public static let sendSize: CGFloat = 24
    public static let sendGlyph: CGFloat = 12
}

/// The subagent inspector's header (Agents board): the branch glyph in the run's state, its
/// name with "· 3 of 3", a mono meta line ending in a state-colored accent ("done 11:02"), and
/// the caller's controls on the trailing side. On the Mac (`.gsv-hd`) it is the card's head: the title wraps, under it
/// "Worker, running for 37m" (`meta`, then the time from `since`), `detail` in its tooltip, the controls to its right.
public struct SHInspectorHeader<Trailing: View>: View {
    let title: String
    let position: String?
    let state: AgentState
    let meta: String
    let accent: String?
    let minHeight: CGFloat
    let since: Date?
    let until: Date?
    let hot: Bool
    let detail: String?
    @ViewBuilder let trailing: () -> Trailing

    /// `minHeight` lets the pane line its header up with the thread's. `since` and `until` end the Mac's subtitle with the
    /// run's time (live from `since`); `hot` says it in `lanternText` (a run that asked its parent).
    public init(_ title: String, position: String? = nil, state: AgentState, meta: String, accent: String? = nil,
                minHeight: CGFloat = 44, since: Date? = nil, until: Date? = nil, hot: Bool = false, detail: String? = nil,
                @ViewBuilder trailing: @escaping () -> Trailing) {
        self.since = since
        self.until = until
        self.hot = hot
        self.detail = detail
        self.title = title
        self.position = position
        self.state = state
        self.meta = meta
        self.accent = accent
        self.minHeight = minHeight
        self.trailing = trailing
    }

    public var body: some View {
        let sh = Color.sh
        #if os(macOS)
        // The boards' `.gsv-hd`: the title in `title` (it wraps) over "Worker, running for 37m" in `caption`, no glyph; its
        // controls on the right, 2pt apart.
        HStack(alignment: .top, spacing: SH.Space.l) {
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(title).font(.sh(.title)).foregroundStyle(sh.textPrimary)
                    .lineLimit(SHInspectorMetrics.titleMaxLines).truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: 0) {
                    Text(meta)
                    if let since { SHElapsedText(since: since, until: until) }
                    Text(accentText)
                }
                .font(hot ? .sh(.caption, weight: .medium) : .sh(.caption))
                .foregroundStyle(hot ? sh.lanternText : sh.textTertiary)
                .lineLimit(1)
                .help(detail ?? meta + accentText)
            }
            .accessibilityElement(children: .combine)
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: SH.Space.xxs) { trailing() }
        }
        .padding(EdgeInsets(top: SH.Space.l, leading: SH.Space.xl, bottom: 0, trailing: SH.Space.l))
        .frame(maxWidth: .infinity, alignment: .top)
        #else
        HStack(spacing: SH.Space.m) {
            SHBranchGlyph(state, size: 13)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(Text(title).font(.shSans(13, .semibold)).foregroundStyle(sh.textPrimary))\(Text(position.map { " · \($0)" } ?? "").font(.shSans(13)).foregroundStyle(sh.textSecondary))")
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Text("\(Text(meta))\(Text(accentText).foregroundStyle(state.textColor))")
                    .font(.shMono(10.5))
                    .foregroundStyle(sh.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(meta + accentText)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: SH.Space.m)
            HStack(spacing: SH.Space.xs) { trailing() }
        }
        .padding(.leading, SH.Space.l)
        .padding(.trailing, SH.Space.s)
        .frame(maxWidth: .infinity, minHeight: minHeight)
        .overlay(alignment: .bottom) { SHHairline() }
        #endif
    }

    private var accentText: String {
        guard let accent else { return "" }
        return meta.isEmpty ? accent : " · \(accent)"
    }
}

/// A run's brief under the inspector header (Agents board): its GOAL (with an optional mono
/// note on the right, "step 1 / 1 · 62%"), and once it finished its RESULT in the state's color
/// followed by the caller's file links. A run that asked its parent shows its question under
/// "Asked the parent" in the place of the result.
public struct SHRunBrief<Files: View>: View {
    let goal: String
    let note: String?
    let result: String?
    let resultLabel: String
    let resultState: AgentState
    @ViewBuilder let files: () -> Files

    public init(goal: String, note: String? = nil, result: String? = nil, resultLabel: String = "Result",
                resultState: AgentState = .done, @ViewBuilder files: @escaping () -> Files) {
        self.goal = goal
        self.note = note
        self.result = result
        self.resultLabel = resultLabel
        self.resultState = resultState
        self.files = files
    }

    public var body: some View {
        let sh = Color.sh
        #if os(macOS)
        // The Mac's goal is the card's title (`.gsv-title`); what is left is a finished or asking run's result, under the head.
        VStack(alignment: .leading, spacing: SH.Space.m) {
            if let result {
                VStack(alignment: .leading, spacing: SH.Space.m) {
                    SHBriefLabel(text: resultLabel, color: resultState.textColor)
                    SHInlineText(text: result, codeSize: 11.5).equatable()
                        .font(.sh(.ui, weight: .regular)).lineSpacing(SH.Space.xs)
                        .foregroundStyle(sh.textPrimary)
                        .lineLimit(8)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    files()
                }
                .padding(.top, SH.Space.l)
                .padding(.bottom, SH.Space.l)
                .overlay(alignment: .bottom) { SHHairline() }
                .shTransition(.disclosure)
            }
        }
        .shAnimation(.disclosure, value: result != nil)
        .padding(.horizontal, SH.Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        #else
        VStack(alignment: .leading, spacing: SH.Space.m) {
            HStack(alignment: .firstTextBaseline) {
                SHBriefLabel(text: "Goal")
                Spacer(minLength: SH.Space.m)
                if let note {
                    Text(note).font(Self.noteFont).foregroundStyle(sh.textTertiary).monospacedDigit().lineLimit(1)
                        .shContentTransition(.numeric())
                }
            }
            .shAnimation(.content, value: note)
            Text(goal)
                .font(.sh(.ui, weight: .regular)).lineSpacing(SH.Space.xs)
                .foregroundStyle(sh.textSecondary)
                .lineLimit(6)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let result {
                VStack(alignment: .leading, spacing: SH.Space.m) {
                    SHBriefLabel(text: resultLabel, color: resultState.textColor)
                    SHInlineText(text: result, codeSize: 11.5).equatable()
                        .font(.sh(.ui, weight: .regular)).lineSpacing(SH.Space.xs)
                        .foregroundStyle(sh.textPrimary)
                        .lineLimit(8)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    files()
                }
                .shTransition(.disclosure)
            }
        }
        .shAnimation(.disclosure, value: result != nil)
        .padding(.vertical, 10)
        .padding(.horizontal, SH.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(sh.bgSunken)
        #endif
    }

    @MainActor private static var noteFont: Font {
        #if os(macOS)
        .sh(.caption)
        #else
        .shMono(10.5)
        #endif
    }
}

extension SHRunBrief where Files == EmptyView {
    public init(goal: String, note: String? = nil, result: String? = nil, resultLabel: String = "Result",
                resultState: AgentState = .done) {
        self.init(goal: goal, note: note, result: result, resultLabel: resultLabel, resultState: resultState) { EmptyView() }
    }
}

/// The bar under a finished run (Agents board): its actions (Re-run · Fork · Copy transcript)
/// on a hairline, with an optional trailing note.
public struct SHRunActions<Actions: View, Trailing: View>: View {
    @ViewBuilder let actions: () -> Actions
    @ViewBuilder let trailing: () -> Trailing

    public init(@ViewBuilder actions: @escaping () -> Actions, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.actions = actions
        self.trailing = trailing
    }

    public var body: some View {
        HStack(spacing: SH.Space.s) {
            actions()
            Spacer(minLength: SH.Space.m)
            trailing()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, SH.Space.l)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) { SHHairline() }
    }
}

extension SHRunActions where Trailing == EmptyView {
    public init(@ViewBuilder actions: @escaping () -> Actions) {
        self.init(actions: actions) { EmptyView() }
    }
}

#if os(macOS)
/// The Steer field's send (the boards' `.gsv-send`): an arrow in a 24pt circle, on the ink fill once there is something to send and
/// on `bgSelected` with a dim arrow before.
public struct SHInspectorSendButton: View {
    let label: String
    let help: String
    let enabled: Bool
    let action: () -> Void

    public init(_ label: String, help: String = "", enabled: Bool, action: @escaping () -> Void) {
        self.label = label
        self.help = help
        self.enabled = enabled
        self.action = action
    }

    public var body: some View {
        let sh = Color.sh
        Button(action: action) {
            Image(systemName: "arrow.up")
                .font(.system(size: SHInspectorMetrics.sendGlyph, weight: .semibold))
                .foregroundStyle(enabled ? sh.textOnPrimary : sh.textTertiary)
                .frame(width: SHInspectorMetrics.sendSize, height: SHInspectorMetrics.sendSize)
                .background(enabled ? sh.primary : sh.bgSelected, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(label)
    }
}
#endif
