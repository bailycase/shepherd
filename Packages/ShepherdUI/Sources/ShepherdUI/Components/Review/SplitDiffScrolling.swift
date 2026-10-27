import SwiftUI
#if os(macOS)
import AppKit
#endif

/// One file's horizontal positions: a split file's two sides, or a unified file's code (the new
/// side's). Vertical scrolling remains the containing diff's.
@MainActor @Observable
public final class SHSplitDiffScroll {
    public var oldOffset: CGFloat = 0
    public var newOffset: CGFloat = 0
    public private(set) var oldLimit: CGFloat = 0
    public private(set) var newLimit: CGFloat = 0

    public init() {}

    public func resize(oldWidth: CGFloat, newWidth: CGFloat, viewport: CGFloat) {
        let old = max(0, oldWidth - viewport), new = max(0, newWidth - viewport)
        if oldLimit != old { oldLimit = old }
        if newLimit != new { newLimit = new }
        move(to: oldOffset, old: true)
        move(to: newOffset, old: false)
    }

    public func move(to offset: CGFloat, old: Bool) {
        let value = min(max(0, offset), old ? oldLimit : newLimit)
        if old { if oldOffset != value { oldOffset = value } }
        else if newOffset != value { newOffset = value }
    }
}

extension EnvironmentValues {
    @Entry public var splitDiffScroll: SHSplitDiffScroll? = nil
    /// Diff lines wrap at the pane's edge instead of scrolling sideways.
    @Entry public var diffWrapsLines = false
}

#if os(macOS)
/// Native scrollbars per file (two in split, one in unified), not a scroll view per line. Code
/// canvases read their own column's offset; gutters, comments and the center divider stay at the
/// viewport's positions.
public struct SHSplitDiffScrollbars: View {
    let scroll: SHSplitDiffScroll
    let unified: Bool
    public init(_ scroll: SHSplitDiffScroll, unified: Bool = false) { self.scroll = scroll; self.unified = unified }
    public var body: some View {
        HStack(spacing: 0) {
            if unified {
                SplitScroller(scroll: scroll, old: false, codeLeading: SHDiffMetrics.codeLeading)
            } else {
                SplitScroller(scroll: scroll, old: true, codeLeading: SHDiffMetrics.splitCodeLeading)
                Color.sh.lineSubtle.frame(width: 1)
                SplitScroller(scroll: scroll, old: false, codeLeading: SHDiffMetrics.splitCodeLeading)
            }
        }
        .frame(height: NSScroller.scrollerWidth(for: .small, scrollerStyle: .legacy))
    }
}

private struct SplitScroller: NSViewRepresentable {
    let scroll: SHSplitDiffScroll
    let old: Bool
    let codeLeading: CGFloat
    func makeNSView(context: Context) -> Control {
        let height = NSScroller.scrollerWidth(for: .small, scrollerStyle: .legacy)
        let view = Control(frame: CGRect(x: 0, y: 0, width: SHDiffMetrics.numberWidth * 2, height: height))
        view.controlSize = .small
        view.scrollerStyle = .legacy
        view.target = view
        view.action = #selector(Control.changed)
        view.setAccessibilityLabel(old ? "Scroll old code horizontally" : "Scroll new code horizontally")
        return view
    }
    func updateNSView(_ view: Control, context: Context) {
        view.scroll = scroll; view.old = old; view.codeLeading = codeLeading
        view.updatePosition()
    }
    final class Control: NSScroller {
        var scroll: SHSplitDiffScroll?
        var old = false
        var codeLeading = SHDiffMetrics.splitCodeLeading
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            updatePosition()
        }
        func updatePosition() {
            guard let scroll else { return }
            let limit = old ? scroll.oldLimit : scroll.newLimit
            isEnabled = limit > 0
            doubleValue = limit > 0 ? Double((old ? scroll.oldOffset : scroll.newOffset) / limit) : 0
            let viewport = max(1, bounds.width - codeLeading - SHDiffMetrics.commentSlotWidth)
            knobProportion = viewport / (viewport + limit)
        }
        @objc func changed() {
            guard let scroll else { return }
            let limit = old ? scroll.oldLimit : scroll.newLimit
            let current = old ? scroll.oldOffset : scroll.newOffset
            switch hitPart {
            case .decrementPage: scroll.move(to: current - bounds.width, old: old)
            case .incrementPage: scroll.move(to: current + bounds.width, old: old)
            default: scroll.move(to: CGFloat(doubleValue) * limit, old: old)
            }
        }
    }
}

#endif
