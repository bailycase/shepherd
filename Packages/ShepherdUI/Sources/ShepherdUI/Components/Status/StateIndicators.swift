import SwiftUI

/// The state pill for headers and cards (Status board): a 6pt dot and the state's word on its
/// tint, radius 4. Queued and idle are outlined. Only attention glows.
public struct NWStatusPill: View {
    let state: AgentState
    let label: String

    /// `label` replaces the state's word ("Running · 0:31", "Stuck 14m", "2 subagents need you").
    public init(_ state: AgentState, label: String? = nil) {
        self.state = state
        self.label = label ?? state.label
    }

    public var body: some View {
        HStack(spacing: NW.Space.s) {
            NWStatusDot(state)
            Text(label)
                .font(.nwSans(11.5, .medium))
                .foregroundStyle(state.textColor)
                .lineLimit(1)
                .monospacedDigit()
                .nwContentTransition(.crossFade)
        }
        .padding(.leading, NW.Space.s)
        .padding(.trailing, 7)
        .frame(height: 20)
        .background(state.tint ?? .clear, in: RoundedRectangle(cornerRadius: NW.Radius.xs))
        .nwBorder(state.tint == nil ? Color.nw.lineStrong : .clear, radius: NW.Radius.xs)
        .fixedSize()
        // Keyed on the state: a new word and tint fade in, while a label that ticks (an elapsed
        // time) changes at once.
        .nwComponentAnimation(.content, value: state)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}

/// The state dot for rows (6pt). Attention glows (1.6s), and stops glowing under Reduce Motion,
/// including when Reduce Motion changes while the dot is on screen.
public struct NWStatusDot: View {
    let state: AgentState
    let size: CGFloat
    let color: Color?

    /// `color` overrides the state's color (a row's own accent), keeping its shape and glow.
    public init(_ state: AgentState, size: CGFloat = 6, color: Color? = nil) {
        self.state = state
        self.size = size
        self.color = color
    }

    public var body: some View {
        let fill = color ?? state.color
        Group {
            if state.isHollow {
                Circle().strokeBorder(fill, lineWidth: 1)
            } else if state.glows {
                NWGlow { Circle().fill(fill) }
            } else {
                Circle().fill(fill)
            }
        }
        .frame(width: size, height: size)
        .nwComponentAnimation(.content, value: state)
        .accessibilityHidden(true)
    }
}

/// Opacity pulse driven by the clock; static under Reduce Motion.
struct NWGlow<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            content()
        } else {
            TimelineView(.animation) { context in
                content().opacity(NWPhase.glowOpacity(context.date))
            }
        }
    }
}

/// The running spinner: a 3/4 arc turning once a second. Static under Reduce Motion. As a
/// style on a native `ProgressView`: `.progressViewStyle(.nwSpinner)`.
public struct NWSpinnerStyle: ProgressViewStyle {
    let size: CGFloat
    let color: Color?

    public init(size: CGFloat = 13, color: Color? = nil) {
        self.size = size
        self.color = color
    }

    public func makeBody(configuration: Configuration) -> some View {
        NWSpinnerArc(size: size, color: color)
    }
}

extension ProgressViewStyle where Self == NWSpinnerStyle {
    public static var nwSpinner: NWSpinnerStyle { NWSpinnerStyle() }
    public static func nwSpinner(size: CGFloat = 13, color: Color? = nil) -> NWSpinnerStyle { NWSpinnerStyle(size: size, color: color) }
}

struct NWSpinnerArc: View {
    let size: CGFloat
    let color: Color?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let arc = Circle().trim(from: 0, to: 0.75)
            .stroke(color ?? .nw.running, style: StrokeStyle(lineWidth: max(1.5, size * 0.145), lineCap: .round))
            .padding(max(1.5, size * 0.145) / 2)
        Group {
            if reduceMotion {
                arc
            } else {
                TimelineView(.animation) { context in
                    arc.rotationEffect(.degrees(NWPhase.fraction(context.date, .spin) * 360))
                }
            }
        }
        .frame(width: size, height: size)
    }
}

/// The 4pt progress bar (steps, budget): `.progressViewStyle(.nwBar)`, running blue unless
/// tinted.
public struct NWBarProgressStyle: ProgressViewStyle {
    let tint: Color?

    public init(tint: Color? = nil) { self.tint = tint }

    public func makeBody(configuration: Configuration) -> some View {
        let fraction = min(1, max(0, configuration.fractionCompleted ?? 0))
        let nw = Color.nw
        return Capsule().fill(nw.lineSubtle)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    Capsule().fill(tint ?? nw.running).frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 4)
            .nwComponentAnimation(.content, value: fraction)
            .accessibilityElement()
            .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
    }
}

extension ProgressViewStyle where Self == NWBarProgressStyle {
    public static var nwBar: NWBarProgressStyle { NWBarProgressStyle() }
    public static func nwBar(tint: Color?) -> NWBarProgressStyle { NWBarProgressStyle(tint: tint) }
}

/// A state glyph at 14pt (tool rows, runs): a spinner while running, otherwise the state's
/// symbol in its color; queued is a hollow ring.
public struct NWStateGlyph: View {
    let state: AgentState
    let size: CGFloat

    public init(_ state: AgentState, size: CGFloat = 14) {
        self.state = state
        self.size = size
    }

    public var body: some View {
        Group {
            switch state {
            case .running:
                NWSpinnerArc(size: size - 2, color: state.color)
            case .queued, .idle:
                Circle().strokeBorder(state.color, lineWidth: 1.5).frame(width: size - 5, height: size - 5)
            default:
                symbol
            }
        }
        .frame(width: size, height: size)
        // The spinner gives way to its outcome, and one outcome's symbol to another's.
        .nwComponentAnimation(.content, value: state)
        .accessibilityHidden(true)
    }

    private var symbol: some View {
        Image(systemName: state.symbolName)
            .font(.system(size: size - 3, weight: .semibold))
            .foregroundStyle(state.color)
            .nwContentTransition(.symbol)
    }
}

/// Mission and run steps, one segment per step in its state's color; pending steps are
/// `lineStrong` (Status board).
public struct NWStepStrip: View {
    let steps: [AgentState?]
    let segmentWidth: CGFloat?

    /// `nil` steps are pending. `segmentWidth` fixes each segment's width (the board's segments
    /// share the row, at least 14pt each).
    public init(_ steps: [AgentState?], segmentWidth: CGFloat? = nil) {
        self.steps = steps
        self.segmentWidth = segmentWidth
    }

    /// The gap between segments.
    static let spacing: CGFloat = 3
    static let segmentHeight: CGFloat = 3
    static let cornerRadius: CGFloat = 2

    public var body: some View {
        HStack(spacing: Self.spacing) {
            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                RoundedRectangle(cornerRadius: Self.cornerRadius)
                    .fill(Self.fill(step))
                    .frame(minWidth: segmentWidth ?? 14, maxWidth: segmentWidth ?? .infinity)
                    .frame(height: Self.segmentHeight)
            }
        }
        .nwComponentAnimation(.content, value: steps)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.summary(steps))
    }

    /// A segment's color: its state's, with pending and waiting steps in `lineStrong`.
    @MainActor static func fill(_ step: AgentState?) -> Color {
        step.map { $0 == .idle || $0 == .queued ? Color.nw.lineStrong : $0.color } ?? Color.nw.lineStrong
    }

    static func summary(_ steps: [AgentState?]) -> String {
        let finished = steps.filter { $0 == .done }.count
        return "\(finished) of \(steps.count) steps done"
    }
}

/// Activity over time (tool calls per minute, last 10 minutes) as a small line.
public struct NWSparkline: View {
    let values: [Double]
    let color: Color?

    public init(_ values: [Double], color: Color? = nil) {
        self.values = values
        self.color = color
    }

    public var body: some View {
        NWSparklineShape(values: values)
            .stroke(color ?? .nw.running, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
            .frame(width: 36, height: 12)
            .accessibilityHidden(true)
    }
}

struct NWSparklineShape: Shape {
    let values: [Double]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1, let low = values.min(), let high = values.max() else { return path }
        let span = high - low
        for (index, value) in values.enumerated() {
            let x = rect.minX + rect.width * CGFloat(index) / CGFloat(values.count - 1)
            let y = rect.maxY - rect.height * CGFloat(span > 0 ? (value - low) / span : 0.5)
            index == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
        }
        return path
    }
}
