import SwiftUI

/// The canvas toolbar (NWCanvasToolbar; DZCanvas), 16pt from the canvas's bottom-leading corner:
/// a 38pt raised bar with the popover's line and shadow, three 30pt circle tools (Select,
/// Comment, Pan; the current one on `bgSelected` in `textPrimary`, the others clear in
/// `textSecondary`), a divider, and the zoom in mono 11 ("42%").
public struct NWCanvasToolbar: View {
    @Binding var tool: NWCanvasTool
    let zoom: String
    /// Tools not built yet draw disabled (Comment, until comments are).
    let disabled: Set<NWCanvasTool>

    public init(tool: Binding<NWCanvasTool>, zoom: String, disabled: Set<NWCanvasTool> = []) {
        _tool = tool
        self.zoom = zoom
        self.disabled = disabled
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(NWCanvasTool.allCases, id: \.self) { item in
                NWCanvasToolButton(tool: item, current: tool == item) { tool = item }
                    .disabled(disabled.contains(item))
            }
            Rectangle()
                .fill(Color.nw.lineSubtle)
                .frame(width: 1, height: NWDesignMetrics.toolbarDividerHeight)
                .padding(.horizontal, NWDesignMetrics.toolbarDividerMargin)
                .accessibilityHidden(true)
            Text(zoom)
                .font(.nwMono(NWDesignMetrics.zoomTextSize))
                .foregroundStyle(Color.nw.textSecondary)
                .monospacedDigit()
                .padding(.horizontal, NW.Space.s)
                .accessibilityLabel("Zoom \(zoom)")
        }
        .padding(NWDesignMetrics.toolbarPadding)
        .frame(height: NWDesignMetrics.toolbarHeight)
        .nwPopover(radius: NWDesignMetrics.toolbarRadius)
    }
}

private struct NWCanvasToolButton: View {
    let tool: NWCanvasTool
    let current: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: tool.symbol)
                .font(.nwSans(NWDesignMetrics.toolGlyph))
                .foregroundStyle(current ? Color.nw.textPrimary : Color.nw.textSecondary)
                .frame(width: NWDesignMetrics.toolSize, height: NWDesignMetrics.toolSize)
                .background(current ? Color.nw.bgSelected : .clear, in: Circle())
                .contentShape(Circle())
                .opacity(isEnabled ? 1 : NWControlMetrics.disabledOpacity)
        }
        .buttonStyle(.plain)
        .help(tool.title)
        .accessibilityLabel(tool.title)
        .accessibilityAddTraits(current ? .isSelected : [])
    }
}
