import SwiftUI

/// The goal's presentation, independent of an agent's turn or the goal runner.
public enum NWGoalState: CaseIterable, Equatable, Sendable {
    case working, checking, met, paused, needsYou

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

    @MainActor var color: Color {
        switch self {
        case .working, .checking: Color.nw.running
        case .met: Color.nw.done
        case .paused: Color.nw.textSecondary
        case .needsYou: Color.nw.lantern
        }
    }

    @MainActor var tint: Color { color.opacity(NWGoalMetrics.tintOpacity) }
}

public enum NWGoalSize: Equatable, Sendable {
    case desktop, touch

    public var cardHeight: CGFloat { self == .desktop ? NWGoalMetrics.desktopHeight : NWGoalMetrics.touchHeight }
    public var headerHeight: CGFloat { self == .desktop ? NWGoalMetrics.desktopHeaderHeight : NWGoalMetrics.touchHeaderHeight }
    public var radius: CGFloat { self == .desktop ? NWGoalMetrics.desktopRadius : NWGoalMetrics.touchRadius }
    public var pillHeight: CGFloat { self == .desktop ? NWGoalMetrics.desktopPillHeight : NWGoalMetrics.touchPillHeight }
    public var actionSize: CGFloat { self == .desktop ? NWGoalMetrics.desktopActionSize : NWGoalMetrics.touchActionSize }
    public var hitTarget: CGFloat { self == .desktop ? actionSize : NW.Height.touch }
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
}

/// GoalStates: the card keeps a flexible width and a fixed desktop/touch anatomy.
public enum NWGoalMetrics {
    public static let tintOpacity: Double = 0.12
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
    let pause: () -> Void
    let resume: () -> Void
    let edit: () -> Void
    let clear: () -> Void

    public init(state: NWGoalState, time: String, meta: String, text: String,
                size: NWGoalSize = .desktop, framed: Bool = true,
                pause: @escaping () -> Void, resume: @escaping () -> Void,
                edit: @escaping () -> Void, clear: @escaping () -> Void) {
        self.state = state
        self.time = time
        self.meta = meta
        self.text = text
        self.size = size
        self.framed = framed
        self.pause = pause
        self.resume = resume
        self.edit = edit
        self.clear = clear
    }

    public var body: some View {
        VStack(spacing: 0) {
            NWGoalCardHeader(state: state, time: time, meta: meta, size: size,
                             pause: pause, resume: resume, edit: edit, clear: clear)
            Text(text)
                .help(text)
                .font(.nwSans(size.textFont))
                .foregroundStyle(Color.nw.textPrimary)
                .lineLimit(size.textLines)
                .truncationMode(.tail)
                .padding(.horizontal, NWGoalMetrics.textInset)
                .frame(maxWidth: .infinity, minHeight: size.cardHeight - size.headerHeight, alignment: .leading)
                .overlay(alignment: .top) { NWHairline() }
        }
        .background(framed ? Color.nw.bgRaised : .clear, in: RoundedRectangle(cornerRadius: size.radius))
        .nwBorder(framed ? Color.nw.lineStrong : .clear, radius: size.radius)
        .contentShape(RoundedRectangle(cornerRadius: size.radius))
        .contextMenu {
            if size == .touch {
                if !meta.isEmpty { Text(meta) }
                if state.offersPause { Button("Pause goal", systemImage: "pause", action: pause) }
                if state.offersResume { Button("Resume goal", systemImage: "play", action: resume) }
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
    let pause: () -> Void
    let resume: () -> Void
    let edit: () -> Void
    let clear: () -> Void

    var body: some View {
        HStack(spacing: NW.Space.m) {
            HStack(spacing: NW.Space.m) {
                NWGoalGlyph().foregroundStyle(Color.nw.textSecondary)
                Text("Goal").font(.nwSans(size.labelFont, .semibold)).foregroundStyle(Color.nw.textSecondary)
                NWGoalPill(state: state, time: time, size: size)
            }
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .accessibilityHint(size == .touch ? meta : "")
            if size == .desktop {
                Text(meta).font(.nwMono(NWGoalMetrics.metaFont)).foregroundStyle(Color.nw.textTertiary)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, NW.Space.s)
                    .help(meta)
            } else if state.offersResume {
                Spacer(minLength: 0)
            }
            if state.offersResume {
                Button("Resume", action: resume)
                    .buttonStyle(NWGoalActionStyle(size: size, icon: false))
                    .help("Resume goal")
                    .accessibilityLabel("Resume goal")
            }
            if state.offersPause { NWGoalIconButton(symbol: "pause", label: "Pause goal", size: size, action: pause) }
            if size == .desktop && state.offersEdit {
                NWGoalIconButton(symbol: "pencil", label: "Edit goal", size: size, action: edit)
            }
            NWGoalIconButton(symbol: "xmark", label: "Clear goal", size: size, action: clear)
        }
        .padding(.leading, size.leadingInset)
        .padding(.trailing, size.trailingInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: size.headerHeight)
    }
}

/// Working pulses, Checking spins, and the other states stay legible without motion.
/// The existing layer indicators honor Reduce Motion and `nwMotionPaused` without frame ticks.
public struct NWGoalPill: View {
    let state: NWGoalState
    let time: String
    let size: NWGoalSize

    public init(state: NWGoalState, time: String, size: NWGoalSize = .desktop) {
        self.state = state
        self.time = time
        self.size = size
    }

    public var body: some View {
        HStack(spacing: NW.Space.s) {
            NWGoalStatusMark(state: state)
            Text(state.pillText(time: time)).font(.nwMono(size.pillFont)).monospacedDigit()
        }
        .foregroundStyle(state.color)
        .padding(.horizontal, NW.Space.m)
        .frame(height: size.pillHeight)
        .background(state.tint, in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.pillText(time: time))
    }
}

/// The compact "Goal · time" marker in a thread's header.
public struct NWGoalHeaderPill: View {
    let time: String

    public init(time: String) { self.time = time }

    public var body: some View {
        HStack(spacing: NW.Space.s) {
            NWGoalGlyph()
            Text(time.isEmpty ? "Goal" : "Goal · \(time)").font(.nwMono(NWGoalMetrics.desktopPillFont)).monospacedDigit()
        }
        .foregroundStyle(Color.nw.running)
        .padding(.horizontal, NW.Space.m)
        .frame(height: NWGoalMetrics.desktopPillHeight)
        .background(Color.nw.running.opacity(NWGoalMetrics.tintOpacity), in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

private struct NWGoalStatusMark: View {
    let state: NWGoalState

    var body: some View {
        Group {
            switch state {
            case .working:
                NWLayerGlowDot(color: state.color).frame(width: NWGoalMetrics.dot, height: NWGoalMetrics.dot)
            case .checking:
                NWLayerSpinner(size: NWGoalMetrics.statusGlyph, color: state.color, lineWidth: NWGoalMetrics.spinnerStroke)
            case .met:
                Image(systemName: "checkmark").font(.system(size: NWGoalMetrics.statusGlyph, weight: .semibold))
            case .paused:
                Image(systemName: "pause").font(.system(size: NWGoalMetrics.pauseGlyph, weight: .semibold))
            case .needsYou:
                NWLayerGlowDot(color: state.color).frame(width: NWGoalMetrics.dot, height: NWGoalMetrics.dot)
            }
        }
        .symbolRenderingMode(.monochrome)
        .accessibilityHidden(true)
    }
}

/// Two stroked rings, rather than SF's target with a third ring or a filled center.
private struct NWGoalGlyph: View {
    var body: some View {
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

    var body: some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(NWGoalActionStyle(size: size, icon: true))
            .help(label)
            .accessibilityLabel(label)
    }
}

/// Touch retains the board's 34pt chrome inside a nonoverlapping 44pt rectangular hit area,
/// including in desktop previews of the touch size. The 40pt header permits a 2pt overhang.
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
            .padding(.vertical, (size.hitTarget - size.actionSize) / 2)
            .padding(.horizontal, icon ? (size.hitTarget - size.actionSize) / 2 : 0)
            .contentShape(Rectangle())
            .nwEnabledOpacity(enabled)
            .onHover { hovering = $0 }
            .nwAnimation(.hover, value: hovering)
    }
}
