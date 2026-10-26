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
