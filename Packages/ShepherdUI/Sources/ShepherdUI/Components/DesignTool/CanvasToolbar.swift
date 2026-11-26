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
        #if os(macOS)
        macBar
        #else
        iosBar
        #endif
    }

    #if os(macOS)
    /// DZCanvas: a 36pt capsule on the card fill with the toolbar capsule's line and lift, three 28pt tools,
    /// a rule, and the zoom in 12.
    private var macBar: some View {
        let M = SHDesignChrome.self
        let shape = Capsule()
        return HStack(spacing: M.barSpacing) {
            ForEach(SHCanvasTool.allCases, id: \.self) { item in
                SHCanvasToolButton(tool: item, current: tool == item) { tool = item }
                    .disabled(disabled.contains(item))
            }
            SHHairline(.vertical)
                .frame(height: M.dividerHeight)
                .padding(.leading, M.barDividerMargin)
            Text(zoom)
                .font(.shSans(M.zoomTextSize))
                .foregroundStyle(Color.sh.textSecondary)
                .monospacedDigit()
                .padding(.leading, M.zoomPaddingLeading)
                .padding(.trailing, M.zoomPaddingTrailing)
                .accessibilityLabel("Zoom \(zoom)")
        }
        .padding(M.barPadding)
        .frame(height: M.barHeight)
        .shLift(shape)
        .overlay { shape.strokeBorder(Color.sh.lineSubtle, lineWidth: 1).allowsHitTesting(false) }
    }
    #endif

    private var iosBar: some View {
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
        #if os(iOS)
        // The iPad boards' glass capsule (iPadDesign's tools).
        .glassEffect(.regular, in: Capsule())
        #else
        .shPopover(radius: SHDesignMetrics.toolbarRadius)
        #endif
    }
}

private struct SHCanvasToolButton: View {
    let tool: SHCanvasTool
    let current: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        #if os(macOS)
        // The boards' `.ib`: a 28pt rounded square, the current tool on `bgSelected`.
        let side = SHDesignChrome.barItemHeight
        let glyph = SHDesignChrome.barGlyph
        let shape = RoundedRectangle(cornerRadius: SH.Radius.s)
        #else
        let side = SHDesignMetrics.toolSize
        let glyph = SHDesignMetrics.toolGlyph
        let shape = RoundedRectangle(cornerRadius: SHDesignMetrics.toolSize / 2)
        #endif
        Button(action: action) {
            Image(systemName: tool.symbol)
                .font(.shSans(glyph))
                .foregroundStyle(current ? Color.sh.textPrimary : Color.sh.textSecondary)
                .frame(width: side, height: side)
                .background(current ? Color.sh.bgSelected : .clear, in: shape)
                .contentShape(shape)
                .opacity(isEnabled ? 1 : SHControlMetrics.disabledOpacity)
        }
        .buttonStyle(.plain)
        .help(tool.title)
        .accessibilityLabel(tool.title)
        .accessibilityAddTraits(current ? .isSelected : [])
    }
}
