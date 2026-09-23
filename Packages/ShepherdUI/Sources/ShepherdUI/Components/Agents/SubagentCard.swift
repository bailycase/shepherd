import SwiftUI

/// A question a subagent asked, with the answers it offered (the first is the recommended one).
public struct NWSubagentQuestion: Equatable, Sendable {
    public var text: String
    public var options: [String]

    public init(text: String, options: [String] = []) {
        self.text = text
        self.options = options
    }
}

/// Everything a subagent card shows, as values.
public struct NWSubagentRun: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// The agent profile, as a tag ("worker"); nil when it would repeat the name.
    public var role: String?
    /// The model, as a mono tag ("claude-sonnet").
    public var model: String?
    public var state: AgentState
    /// Replaces the pill's word ("Paused").
    public var stateLabel: String?
    /// The one mono line under the header: what the run is doing, asking, or did. Truncates.
    public var detail: String
    /// Kept whole after the detail ("26 tools · 12m").
    public var detailMeta: String?
    /// Counts live after the detail while the run waits on an answer ("· 2m").
    public var waitingSince: Date?
    /// 0…1 under the detail, with its percent.
    public var progress: Double?
    /// What the progress measures, for its tooltip and VoiceOver ("Context window used").
    public var progressLabel: String?
    /// Shown while the run needs you.
    public var question: NWSubagentQuestion?

    public init(id: String, name: String, role: String? = nil, model: String? = nil, state: AgentState,
                stateLabel: String? = nil, detail: String, detailMeta: String? = nil, waitingSince: Date? = nil,
                progress: Double? = nil, progressLabel: String? = nil, question: NWSubagentQuestion? = nil) {
        self.id = id
        self.name = name
        self.role = role
        self.model = model
        self.state = state
        self.stateLabel = stateLabel
        self.detail = detail
        self.detailMeta = detailMeta
        self.waitingSince = waitingSince
        self.progress = progress
        self.progressLabel = progressLabel
        self.question = question
    }

    /// "desktop, worker, Running, edit DesktopNativeThreadView.swift"; a finished run adds its
    /// meta ("reviewer, Done, 2 spec deviations fixed, 26 tools · 12m").
    public var accessibilityLabel: String {
        ([name, role, stateLabel ?? state.label, detail, detailMeta] as [String?]).compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// The progress as VoiceOver reads it ("Context window used 62%"); empty without progress.
    public var accessibilityValue: String {
        percent.map { "\(progressLabel ?? "Progress") \($0)%" } ?? ""
    }

    /// `progress` as a whole percent.
    var percent: Int? { progress.map { Int((min(1, max(0, $0)) * 100).rounded()) } }
}

/// A live subagent inline in its parent's turn (Agents board): branch glyph, name, role and
/// model tags, and the state pill; one mono line of what it is doing; a progress bar while it
/// runs; its question and answers while it needs you; Open replay and Re-run once it failed.
/// Clicking the card opens the run in the inspector; the inspected card wears a running ring.
public struct NWSubagentCard: View, Equatable {
    let run: NWSubagentRun
    let isSelected: Bool
    let isEnabled: Bool
    let inspect: () -> Void
    let answer: ((String) -> Void)?
    let rerun: (() -> Void)?
    /// Which actions exist, for `==` (closures do not compare).
    private let actionShape: [Bool]
    @State private var replying = false
    @State private var reply = ""
    @FocusState private var replyFocused: Bool

    /// `isEnabled` gates the answer and re-run actions (inspecting always works). A nil
    /// `answer` hides the question's buttons; a nil `rerun` hides Re-run.
    public init(_ run: NWSubagentRun, isSelected: Bool = false, isEnabled: Bool = true, inspect: @escaping () -> Void,
                answer: ((String) -> Void)? = nil, rerun: (() -> Void)? = nil) {
        self.run = run
        self.isSelected = isSelected
        self.isEnabled = isEnabled
        self.inspect = inspect
        self.answer = answer
        self.rerun = rerun
        self.actionShape = [answer != nil, rerun != nil]
    }

    public nonisolated static func == (a: NWSubagentCard, b: NWSubagentCard) -> Bool {
        a.run == b.run && a.isSelected == b.isSelected && a.isEnabled == b.isEnabled && a.actionShape == b.actionShape
    }

    public var body: some View {
        let nw = Color.nw
        let shape = RoundedRectangle(cornerRadius: NW.Radius.m)
        VStack(alignment: .leading, spacing: NW.Space.m) {
            Button(action: inspect) { summary }
                .buttonStyle(.plain)
                .accessibilityLabel(run.accessibilityLabel)
                .accessibilityValue(run.accessibilityValue)
                .accessibilityHint("Opens the run in the inspector")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            if run.state == .attention, let question = run.question {
                questionBox(question)
            }
            if run.state == .failed {
                HStack(spacing: NW.Space.s) {
                    Button("Open replay", action: inspect).buttonStyle(.nw(.secondary, size: .s))
                    if let rerun {
                        Button("Re-run", action: rerun).buttonStyle(.nw(.ghost, size: .s)).disabled(!isEnabled)
                            .accessibilityLabel("Re-run \(run.name)")
                    }
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, NW.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(nw.bgRaised, in: shape)
        .nwBorder(isSelected ? nw.running : run.state == .attention ? nw.lantern : nw.lineSubtle, radius: NW.Radius.m)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: NW.Radius.m + Self.ring).fill(nw.runningTint).padding(-Self.ring)
            }
        }
        .contentShape(shape)
        .onTapGesture(perform: inspect)
        .accessibilityElement(children: .contain)
    }

    /// The selection ring outside the inspected card.
    private static let ring: CGFloat = 3

    private var summary: some View {
        let nw = Color.nw
        return VStack(alignment: .leading, spacing: NW.Space.m) {
            HStack(spacing: NW.Space.m) {
                NWBranchGlyph(run.state, size: 13)
                Text(run.name).font(.nw(.ui, weight: .semibold)).foregroundStyle(nw.textPrimary).lineLimit(1)
                if let role = run.role { NWTag(role) }
                if let model = run.model { NWTag(model, mono: true) }
                Spacer(minLength: NW.Space.m)
                NWStatusPill(run.state, label: run.stateLabel)
            }
            HStack(spacing: 0) {
                Text(run.detail).lineLimit(1).truncationMode(.tail)
                if let meta = run.detailMeta, !meta.isEmpty {
                    Text(" · \(meta)").lineLimit(1).layoutPriority(1)
                }
                if let since = run.waitingSince {
                    Text(" · ")
                    NWElapsedText(since: since)
                }
            }
            .font(.nwMono(11))
            .foregroundStyle(nw.textSecondary)
            if let progress = run.progress {
                HStack(spacing: NW.Space.m) {
                    ProgressView(value: progress).progressViewStyle(.nwBar)
                        .accessibilityLabel(run.progressLabel ?? "Progress")
                    Text("\(run.percent ?? 0)%")
                        .font(.nwMono(10)).foregroundStyle(nw.textTertiary).monospacedDigit().fixedSize()
                        .accessibilityHidden(true)
                }
                .help(run.progressLabel ?? "")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func questionBox(_ question: NWSubagentQuestion) -> some View {
        let nw = Color.nw
        return VStack(alignment: .leading, spacing: NW.Space.s) {
            NWInlineText(text: question.text, codeSize: 11.5).equatable()
                .font(.nw(.ui, weight: .regular))
                .lineSpacing(NW.Space.xxs)
                .foregroundStyle(nw.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let answer {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: NW.Space.s) { answers(question, answer: answer) }
                    VStack(alignment: .leading, spacing: NW.Space.s) { answers(question, answer: answer) }
                }
                if replying { replyField(answer: answer) }
            }
        }
        .padding(.vertical, NW.Space.m)
        .padding(.horizontal, 10)
        .background(nw.lanternTint, in: RoundedRectangle(cornerRadius: NW.Radius.s))
    }

    @ViewBuilder private func answers(_ question: NWSubagentQuestion, answer: @escaping (String) -> Void) -> some View {
        ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
            Button(option) { answer(option) }
                .buttonStyle(.nw(index == 0 ? .primary : .secondary, size: .s))
                .disabled(!isEnabled)
                .accessibilityLabel("Answer \(option)")
        }
        Button("Reply…") {
            replying.toggle()
            replyFocused = replying
        }
        .buttonStyle(.nw(question.options.isEmpty ? .secondary : .ghost, size: .s))
        .disabled(!isEnabled)
        .accessibilityLabel("Reply to \(run.name)")
    }

    private func replyField(answer: @escaping (String) -> Void) -> some View {
        HStack(spacing: NW.Space.s) {
            TextField("Reply to \(run.name)…", text: $reply)
                .focused($replyFocused)
                .nwField(focused: replyFocused)
                .onSubmit { send(answer) }
                .accessibilityLabel("Reply to \(run.name)")
            Button("Send") { send(answer) }
                .buttonStyle(.nw(.secondary, size: .m))
                .disabled(!isEnabled || reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func send(_ answer: (String) -> Void) {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isEnabled, !text.isEmpty else { return }
        answer(text)
        reply = ""
        replying = false
    }
}
