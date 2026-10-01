import SwiftUI

/// The goal's presentation, independent of an agent's turn or the goal runner.
public enum NWGoalState: CaseIterable, Equatable, Sendable {
    case working, checking, met, paused, needsYou

    static let confirmationExplanation = "Confirm that every requirement is met despite missing recorded evidence. This is your attestation, not independent verification."

    var label: String {
        switch self {
        case .working: "Working"
        case .checking: "Checking"
        case .met: "Met"
        case .paused: "Paused"
        case .needsYou: "Needs you"
        }
    }

    var offersPause: Bool { self == .working || self == .checking }
    var offersResume: Bool { self == .paused || self == .needsYou }
    var offersEdit: Bool { self != .met }

    func pillText(time: String) -> String {
        self == .needsYou || time.isEmpty ? label : "\(label) · \(time)"
    }

    private var agentState: AgentState {
        switch self {
        case .working, .checking: .running
        case .met: .done
        case .paused: .idle
        case .needsYou: .attention
        }
    }

    @MainActor var color: Color { agentState.textColor }
    @MainActor var markColor: Color { agentState.color }
    @MainActor var tint: Color { agentState.tint ?? Color.nw.bgSelected }
}

public enum NWGoalSize: Equatable, Sendable {
    case desktop, touch

    public var cardHeight: CGFloat { self == .desktop ? NWGoalMetrics.desktopHeight : NWGoalMetrics.touchHeight }
    public var headerHeight: CGFloat { self == .desktop ? NWGoalMetrics.desktopHeaderHeight : NWGoalMetrics.touchHeaderHeight }
    public var radius: CGFloat { self == .desktop ? NWGoalMetrics.desktopRadius : NWGoalMetrics.touchRadius }
    public var pillHeight: CGFloat { self == .desktop ? NWGoalMetrics.desktopPillHeight : NWGoalMetrics.touchPillHeight }
    public var actionSize: CGFloat { self == .desktop ? NWGoalMetrics.desktopActionSize : NWGoalMetrics.touchActionSize }
    public var hitTarget: CGFloat {
        #if os(iOS)
        NW.Height.touch
        #else
        self == .desktop ? actionSize : NW.Height.touch
        #endif
    }
    public var textLines: Int { self == .desktop ? 1 : 2 }

    var labelFont: CGFloat { self == .desktop ? NWGoalMetrics.desktopLabelFont : NWGoalMetrics.touchLabelFont }
    var textFont: CGFloat { self == .desktop ? NWGoalMetrics.desktopTextFont : NWGoalMetrics.touchTextFont }
    var pillFont: CGFloat { self == .desktop ? NWGoalMetrics.desktopPillFont : NWGoalMetrics.touchPillFont }
    var actionGlyph: CGFloat { self == .desktop ? NWGoalMetrics.desktopActionGlyph : NWGoalMetrics.touchActionGlyph }
    var resumeFont: CGFloat { self == .desktop ? NWGoalMetrics.desktopResumeFont : NWGoalMetrics.touchResumeFont }
    var resumePadding: CGFloat { self == .desktop ? NWGoalMetrics.desktopResumePadding : NWGoalMetrics.touchResumePadding }
    var resumeRadius: CGFloat { self == .desktop ? NW.Radius.s : NW.Radius.m }
    var leadingInset: CGFloat { self == .desktop ? NW.Space.l : NWGoalMetrics.textInset }
    var trailingInset: CGFloat { self == .desktop ? NW.Space.s : NW.Space.xs }
    var actionTopInset: CGFloat { min((hitTarget - actionSize) / 2, (headerHeight - actionSize) / 2) }
    func actionOffset(scale: CGFloat) -> CGFloat { max(0, (headerHeight * scale - actionSize) / 2 - actionTopInset) }
}

/// Goal card, MobileGoal and iPadGoal: shared anatomy that grows with text size.
public enum NWGoalMetrics {
    public static let desktopHeight: CGFloat = 70
    public static let touchHeight: CGFloat = 92
    public static let desktopHeaderHeight: CGFloat = 32
    public static let touchHeaderHeight: CGFloat = 40
    public static let desktopRadius: CGFloat = 10
    public static let touchRadius: CGFloat = NW.Radius.l
    public static let desktopPillHeight: CGFloat = 20
    public static let touchPillHeight: CGFloat = 24
    public static let desktopActionSize: CGFloat = NW.Height.controlS
    public static let touchActionSize: CGFloat = 34
    public static let glyph: CGFloat = 13
    public static let glyphStroke: CGFloat = glyph * 1.5 / 16
    public static let dot: CGFloat = 6
    public static let statusGlyph: CGFloat = 11
    public static let pauseGlyph: CGFloat = 10
    public static let spinnerStroke: CGFloat = 1.375
    public static let desktopActionGlyph: CGFloat = 14
    public static let touchActionGlyph: CGFloat = 16
    public static let textInset: CGFloat = 14
    public static let desktopLabelFont: CGFloat = 12
    public static let touchLabelFont: CGFloat = 13
    public static let desktopTextFont: CGFloat = 13
    public static let touchTextFont: CGFloat = 14
    public static let desktopPillFont: CGFloat = 10.5
    public static let touchPillFont: CGFloat = 11.5
    public static let metaFont: CGFloat = 11
    public static let desktopResumeFont: CGFloat = 12
    public static let touchResumeFont: CGFloat = 13.5
    public static let desktopResumePadding: CGFloat = 10
    public static let touchResumePadding: CGFloat = 14
}

/// The condition above the composer. Unframed, it is the first section of the shared dock,
/// above Subagents and Up next; the caller draws that dock's fill, border and separators.
public struct NWGoalCard: View {
    let state: NWGoalState
    let time: String
    let meta: String
    let text: String
    let size: NWGoalSize
    let framed: Bool
    let resumeEnabled: Bool
    let confirmationRequired: Bool
    let checkedBy: String?
    let confirmedByUser: Bool
    let clockStart: Date?
    @ScaledMetric(relativeTo: .body) private var dynamicScale = 1
    let pause: () -> Void
    let resume: () -> Void
    let edit: () -> Void
    let clear: () -> Void

    public init(state: NWGoalState, time: String, meta: String, text: String,
                size: NWGoalSize = .desktop, framed: Bool = true, resumeEnabled: Bool = true,
                confirmationRequired: Bool = false, checkedBy: String? = nil, confirmedByUser: Bool = false,
                clockStart: Date? = nil,
                pause: @escaping () -> Void, resume: @escaping () -> Void,
                edit: @escaping () -> Void, clear: @escaping () -> Void) {
        self.state = state
        self.time = time
        self.meta = meta
        self.text = text
        self.size = size
        self.framed = framed
        self.resumeEnabled = resumeEnabled
        self.confirmationRequired = confirmationRequired
        self.checkedBy = checkedBy
        self.confirmedByUser = confirmedByUser
        self.clockStart = clockStart
        self.pause = pause
        self.resume = resume
        self.edit = edit
        self.clear = clear
    }

    public var body: some View {
        let _ = NWRenderProbe.tick("goal.card")
        let scale = max(1, ThemeStore.shared.textScale * dynamicScale)
        VStack(spacing: 0) {
            NWGoalCardHeader(state: state, time: time, meta: meta, size: size, scale: scale,
                             resumeEnabled: resumeEnabled, confirmationRequired: confirmationRequired,
                             clockStart: clockStart, pause: pause, resume: resume, edit: edit, clear: clear)
            VStack(alignment: .leading, spacing: 0) {
                Text(text)
                    .help(text)
                    .font(.nwSans(size.textFont))
                    .foregroundStyle(Color.nw.textPrimary)
                    .lineLimit(size.textLines)
                    .truncationMode(.tail)
                    .padding(.top, max(NW.Space.m * scale, size.hitTarget - size.headerHeight * scale))
                    .padding(.bottom, NW.Space.m * scale)
                    .frame(maxWidth: .infinity, minHeight: (size.cardHeight - size.headerHeight) * scale, alignment: .leading)
                let touchConfirmation = size == .touch && state == .needsYou && confirmationRequired
                if touchConfirmation || checkedBy != nil || confirmedByUser {
                    VStack(alignment: .leading, spacing: NW.Space.s) {
                        if touchConfirmation {
                            Text("looks met, evidence incomplete, confirm")
                                .font(.nw(.caption))
                                .foregroundStyle(AgentState.attention.textColor)
                        }
                        if let checkedBy { Text("Checked by \(checkedBy)") }
                        if confirmedByUser { Text("Confirmed by you") }
                    }
                    .font(.nwMono(NWGoalMetrics.metaFont))
                    .foregroundStyle(Color.nw.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, NW.Space.m * scale)
                }
            }
            .padding(.horizontal, NWGoalMetrics.textInset)
            .overlay(alignment: .top) { NWHairline() }
        }
        .background(framed ? Color.nw.bgRaised : .clear, in: RoundedRectangle(cornerRadius: size.radius))
        .nwBorder(framed ? Color.nw.lineStrong : .clear, radius: size.radius)
        .contentShape(RoundedRectangle(cornerRadius: size.radius))
        .contextMenu {
            if size == .touch {
                if !meta.isEmpty { Text(meta) }
                if state.offersPause { Button("Pause goal", systemImage: "pause", action: pause) }
                if state.offersResume {
                    if state == .needsYou && confirmationRequired {
                        Button("Confirm goal", action: resume)
                            .disabled(!resumeEnabled)
                            .help(NWGoalState.confirmationExplanation)
                            .accessibilityHint(NWGoalState.confirmationExplanation)
                    } else {
                        Button("Resume goal", systemImage: "play", action: resume).disabled(!resumeEnabled)
                    }
                }
                if state.offersEdit { Button("Edit goal", systemImage: "pencil", action: edit) }
                Button("Clear goal", systemImage: "xmark", action: clear)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct NWGoalCardHeader: View {
    let state: NWGoalState
    let time: String
    let meta: String
    let size: NWGoalSize
    let scale: CGFloat
    let resumeEnabled: Bool
    let confirmationRequired: Bool
    let clockStart: Date?
    let pause: () -> Void
    let resume: () -> Void
    let edit: () -> Void
    let clear: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: NW.Space.m) {
                heading
                if size == .desktop { metadata }
                else if state.offersResume { Spacer(minLength: 0) }
                actions
            }
            .frame(height: size.headerHeight * scale, alignment: .top)
            VStack(alignment: .leading, spacing: 0) {
                heading
                HStack(alignment: .top, spacing: NW.Space.m) {
                    if size == .desktop { metadata } else { Spacer(minLength: 0) }
                    actions
                }
                .frame(height: size.headerHeight * scale, alignment: .top)
            }
        }
        .padding(.leading, size.leadingInset)
        .padding(.trailing, size.trailingInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var heading: some View {
        HStack(spacing: NW.Space.m) {
            NWGoalGlyph().foregroundStyle(Color.nw.textSecondary)
            Text("Goal").font(.nwSans(size.labelFont, .semibold)).foregroundStyle(Color.nw.textSecondary)
            NWGoalPill(state: state, time: time, size: size, clockStart: clockStart)
        }
        .fixedSize(horizontal: true, vertical: false)
        .frame(minHeight: size.headerHeight * scale)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityHint(size == .touch ? meta : "")
    }

    private var metadata: some View {
        Text(meta).font(.nwMono(NWGoalMetrics.metaFont)).foregroundStyle(Color.nw.textTertiary)
            .lineLimit(1).truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, NW.Space.s)
            .help(meta)
            .frame(minHeight: size.headerHeight * scale)
    }

    @ViewBuilder private var actions: some View {
        if state.offersResume {
            let confirming = state == .needsYou && confirmationRequired
            Button(confirming ? "Confirm" : "Resume", action: resume)
                .buttonStyle(NWGoalActionStyle(size: size, icon: false))
                .padding(.top, size.actionOffset(scale: scale))
                .disabled(!resumeEnabled)
                .help(confirming ? NWGoalState.confirmationExplanation : "Resume goal")
                .accessibilityHint(confirming ? NWGoalState.confirmationExplanation : "")
                .accessibilityLabel(confirming ? "Confirm goal" : "Resume goal")
        }
        if state.offersPause { NWGoalIconButton(symbol: "pause", label: "Pause goal", size: size, action: pause) }
        if size == .desktop && state.offersEdit {
            NWGoalIconButton(symbol: "pencil", label: "Edit goal", size: size, action: edit)
        }
        NWGoalIconButton(symbol: "xmark", label: "Clear goal", size: size, action: clear)
    }
}

/// Working pulses, Checking spins, and the other states stay legible without motion.
/// The existing layer indicators honor Reduce Motion and `nwMotionPaused` without frame ticks.
public struct NWGoalPill: View {
    let state: NWGoalState
    let time: String
    let size: NWGoalSize
    @ScaledMetric(relativeTo: .body) private var dynamicScale = 1

    let clockStart: Date?

    public init(state: NWGoalState, time: String, size: NWGoalSize = .desktop, clockStart: Date? = nil) {
        self.state = state
        self.time = time
        self.size = size
        self.clockStart = clockStart
    }

    public var body: some View {
        if let clockStart, state.offersPause {
            TimelineView(NWElapsedSchedule(start: clockStart, style: .long)) { context in
                let _ = NWRenderProbe.tick("goal.clock")
                pill(time: NWGoalTime.text(context.date.timeIntervalSince(clockStart)))
            }
        } else {
            pill(time: time)
        }
    }

    private func pill(time: String) -> some View {
        HStack(spacing: NW.Space.s) {
            NWGoalStatusMark(state: state)
                .frame(width: state.offersPause ? NWGoalMetrics.statusGlyph : nil)
            Text(state.offersPause ? NWGoalState.checking.pillText(time: time) : state.pillText(time: time))
                .hidden()
                .overlay(alignment: .leading) { Text(state.pillText(time: time)) }
                .font(.nwMono(size.pillFont)).monospacedDigit()
        }
        .foregroundStyle(state.color)
        .padding(.horizontal, NW.Space.m)
        .frame(height: size.pillHeight * max(1, ThemeStore.shared.textScale * dynamicScale))
        .background(state.tint, in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.pillText(time: time))
    }
}

/// The compact "Goal · time" marker in a thread's header.
public struct NWGoalHeaderPill: View {
    let time: String

    let clockStart: Date?

    public init(time: String, clockStart: Date? = nil) {
        self.time = time
        self.clockStart = clockStart
    }

    public var body: some View {
        if let clockStart {
            TimelineView(NWElapsedSchedule(start: clockStart, style: .long)) { context in
                let _ = NWRenderProbe.tick("goal.headerClock")
                pill(time: NWGoalTime.text(context.date.timeIntervalSince(clockStart)))
            }
        } else {
            pill(time: time)
        }
    }

    private func pill(time: String) -> some View {
        HStack(spacing: NW.Space.s) {
            NWGoalGlyph()
            Text(time.isEmpty ? "Goal" : "Goal · \(time)").font(.nwMono(NWGoalMetrics.desktopPillFont)).monospacedDigit()
        }
        .foregroundStyle(AgentState.running.textColor)
        .padding(.horizontal, NW.Space.m)
        .frame(height: NWGoalMetrics.desktopPillHeight)
        .background(AgentState.running.tint ?? .clear, in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// Goal clocks retain the native goal's unpadded minutes/seconds copy, not NWDuration's row copy.
enum NWGoalTime {
    static func text(_ elapsed: TimeInterval) -> String {
        let seconds = Int(min(max(elapsed, 0), Double(Int.max / 2)))
        if seconds >= 3600 { return "\(seconds / 3600)h \(seconds % 3600 / 60)m" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }
}

/// Shared editor values keep macOS inline and iOS sheet validation identical.
public struct NWGoalLimits: Equatable, Sendable {
    public var minutes: String
    public var tokens: String
    private let originalSeconds: Double?
    private let originalMinutes: String

    public init(seconds: Double?, tokens: Int?) {
        originalSeconds = seconds
        originalMinutes = seconds.map { String($0 / 60) } ?? ""
        minutes = originalMinutes
        self.tokens = tokens.map(String.init) ?? ""
    }

    public var seconds: Double? {
        // Preserve an untouched cap exactly across seconds/minutes floating-point conversion.
        minutes == originalMinutes ? originalSeconds : Double(minutes.trimmingCharacters(in: .whitespacesAndNewlines)).map { $0 * 60 }
    }
    public var tokenLimit: Int? { Int(tokens.trimmingCharacters(in: .whitespacesAndNewlines)) }
    public var clearsTime: Bool { minutes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var clearsTokens: Bool { tokens.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var isValid: Bool {
        (clearsTime || seconds.map { $0.isFinite && $0 > 0 } == true)
            && (clearsTokens || tokenLimit.map { $0 > 0 } == true)
    }
}

public struct NWGoalLimitFields: View {
    @Binding var limits: NWGoalLimits

    public init(limits: Binding<NWGoalLimits>) { _limits = limits }

    public var body: some View {
        VStack(alignment: .leading, spacing: NW.Space.s) {
            field("Time limit (minutes)", text: $limits.minutes)
            field("Token budget", text: $limits.tokens)
        }
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: NW.Space.xs) {
            Text(label).font(.nw(.caption)).foregroundStyle(Color.nw.textSecondary).accessibilityHidden(true)
            TextField("No limit", text: text)
                .textFieldStyle(.plain)
                .font(.nw(.mono))
                .foregroundStyle(Color.nw.textPrimary)
                .padding(NW.Space.s)
                .background(Color.nw.bgSunken, in: RoundedRectangle(cornerRadius: NW.Radius.s))
                .nwBorder(Color.nw.lineSubtle, radius: NW.Radius.s)
                .accessibilityLabel(label)
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
        }
    }
}

private struct NWGoalStatusMark: View {
    let state: NWGoalState

    var body: some View {
        Group {
            switch state {
            case .working:
                NWLayerGlowDot(color: state.markColor).frame(width: NWGoalMetrics.dot, height: NWGoalMetrics.dot)
            case .checking:
                NWLayerSpinner(size: NWGoalMetrics.statusGlyph, color: state.markColor, lineWidth: NWGoalMetrics.spinnerStroke)
            case .met:
                Image(systemName: "checkmark").font(.system(size: NWGoalMetrics.statusGlyph, weight: .semibold))
            case .paused:
                Image(systemName: "pause").font(.system(size: NWGoalMetrics.pauseGlyph, weight: .semibold))
            case .needsYou:
                NWLayerGlowDot(color: state.markColor).frame(width: NWGoalMetrics.dot, height: NWGoalMetrics.dot)
            }
        }
        .foregroundStyle(state.markColor)
        .symbolRenderingMode(.monochrome)
        .accessibilityHidden(true)
    }
}

/// Two stroked rings, rather than SF's target with a third ring or a filled center.
public struct NWGoalGlyph: View {
    public init() {}

    public var body: some View {
        NWGoalRings().stroke(lineWidth: NWGoalMetrics.glyphStroke)
            .frame(width: NWGoalMetrics.glyph, height: NWGoalMetrics.glyph)
            .accessibilityHidden(true)
    }
}

private struct NWGoalRings: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 16
        var path = Path()
        for radius in [6.0, 2.4] {
            path.addEllipse(in: CGRect(x: rect.midX - radius * unit, y: rect.midY - radius * unit,
                                       width: 2 * radius * unit, height: 2 * radius * unit))
        }
        return path
    }
}

private struct NWGoalIconButton: View {
    let symbol: String
    let label: String
    let size: NWGoalSize
    let action: () -> Void
    @ScaledMetric(relativeTo: .body) private var dynamicScale = 1

    var body: some View {
        let scale = max(1, ThemeStore.shared.textScale * dynamicScale)
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(NWGoalActionStyle(size: size, icon: true))
            .padding(.top, size.actionOffset(scale: scale))
            .help(label)
            .accessibilityLabel(label)
    }
}

/// Touch retains the board's 34pt chrome inside a nonoverlapping 44pt rectangular hit area,
/// including in desktop previews of the touch size. At the base size the extra hit height
/// extends into the body's padding, never outside the card.
private struct NWGoalActionStyle: ButtonStyle {
    let size: NWGoalSize
    let icon: Bool

    func makeBody(configuration: Configuration) -> some View {
        NWGoalAction(configuration: configuration, size: size, icon: icon)
    }
}

private struct NWGoalAction: View {
    let configuration: ButtonStyleConfiguration
    let size: NWGoalSize
    let icon: Bool
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        let active = enabled && (hovering || configuration.isPressed)
        let radius = icon ? size.actionSize / 2 : size.resumeRadius
        configuration.label
            .font(icon ? .system(size: size.actionGlyph, weight: .medium) : .nwSans(size.resumeFont, .medium))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(icon && !active ? Color.nw.textSecondary : Color.nw.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, icon ? 0 : size.resumePadding)
            .frame(minWidth: size.actionSize, minHeight: size.actionSize)
            .background(active ? Color.nw.bgSelected : icon ? .clear : Color.nw.bgBubble,
                        in: RoundedRectangle(cornerRadius: radius))
            .nwBorder(icon ? .clear : Color.nw.lineStrong, radius: radius)
            .nwFocusRing(radius: radius)
            .padding(.top, size.actionTopInset)
            .padding(.bottom, size.hitTarget - size.actionSize - size.actionTopInset)
            .padding(.horizontal, icon ? (size.hitTarget - size.actionSize) / 2 : 0)
            .contentShape(Rectangle())
            .nwEnabledOpacity(enabled)
            .onHover { hovering = $0 }
            .nwAnimation(.hover, value: hovering)
    }
}
