import SwiftUI

/// The goal's presentation, independent of an agent's turn or the goal runner.
public enum SHGoalState: CaseIterable, Equatable, Sendable {
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
    @MainActor var tint: Color { agentState.tint ?? Color.sh.bgSelected }
}

public enum SHGoalSize: Equatable, Sendable {
    case desktop, touch

    public var cardHeight: CGFloat { self == .desktop ? SHGoalMetrics.desktopHeight : SHGoalMetrics.touchHeight }
    public var headerHeight: CGFloat { self == .desktop ? SHGoalMetrics.desktopHeaderHeight : SHGoalMetrics.touchHeaderHeight }
    public var radius: CGFloat { self == .desktop ? SHGoalMetrics.desktopRadius : SHGoalMetrics.touchRadius }
    public var pillHeight: CGFloat { self == .desktop ? SHGoalMetrics.desktopPillHeight : SHGoalMetrics.touchPillHeight }
    public var actionSize: CGFloat { self == .desktop ? SHGoalMetrics.desktopActionSize : SHGoalMetrics.touchActionSize }
    public var hitTarget: CGFloat {
        #if os(iOS)
        SH.Height.touch
        #else
        self == .desktop ? actionSize : SH.Height.touch
        #endif
    }
    public var textLines: Int { self == .desktop ? 1 : 2 }

    var labelFont: CGFloat { self == .desktop ? SHGoalMetrics.desktopLabelFont : SHGoalMetrics.touchLabelFont }
    var textFont: CGFloat { self == .desktop ? SHGoalMetrics.desktopTextFont : SHGoalMetrics.touchTextFont }
    var pillFont: CGFloat { self == .desktop ? SHGoalMetrics.desktopPillFont : SHGoalMetrics.touchPillFont }
    var actionGlyph: CGFloat { self == .desktop ? SHGoalMetrics.desktopActionGlyph : SHGoalMetrics.touchActionGlyph }
    var resumeFont: CGFloat { self == .desktop ? SHGoalMetrics.desktopResumeFont : SHGoalMetrics.touchResumeFont }
    var resumePadding: CGFloat { self == .desktop ? SHGoalMetrics.desktopResumePadding : SHGoalMetrics.touchResumePadding }
    var resumeRadius: CGFloat { self == .desktop ? SH.Radius.s : SH.Radius.m }
    var leadingInset: CGFloat { self == .desktop ? SH.Space.l : SHGoalMetrics.textInset }
    var trailingInset: CGFloat { self == .desktop ? SH.Space.s : SH.Space.xs }
    var actionTopInset: CGFloat { min((hitTarget - actionSize) / 2, (headerHeight - actionSize) / 2) }
    func actionOffset(scale: CGFloat) -> CGFloat { max(0, (headerHeight * scale - actionSize) / 2 - actionTopInset) }
}

/// Goal card, MobileGoal and iPadGoal: shared anatomy that grows with text size.
public enum SHGoalMetrics {
    public static let desktopHeight: CGFloat = 70
    public static let touchHeight: CGFloat = 92
    public static let desktopHeaderHeight: CGFloat = 32
    public static let touchHeaderHeight: CGFloat = 40
    public static let desktopRadius: CGFloat = 10
    public static let touchRadius: CGFloat = SH.Radius.l
    public static let desktopPillHeight: CGFloat = 20
    public static let touchPillHeight: CGFloat = 24
    public static let desktopActionSize: CGFloat = SH.Height.controlS
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
public struct SHGoalCard: View {
    let state: SHGoalState
    let time: String
    let meta: String
    let text: String
    let size: SHGoalSize
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

    public init(state: SHGoalState, time: String, meta: String, text: String,
                size: SHGoalSize = .desktop, framed: Bool = true, resumeEnabled: Bool = true,
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
        let _ = SHRenderProbe.tick("goal.card")
        let scale = max(1, ThemeStore.shared.textScale * dynamicScale)
        VStack(spacing: 0) {
            SHGoalCardHeader(state: state, time: time, meta: meta, size: size, scale: scale,
                             resumeEnabled: resumeEnabled, confirmationRequired: confirmationRequired,
                             clockStart: clockStart, pause: pause, resume: resume, edit: edit, clear: clear)
            VStack(alignment: .leading, spacing: 0) {
                Text(text)
                    .help(text)
                    .font(.shSans(size.textFont))
                    .foregroundStyle(Color.sh.textPrimary)
                    .lineLimit(size.textLines)
                    .truncationMode(.tail)
                    .padding(.top, max(SH.Space.m * scale, size.hitTarget - size.headerHeight * scale))
                    .padding(.bottom, SH.Space.m * scale)
                    .frame(maxWidth: .infinity, minHeight: (size.cardHeight - size.headerHeight) * scale, alignment: .leading)
                let touchConfirmation = size == .touch && state == .needsYou && confirmationRequired
                if touchConfirmation || checkedBy != nil || confirmedByUser {
                    VStack(alignment: .leading, spacing: SH.Space.s) {
                        if touchConfirmation {
                            Text("looks met, evidence incomplete, confirm")
                                .font(.sh(.caption))
                                .foregroundStyle(AgentState.attention.textColor)
                        }
                        if let checkedBy { Text("Checked by \(checkedBy)") }
                        if confirmedByUser { Text("Confirmed by you") }
                    }
                    .font(.shMono(SHGoalMetrics.metaFont))
                    .foregroundStyle(Color.sh.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, SH.Space.m * scale)
                }
            }
            .padding(.horizontal, SHGoalMetrics.textInset)
            .overlay(alignment: .top) { SHHairline() }
        }
        .background(framed ? Color.sh.bgRaised : .clear, in: RoundedRectangle(cornerRadius: size.radius))
        .shBorder(framed ? Color.sh.lineStrong : .clear, radius: size.radius)
        .contentShape(RoundedRectangle(cornerRadius: size.radius))
        .contextMenu {
            if size == .touch {
                if !meta.isEmpty { Text(meta) }
                if state.offersPause { Button("Pause goal", systemImage: "pause", action: pause) }
                if state.offersResume {
                    if state == .needsYou && confirmationRequired {
                        Button("Confirm goal", action: resume)
                            .disabled(!resumeEnabled)
                            .help(SHGoalState.confirmationExplanation)
                            .accessibilityHint(SHGoalState.confirmationExplanation)
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

private struct SHGoalCardHeader: View {
    let state: SHGoalState
    let time: String
    let meta: String
    let size: SHGoalSize
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
            HStack(alignment: .top, spacing: SH.Space.m) {
                heading
                if size == .desktop { metadata }
                else if state.offersResume { Spacer(minLength: 0) }
                actions
            }
            .frame(height: size.headerHeight * scale, alignment: .top)
            VStack(alignment: .leading, spacing: 0) {
                heading
                HStack(alignment: .top, spacing: SH.Space.m) {
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
        HStack(spacing: SH.Space.m) {
            SHGoalGlyph().foregroundStyle(Color.sh.textSecondary)
            Text("Goal").font(.shSans(size.labelFont, .semibold)).foregroundStyle(Color.sh.textSecondary)
            SHGoalPill(state: state, time: time, size: size, clockStart: clockStart)
        }
        .fixedSize(horizontal: true, vertical: false)
        .frame(minHeight: size.headerHeight * scale)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityHint(size == .touch ? meta : "")
    }

    private var metadata: some View {
        Text(meta).font(.shMono(SHGoalMetrics.metaFont)).foregroundStyle(Color.sh.textTertiary)
            .lineLimit(1).truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, SH.Space.s)
            .help(meta)
            .frame(minHeight: size.headerHeight * scale)
    }

    @ViewBuilder private var actions: some View {
        if state.offersResume {
            let confirming = state == .needsYou && confirmationRequired
            Button(confirming ? "Confirm" : "Resume", action: resume)
                .buttonStyle(SHGoalActionStyle(size: size, icon: false))
                .padding(.top, size.actionOffset(scale: scale))
                .disabled(!resumeEnabled)
                .help(confirming ? SHGoalState.confirmationExplanation : "Resume goal")
                .accessibilityHint(confirming ? SHGoalState.confirmationExplanation : "")
                .accessibilityLabel(confirming ? "Confirm goal" : "Resume goal")
        }
        if state.offersPause { SHGoalIconButton(symbol: "pause", label: "Pause goal", size: size, action: pause) }
        if size == .desktop && state.offersEdit {
            SHGoalIconButton(symbol: "pencil", label: "Edit goal", size: size, action: edit)
        }
        SHGoalIconButton(symbol: "xmark", label: "Clear goal", size: size, action: clear)
    }
}

/// Working pulses, Checking spins, and the other states stay legible without motion.
/// The existing layer indicators honor Reduce Motion and `shMotionPaused` without frame ticks.
public struct SHGoalPill: View {
    let state: SHGoalState
    let time: String
    let size: SHGoalSize
    @ScaledMetric(relativeTo: .body) private var dynamicScale = 1

    let clockStart: Date?

    public init(state: SHGoalState, time: String, size: SHGoalSize = .desktop, clockStart: Date? = nil) {
        self.state = state
        self.time = time
        self.size = size
        self.clockStart = clockStart
    }

    public var body: some View {
        if let clockStart, state.offersPause {
            TimelineView(SHElapsedSchedule(start: clockStart, style: .long)) { context in
                let _ = SHRenderProbe.tick("goal.clock")
                pill(time: SHGoalTime.text(context.date.timeIntervalSince(clockStart)))
            }
        } else {
            pill(time: time)
        }
    }

    private func pill(time: String) -> some View {
        HStack(spacing: SH.Space.s) {
            SHGoalStatusMark(state: state)
                .frame(width: state.offersPause ? SHGoalMetrics.statusGlyph : nil)
            Text(state.offersPause ? SHGoalState.checking.pillText(time: time) : state.pillText(time: time))
                .hidden()
                .overlay(alignment: .leading) { Text(state.pillText(time: time)) }
                .font(.shMono(size.pillFont)).monospacedDigit()
        }
        .foregroundStyle(state.color)
        .padding(.horizontal, SH.Space.m)
        .frame(height: size.pillHeight * max(1, ThemeStore.shared.textScale * dynamicScale))
        .background(state.tint, in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.pillText(time: time))
    }
}

/// The compact "Goal · time" marker in a thread's header.
public struct SHGoalHeaderPill: View {
    let time: String

    let clockStart: Date?

    public init(time: String, clockStart: Date? = nil) {
        self.time = time
        self.clockStart = clockStart
    }

    public var body: some View {
        if let clockStart {
            TimelineView(SHElapsedSchedule(start: clockStart, style: .long)) { context in
                let _ = SHRenderProbe.tick("goal.headerClock")
                pill(time: SHGoalTime.text(context.date.timeIntervalSince(clockStart)))
            }
        } else {
            pill(time: time)
        }
    }

    private func pill(time: String) -> some View {
        HStack(spacing: SH.Space.s) {
            SHGoalGlyph()
            Text(time.isEmpty ? "Goal" : "Goal · \(time)").font(.shMono(SHGoalMetrics.desktopPillFont)).monospacedDigit()
        }
        .foregroundStyle(AgentState.running.textColor)
        .padding(.horizontal, SH.Space.m)
        .frame(height: SHGoalMetrics.desktopPillHeight)
        .background(AgentState.running.tint ?? .clear, in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// Goal clocks retain the native goal's unpadded minutes/seconds copy, not SHDuration's row copy.
enum SHGoalTime {
    static func text(_ elapsed: TimeInterval) -> String {
        let seconds = Int(min(max(elapsed, 0), Double(Int.max / 2)))
        if seconds >= 3600 { return "\(seconds / 3600)h \(seconds % 3600 / 60)m" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }
}

private struct SHGoalStatusMark: View {
    let state: SHGoalState

    var body: some View {
        Group {
            switch state {
            case .working:
                SHLayerGlowDot(color: state.markColor).frame(width: SHGoalMetrics.dot, height: SHGoalMetrics.dot)
            case .checking:
                SHLayerSpinner(size: SHGoalMetrics.statusGlyph, color: state.markColor, lineWidth: SHGoalMetrics.spinnerStroke)
            case .met:
                Image(systemName: "checkmark").font(.system(size: SHGoalMetrics.statusGlyph, weight: .semibold))
            case .paused:
                Image(systemName: "pause").font(.system(size: SHGoalMetrics.pauseGlyph, weight: .semibold))
            case .needsYou:
                SHLayerGlowDot(color: state.markColor).frame(width: SHGoalMetrics.dot, height: SHGoalMetrics.dot)
            }
        }
        .foregroundStyle(state.markColor)
        .symbolRenderingMode(.monochrome)
        .accessibilityHidden(true)
    }
}

/// Two stroked rings, rather than SF's target with a third ring or a filled center.
public struct SHGoalGlyph: View {
    public init() {}

    public var body: some View {
        SHGoalRings().stroke(lineWidth: SHGoalMetrics.glyphStroke)
            .frame(width: SHGoalMetrics.glyph, height: SHGoalMetrics.glyph)
            .accessibilityHidden(true)
    }
}

private struct SHGoalRings: Shape {
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

private struct SHGoalIconButton: View {
    let symbol: String
    let label: String
    let size: SHGoalSize
    let action: () -> Void
    @ScaledMetric(relativeTo: .body) private var dynamicScale = 1

    var body: some View {
        let scale = max(1, ThemeStore.shared.textScale * dynamicScale)
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(SHGoalActionStyle(size: size, icon: true))
            .padding(.top, size.actionOffset(scale: scale))
            .help(label)
            .accessibilityLabel(label)
    }
}

/// Touch retains the board's 34pt chrome inside a nonoverlapping 44pt rectangular hit area,
/// including in desktop previews of the touch size. At the base size the extra hit height
/// extends into the body's padding, never outside the card.
private struct SHGoalActionStyle: ButtonStyle {
    let size: SHGoalSize
    let icon: Bool

    func makeBody(configuration: Configuration) -> some View {
        SHGoalAction(configuration: configuration, size: size, icon: icon)
    }
}

private struct SHGoalAction: View {
    let configuration: ButtonStyleConfiguration
    let size: SHGoalSize
    let icon: Bool
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        let active = enabled && (hovering || configuration.isPressed)
        let radius = icon ? size.actionSize / 2 : size.resumeRadius
        configuration.label
            .font(icon ? .system(size: size.actionGlyph, weight: .medium) : .shSans(size.resumeFont, .medium))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(icon && !active ? Color.sh.textSecondary : Color.sh.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, icon ? 0 : size.resumePadding)
            .frame(minWidth: size.actionSize, minHeight: size.actionSize)
            .background(active ? Color.sh.bgSelected : icon ? .clear : Color.sh.bgBubble,
                        in: RoundedRectangle(cornerRadius: radius))
            .shBorder(icon ? .clear : Color.sh.lineStrong, radius: radius)
            .shFocusRing(radius: radius)
            .padding(.top, size.actionTopInset)
            .padding(.bottom, size.hitTarget - size.actionSize - size.actionTopInset)
            .padding(.horizontal, icon ? (size.hitTarget - size.actionSize) / 2 : 0)
            .contentShape(Rectangle())
            .shEnabledOpacity(enabled)
            .onHover { hovering = $0 }
            .shAnimation(.hover, value: hovering)
    }
}
