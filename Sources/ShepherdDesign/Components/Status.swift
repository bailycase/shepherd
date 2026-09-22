import SwiftUI

/// The agent states the chrome shows (spec §6). `needsYou` is a blocked agent or a subagent
/// waiting on the user.
public enum AgentPillState: Equatable, Sendable {
    case idle, running, needsYou, error, stopped
}

/// AgentStatusPill: dot (or spinner) + word on the state's tint.
public struct StatusPill: View {
    let state: AgentPillState
    let label: String
    var small = false

    public init(_ state: AgentPillState, label: String? = nil, small: Bool = false) {
        self.state = state
        self.label = label ?? Self.defaultLabel(state)
        self.small = small
    }

    public static func defaultLabel(_ state: AgentPillState) -> String {
        switch state {
        case .idle: "Idle"
        case .running: "Running"
        case .needsYou: "Needs you"
        case .error: "Error"
        case .stopped: "Stopped"
        }
    }

    public var body: some View {
        let (fill, text, mark): (Color, Color, Color) = switch state {
        case .idle: (Tokens.successBg, Tokens.successText, Tokens.success)
        case .running: (Tokens.accentBg, Tokens.accentText, Tokens.accent)
        case .needsYou: (Tokens.warningBg, Tokens.warningText, Tokens.warning)
        case .error: (Tokens.dangerBg, Tokens.dangerText, Tokens.danger)
        case .stopped: (Tokens.bgBubble, Tokens.textSecondary, Tokens.textMuted)
        }
        HStack(spacing: 6) {
            if state == .running {
                Spinner(size: 10, color: mark)
            } else {
                Circle().fill(mark).frame(width: 6, height: 6)
            }
            Text(label).font(Fonts.captionMedium).foregroundStyle(text).lineLimit(1).monospacedDigit()
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .padding(.vertical, small ? 2 : 3)
        .background(fill, in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}

/// StatusDot (7pt, 6pt compact).
public struct StatusDot: View {
    let color: Color
    var size: CGFloat

    public init(_ color: Color, size: CGFloat = Metrics.statusDot) {
        self.color = color
        self.size = size
    }

    public var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}

/// The running glyph: a rotating 3/4 arc. Under Reduce Motion it is a pulsing dot instead.
public struct Spinner: View {
    var size: CGFloat
    var color: Color?
    var lineWidth: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false

    public init(size: CGFloat = 12, color: Color? = nil, lineWidth: CGFloat? = nil) {
        self.size = size
        self.color = color
        self.lineWidth = lineWidth
    }

    public var body: some View {
        let tint = color ?? Tokens.accent
        Group {
            if reduceMotion {
                Circle().fill(tint).frame(width: size * 0.55, height: size * 0.55)
                    .opacity(spinning ? 0.35 : 1)
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: spinning)
            } else {
                Circle().trim(from: 0, to: 0.75)
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth ?? max(1.5, size / 7), lineCap: .round))
                    .rotationEffect(.degrees(spinning ? 360 : 0))
                    .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spinning)
            }
        }
        .frame(width: size, height: size)
        .onAppear { spinning = true }
        .accessibilityHidden(true)
    }
}

/// Tool-call and run state glyph: spinner, check, cross, or a warning mark, at 14pt.
public enum RunState: Equatable, Sendable {
    case running, done, failed, needsYou, queued
}

public struct RunStateGlyph: View {
    let state: RunState
    var size: CGFloat

    public init(_ state: RunState, size: CGFloat = Metrics.statusGlyph) {
        self.state = state
        self.size = size
    }

    public var body: some View {
        Group {
            switch state {
            case .running: Spinner(size: size - 2, color: Tokens.accent)
            case .done: Image(systemName: "checkmark").font(.system(size: size - 3, weight: .semibold)).foregroundStyle(Tokens.success)
            case .failed: Image(systemName: "xmark").font(.system(size: size - 3, weight: .semibold)).foregroundStyle(Tokens.danger)
            case .needsYou: Image(systemName: "exclamationmark.circle").font(.system(size: size - 2, weight: .medium)).foregroundStyle(Tokens.warning)
            case .queued: Circle().strokeBorder(Tokens.textMuted, lineWidth: 1.5).frame(width: size - 5, height: size - 5)
            }
        }
        .frame(width: size, height: size)
    }
}

/// The subagent branch glyph, in its run's state color.
public struct BranchGlyph: View {
    let color: Color
    var size: CGFloat

    public init(_ color: Color, size: CGFloat = 14) {
        self.color = color
        self.size = size
    }

    public var body: some View {
        Image(systemName: "arrow.turn.down.right")
            .font(.system(size: size - 3, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// DiffStat: "+58 −41" in success/danger micro mono (a true minus sign).
public struct DiffStat: View {
    let added: Int
    let removed: Int
    var font: Font?

    public init(added: Int, removed: Int, font: Font? = nil) {
        self.added = added
        self.removed = removed
        self.font = font
    }

    public var body: some View {
        HStack(spacing: 6) {
            Text("+\(added)").foregroundStyle(Tokens.successText)
            Text("\u{2212}\(removed)").foregroundStyle(Tokens.dangerText)
        }
        .font(font ?? Fonts.micro)
        .monospacedDigit()
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(added) added, \(removed) removed")
    }
}

/// One 8pt state cell per run (RunsStrip, RunLedger header).
public struct RunCells: View {
    let colors: [Color]

    public init(_ colors: [Color]) { self.colors = colors }

    public var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: Metrics.runCell, height: Metrics.runCell)
            }
        }
    }
}

/// The 4pt progress bar on running subagent cards.
public struct ProgressBar: View {
    let fraction: Double

    public init(_ fraction: Double) { self.fraction = min(1, max(0, fraction)) }

    public var body: some View {
        GeometryReader { geo in
            Capsule().fill(Tokens.bgTrack)
                .overlay(alignment: .leading) {
                    Capsule().fill(Tokens.accent).frame(width: geo.size.width * fraction)
                }
        }
        .frame(height: Metrics.progressHeight)
        .accessibilityValue("\(Int(fraction * 100)) percent")
    }
}
