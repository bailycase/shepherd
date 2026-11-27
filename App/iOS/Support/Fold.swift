import SwiftUI
import ShepherdUI

extension GeometryProxy {
    /// iPhone Duo's fold while it splits this view into a leading and a trailing side (the inner
    /// display held upright, half open): its span across the view, in the view's coordinates.
    /// Nil fully open, closed, held sideways (the fold runs across, and scrolling content may pass
    /// under it), and on every other device.
    var verticalFold: ClosedRange<CGFloat>? {
        // Reserved regions arrive with the iOS 27.1 SDK (SwiftUI 8.0.85); an older SDK still builds,
        // and has no fold to report.
        #if canImport(SwiftUI, _version: 8.0.85)
        guard #available(iOS 27.1, *) else { return nil }
        let fold = reservedRegions(kind: .division).first {
            $0.frame.height > $0.frame.width && $0.frame.minX > 0 && $0.frame.maxX < size.width
        }
        return fold.map { $0.frame.minX...$0.frame.maxX }
        #else
        return nil
        #endif
    }
}

extension GeometryProxy {
    /// Where a flat inner display's halves meet: its middle, as wide as nothing, across the view in the view's own
    /// coordinates. The view is the display less what the system's bars take down its trailing side.
    var seam: ClosedRange<CGFloat> {
        let middle = (size.width + safeAreaInsets.leading + safeAreaInsets.trailing) / 2 - safeAreaInsets.leading
        return middle...middle
    }
}

extension GeometryProxy {
    /// iPhone Duo's fold while it splits this view into a top and a bottom part (the inner display
    /// held in portrait, half open: the laptop pose). Nil otherwise.
    var horizontalFold: ClosedRange<CGFloat>? {
        #if canImport(SwiftUI, _version: 8.0.85)
        guard #available(iOS 27.1, *) else { return nil }
        let fold = reservedRegions(kind: .division).first {
            $0.frame.width > $0.frame.height && $0.frame.minY > 0 && $0.frame.maxY < size.height
        }
        return fold.map { $0.frame.minY...$0.frame.maxY }
        #else
        return nil
        #endif
    }
}

extension View {
    /// Calls `action` with whether iPhone Duo is folded shut, at first and as its hinge moves;
    /// never on a device without a hinge, nor built with an SDK older than iOS 27.1's.
    func onHingeClosedChange(_ action: @escaping (Bool) -> Void) -> some View {
        modifier(HingeWatch(action: action))
    }

    /// Exactly `width` when given, else as wide as it is offered. One modifier either way, so a
    /// pane keeps its identity (and its scroll position) as the fold comes and goes.
    func paneWidth(_ width: CGFloat?) -> some View {
        frame(minWidth: width ?? 0, maxWidth: width ?? .infinity)
    }
}

private struct HingeWatch: ViewModifier {
    let action: (Bool) -> Void

    func body(content: Content) -> some View {
        #if canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *) {
            content.onHingeChange { _, new in
                if let hinge = new.hinge { action(hinge.status == .closed) }
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// Whether the system draws this view's bars as a column at its side (iPhone Duo's outer display, and
/// its inner one in landscape; `toolbarVerticalEdge`). Always false before the iOS 27.1 SDK and system.
struct VerticalBars<Content: View>: View {
    @ViewBuilder let content: (Bool) -> Content

    var body: some View {
        #if canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *) {
            VerticalBarsReader(content: content)
        } else {
            content(false)
        }
        #else
        content(false)
        #endif
    }
}

#if canImport(SwiftUI, _version: 8.0.85)
@available(iOS 27.1, *)
private struct VerticalBarsReader<Content: View>: View {
    let content: (Bool) -> Content
    @Environment(\.toolbarVerticalEdge) private var edge

    var body: some View { content(edge != nil) }
}
#endif

/// An iPad list beside its detail (Settings, Automations, Needs you, Hosts). Half open, the list
/// ends at the fold and the detail starts after it. Where the detail would be narrower than
/// `MobileLayout.splitDetailMinWidth` (an iPhone Duo's detail column beside the sidebar), the
/// screen shows `single`, the list alone, its rows pushing their detail.
struct PadListDetail<List: View, Detail: View, Single: View>: View {
    let listWidth: CGFloat
    @ViewBuilder let list: List
    @ViewBuilder let detail: Detail
    @ViewBuilder let single: Single

    var body: some View {
        GeometryReader { proxy in
            let fold = proxy.verticalFold
            if fold == nil, proxy.size.width < listWidth + MobileLayout.splitDetailMinWidth {
                single
            } else {
                HStack(spacing: 0) {
                    list
                        .paneWidth(fold?.lowerBound ?? listWidth)
                        .padding(.trailing, fold.map { $0.upperBound - $0.lowerBound } ?? 0)
                    SHHairline(.vertical)
                    detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}

/// Where the bars run down the side (iPhone Duo's inner display) the screen's top edge holds nothing: a screen starts there, its head at the
/// edge, as the boards draw it (DuoOpenThread, DuoOpenSidePane, DuoOpenNeedsYou). Elsewhere the bar's room stays.
struct DuoTopEdge: ViewModifier {
    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content: Content) -> some View {
        VerticalBars { bars in
            let duo = bars && sizeClass == .regular
            // The bar's blur over the first 24pt goes with its room: nothing draws there.
            content
                .ignoresSafeArea(.container, edges: duo ? .top : [])
                .scrollEdgeEffectHidden(duo, for: .top)
                // The boards' heads sit 12pt below the edge (DuoOpenSettings, DuoOpenNeedsYou).
                .contentMargins(.top, duo ? SH.Space.l : 0, for: .scrollContent)
                .toolbarBackgroundVisibility(duo ? .hidden : .automatic, for: .navigationBar)
        }
    }
}

// MARK: The bars' column

extension MobileLayout {
    /// A glyph in the column iPhone Duo's bars make at its side. The system draws the glass (a 48pt-wide pill of 44pt buttons) and
    /// nothing in it can be resized; the boards' glyphs are lighter and smaller than the system's 17pt (DuoOpenOverview, DuoClosedHome:
    /// the magnifier, dots and compose measure 13pt), except the side pane's, which the board draws a size larger (DuoOpenThread).
    static let stripGlyph: CGFloat = 13
    static let stripPaneGlyph: CGFloat = 17
}

extension View {
    /// A bar button's icon, drawn at the boards' size where the bars run down the side (iPhone Duo); the system's size elsewhere.
    func duoStripIcon(size: CGFloat = MobileLayout.stripGlyph) -> some View { labelStyle(DuoStripLabelStyle(size: size)) }
}

struct DuoStripLabelStyle: LabelStyle {
    let size: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        DuoStripIcon(label: Label(configuration).labelStyle(.iconOnly), size: size)
    }
}

private struct DuoStripIcon<Content: View>: View {
    let label: Content
    let size: CGFloat
    // The bar's own environment does not say which way it runs (`toolbarVerticalEdge` is not set for a toolbar's items), but only an
    // iPhone Duo has a hinge, and every pose of it draws the bars as the column at its side.
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        if navigator.hingeClosed != nil { label.font(.system(size: size)) } else { label }
    }
}
