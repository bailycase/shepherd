import SwiftUI

/// The canvas toolbar (SHCanvasToolbar; DZCanvas), 16pt from the canvas's bottom-leading corner:
/// a 38pt raised bar with the popover's line and shadow, three 30pt circle tools (Select,
/// Comment, Pan; the current one on `bgSelected` in `textPrimary`, the others clear in
/// `textSecondary`), a divider, and the zoom in mono 11 ("42%").
public struct SHCanvasToolbar: View {
    @Binding var tool: SHCanvasTool
    let zoom: String
    /// Tools not built yet draw disabled (Comment, until comments are).
    let disabled: Set<SHCanvasTool>

    public init(tool: Binding<SHCanvasTool>, zoom: String, disabled: Set<SHCanvasTool> = []) {
        _tool = tool
        self.zoom = zoom
        self.disabled = disabled
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(SHCanvasTool.allCases, id: \.self) { item in
                SHCanvasToolButton(tool: item, current: tool == item) { tool = item }
                    .disabled(disabled.contains(item))
            }
            SHHairline(.vertical)
                .frame(height: SHDesignMetrics.toolbarDividerHeight)
                .padding(.horizontal, SHDesignMetrics.toolbarDividerMargin)
            Text(zoom)
                .font(.shMono(SHDesignMetrics.zoomTextSize))
                .foregroundStyle(Color.sh.textSecondary)
                .monospacedDigit()
                .padding(.horizontal, SH.Space.s)
                .accessibilityLabel("Zoom \(zoom)")
        }
        .padding(SHDesignMetrics.toolbarPadding)
        .frame(height: SHDesignMetrics.toolbarHeight)
        .shPopover(radius: SHDesignMetrics.toolbarRadius)
    }
}

private struct SHCanvasToolButton: View {
    let tool: SHCanvasTool
    let current: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: tool.symbol)
                .font(.shSans(SHDesignMetrics.toolGlyph))
                .foregroundStyle(current ? Color.sh.textPrimary : Color.sh.textSecondary)
                .frame(width: SHDesignMetrics.toolSize, height: SHDesignMetrics.toolSize)
                .background(current ? Color.sh.bgSelected : .clear, in: Circle())
                .contentShape(Circle())
                .opacity(isEnabled ? 1 : SHControlMetrics.disabledOpacity)
        }
        .buttonStyle(.plain)
        .help(tool.title)
        .accessibilityLabel(tool.title)
        .accessibilityAddTraits(current ? .isSelected : [])
    }
}
