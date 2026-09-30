import SwiftUI

// The Browser while the agent is using it (PaneStates › BrowserPane · the agent is using it, and
// SidePaneTabs · the agent opened a tab): a `running` ring inset the page, a pointer where pi
// points, and a floating card under the toolbar with Take over. All of it is drawn over the page by
// the app, never in it. The app supplies the words and the pointer's place.

public enum NWBrowserAgentMetrics {
    /// The ring inset the page.
    public static let ringWidth: CGFloat = 2
    /// The pointer glyph (18pt wide; the board's arrow is 18 × 20).
    public static let pointerWidth: CGFloat = 18
    public static let pointerHeight: CGFloat = 20
    /// Where the arrow's tip is inside the glyph's box.
    public static let pointerTip = CGPoint(x: 2, y: 2)
    /// The card sits this far from the pane's sides and under the toolbar.
    public static let cardInset: CGFloat = NW.Space.l
    public static let cardGlyph: CGFloat = 12
    public static let cardGap: CGFloat = 10
    public static let cardLeading: CGFloat = NW.Space.l
    public static let cardOther: CGFloat = NW.Space.m
    /// The tab's brief tip: 300pt wide, a little more for a long page.
    public static let tabTipWidth: CGFloat = 300
    public static let tabTipMaxWidth: CGFloat = 420
    /// How long the tab's tip stays after pi opens something (and again while the tab is hovered).
    public static let tabTipSeconds: Double = 4
}

/// The 2pt `running` ring inset the page.
public struct NWAgentRing: View {
    public init() {}

    public var body: some View {
        Rectangle()
            .strokeBorder(Color.nw.running, lineWidth: NWBrowserAgentMetrics.ringWidth)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The pointer glyph: the board's arrow, `running` with a white edge.
public struct NWAgentPointer: View {
    public init() {}

    public var body: some View {
        NWAgentPointerShape()
            .fill(Color.nw.running)
            .overlay { NWAgentPointerShape().stroke(Color.nw.selectionHandle, style: StrokeStyle(lineWidth: 1.4, lineJoin: .round)) }
            .frame(width: NWBrowserAgentMetrics.pointerWidth, height: NWBrowserAgentMetrics.pointerHeight)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// `M2 2l13 7-6 1.4L6.5 17z` in an 18 × 20 box.
struct NWAgentPointerShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / NWBrowserAgentMetrics.pointerWidth
        let sy = rect.height / NWBrowserAgentMetrics.pointerHeight
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy) }
        var path = Path()
        path.move(to: point(2, 2))
        path.addLine(to: point(15, 9))
        path.addLine(to: point(9, 10.4))
        path.addLine(to: point(6.5, 17))
        path.closeSubpath()
        return path
    }
}

/// "Agent is clicking through checkout" with Take over (PaneStates › BrowserPane · the agent is
/// using it): `bgRaised`, radius 12, a `running` line and the popover's shadow; padding 8, 12 on
/// the leading side; the words in `ui` after a 12pt `running` glyph; Take over a secondary `s`
/// button with a glyph.
public struct NWAgentCard: View {
    let note: String
    let takeOver: () -> Void

    public init(note: String, takeOver: @escaping () -> Void) {
        self.note = note
        self.takeOver = takeOver
    }

    public static let glyph = "hand.raised"

    public var body: some View {
        let nw = Color.nw
        HStack(spacing: NWBrowserAgentMetrics.cardGap) {
            Image(systemName: Self.glyph)
                .font(.system(size: NWBrowserAgentMetrics.cardGlyph))
                .foregroundStyle(nw.running)
                .accessibilityHidden(true)
            Text("Agent is \(note)")
                .font(.nw(.ui, weight: .regular))
                .foregroundStyle(nw.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: takeOver) {
                Label("Take over", systemImage: Self.glyph)
            }
            .buttonStyle(.nw(.secondary, size: .s))
            .fixedSize()
        }
        .padding(.leading, NWBrowserAgentMetrics.cardLeading)
        .padding([.vertical, .trailing], NWBrowserAgentMetrics.cardOther)
        .nwPopover(radius: NW.Radius.l, line: nw.running)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent is \(note)")
    }
}

/// The ring, the pointer and the card over the page area. `pointer` is where the last action
/// pointed, in this view's own points; nil draws none. Only the card takes clicks: everything else
/// reaches the page, and a click there is the user taking it back.
public struct NWBrowserAgentOverlay: View {
    let note: String
    let pointer: CGPoint?
    let takeOver: () -> Void

    public init(note: String, pointer: CGPoint?, takeOver: @escaping () -> Void) {
        self.note = note
        self.pointer = pointer
        self.takeOver = takeOver
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            NWAgentRing()
            if let pointer {
                NWAgentPointer()
                    .offset(x: pointer.x - NWBrowserAgentMetrics.pointerTip.x, y: pointer.y - NWBrowserAgentMetrics.pointerTip.y)
                    .nwTransition(.overlay, edge: .top)
            }
            NWAgentCard(note: note, takeOver: takeOver)
                .padding(.horizontal, NWBrowserAgentMetrics.cardInset)
                .padding(.top, NWBrowserAgentMetrics.cardInset)
                .frame(maxWidth: .infinity, alignment: .top)
        }
        .nwAnimation(.overlay, value: pointer)
    }
}

// MARK: The tab's tip

/// What pi opened in a tab, for its brief tip.
public struct NWSidePaneTabTip: Equatable, Sendable {
    /// The page, host and path ("localhost:5173/checkout").
    public let text: String
    public let openedAt: Date

    public init(text: String, openedAt: Date) {
        self.text = text
        self.openedAt = openedAt
    }
}

/// "Agent opened localhost:5173/checkout   10s" under the tab (PaneStates › SidePaneTabs · the agent
/// opened a tab): 300pt, a popover with padding 4, a row of 4 × 6 with a 12pt globe, Geist 12, the
/// URL in mono and its age in `textTertiary`.
public struct NWPaneTabTip: View {
    let tip: NWSidePaneTabTip

    public init(_ tip: NWSidePaneTabTip) {
        self.tip = tip
    }

    /// "10s", "2m", "1h": how long ago, for the tip's trailing age.
    public static func age(seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds))
        if whole < 60 { return "\(whole)s" }
        if whole < 3600 { return "\(whole / 60)m" }
        return "\(whole / 3600)h"
    }

    public var body: some View {
        let nw = Color.nw
        HStack(spacing: NW.Space.m) {
            Image(systemName: "globe")
                .font(.system(size: NWBrowserAgentMetrics.cardGlyph))
                .foregroundStyle(nw.textSecondary)
                .accessibilityHidden(true)
            (Text("Agent opened ").font(.nwSans(12)) + Text(tip.text).font(.nwMono(12)))
                .foregroundStyle(nw.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: NW.Space.m)
            TimelineView(.periodic(from: tip.openedAt, by: 1)) { context in
                Text(Self.age(seconds: context.date.timeIntervalSince(tip.openedAt)))
                    .font(.nwSans(12))
                    .foregroundStyle(nw.textTertiary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, NW.Space.s)
        .padding(.vertical, NW.Space.xs)
        .padding(NW.Space.xs)
        // 300pt as drawn; a longer page widens it a little rather than cutting the address.
        .frame(minWidth: NWBrowserAgentMetrics.tabTipWidth, maxWidth: NWBrowserAgentMetrics.tabTipMaxWidth)
        .nwPopover(radius: NW.Radius.l)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Agent opened \(tip.text)")
    }
}
