import SwiftUI

// The Browser while the agent is using it (PaneStates › BrowserPane · the agent is using it, and
// SidePaneTabs · the agent opened a tab): a `running` ring inset the page, a pointer where pi
// points; the words and Take over are the bar under the page (BrowserTabs.swift). All of it is drawn
// over or under the page by the app, never in it. The app supplies the words and the pointer's place.

public enum SHBrowserAgentMetrics {
    /// The ring inset the page.
    public static let ringWidth: CGFloat = 2
    /// The pointer glyph (18pt wide; the board's arrow is 18 × 20).
    public static let pointerWidth: CGFloat = 18
    public static let pointerHeight: CGFloat = 20
    /// Where the arrow's tip is inside the glyph's box.
    public static let pointerTip = CGPoint(x: 2, y: 2)
    /// The notice card sits this far from the pane's sides and under the toolbar.
    public static let cardInset: CGFloat = SH.Space.l
    public static let cardGlyph: CGFloat = 12
    public static let cardGap: CGFloat = 10
    public static let cardLeading: CGFloat = SH.Space.l
    public static let cardOther: CGFloat = SH.Space.m
    /// The tab's brief tip: 300pt wide, a little more for a long page.
    public static let tabTipWidth: CGFloat = 300
    public static let tabTipMaxWidth: CGFloat = 420
    /// How long the tab's tip stays after pi opens something (and again while the tab is hovered).
    public static let tabTipSeconds: Double = 4
}

/// The 2pt `running` ring inset the page.
public struct SHAgentRing: View {
    public init() {}

    public var body: some View {
        Rectangle()
            .strokeBorder(Color.sh.running, lineWidth: SHBrowserAgentMetrics.ringWidth)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The pointer glyph: the board's arrow, `running` with a white edge.
public struct SHAgentPointer: View {
    public init() {}

    public var body: some View {
        SHAgentPointerShape()
            .fill(Color.sh.running)
            .overlay { SHAgentPointerShape().stroke(Color.sh.selectionHandle, style: StrokeStyle(lineWidth: 1.4, lineJoin: .round)) }
            .frame(width: SHBrowserAgentMetrics.pointerWidth, height: SHBrowserAgentMetrics.pointerHeight)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// `M2 2l13 7-6 1.4L6.5 17z` in an 18 × 20 box.
struct SHAgentPointerShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / SHBrowserAgentMetrics.pointerWidth
        let sy = rect.height / SHBrowserAgentMetrics.pointerHeight
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

/// The ring and the pointer over the page area. `pointer` is where the last action pointed, in
/// this view's own points; nil draws none. The words and Take over are `SHAgentBar`, under the
/// page (BrowserTabsAgent). Nothing here takes a click: it all reaches the page, and a click there
/// is the user taking it back.
public struct SHBrowserAgentOverlay: View {
    let pointer: CGPoint?

    public init(pointer: CGPoint?) {
        self.pointer = pointer
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            SHAgentRing()
            if let pointer {
                SHAgentPointer()
                    .offset(x: pointer.x - SHBrowserAgentMetrics.pointerTip.x, y: pointer.y - SHBrowserAgentMetrics.pointerTip.y)
                    .shTransition(.overlay, edge: .top)
            }
        }
        .allowsHitTesting(false)
        .shAnimation(.overlay, value: pointer)
    }
}

// MARK: The tab's tip

/// What pi opened in a tab, for its brief tip.
public struct SHSidePaneTabTip: Equatable, Sendable {
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
public struct SHPaneTabTip: View {
    let tip: SHSidePaneTabTip

    public init(_ tip: SHSidePaneTabTip) {
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
        let sh = Color.sh
        HStack(spacing: SH.Space.m) {
            Image(systemName: "globe")
                .font(.system(size: SHBrowserAgentMetrics.cardGlyph))
                .foregroundStyle(sh.textSecondary)
                .accessibilityHidden(true)
            (Text("Agent opened ").font(.shSans(12)) + Text(tip.text).font(.shMono(12)))
                .foregroundStyle(sh.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: SH.Space.m)
            TimelineView(.periodic(from: tip.openedAt, by: 1)) { context in
                Text(Self.age(seconds: context.date.timeIntervalSince(tip.openedAt)))
                    .font(.shSans(12))
                    .foregroundStyle(sh.textTertiary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, SH.Space.s)
        .padding(.vertical, SH.Space.xs)
        .padding(SH.Space.xs)
        // 300pt as drawn; a longer page widens it a little rather than cutting the address.
        .frame(minWidth: SHBrowserAgentMetrics.tabTipWidth, maxWidth: SHBrowserAgentMetrics.tabTipMaxWidth)
        .shPopover(radius: SH.Radius.l)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Agent opened \(tip.text)")
    }
}
