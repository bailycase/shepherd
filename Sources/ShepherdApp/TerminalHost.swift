import SwiftUI
import TerminalSurfaceKit

/// Thin forwarders around the frozen TerminalSurfaceKit API. The only file in
/// the app that imports the module, so an engine-side change breaks one file.
@MainActor
final class AppTerminalModel {
    private let surface: TerminalSurfaceModel

    init(
        fontSize: CGFloat = 12.5,
        fontFamily: String = "SF Mono",
        terminal: ShepherdTheme.Terminal,
        extraUnbinds: [String] = [],
        acceptsFileDrops: Bool = true
    ) {
        surface = TerminalSurfaceModel(
            fontSize: fontSize,
            fontFamily: fontFamily,
            appearance: TerminalAppearance(
                background: terminal.background,
                foreground: terminal.foreground,
                cursorColor: terminal.cursorColor,
                selectionBackground: terminal.selectionBackground,
                selectionForeground: terminal.selectionForeground,
                palette: terminal.palette
            ),
            extraUnbinds: extraUnbinds,
            acceptsFileDrops: acceptsFileDrops
        )
    }

    func feed(_ data: Data) {
        surface.feed(data)
    }

    func updateAppearance(_ terminal: ShepherdTheme.Terminal) {
        surface.updateAppearance(
            TerminalAppearance(
                background: terminal.background,
                foreground: terminal.foreground,
                cursorColor: terminal.cursorColor,
                selectionBackground: terminal.selectionBackground,
                selectionForeground: terminal.selectionForeground,
                palette: terminal.palette
            )
        )
    }

    @discardableResult
    func updateConfiguration(fontSize: CGFloat, fontFamily: String, extraUnbinds: [String]) -> Bool {
        surface.updateConfiguration(fontSize: fontSize, fontFamily: fontFamily, extraUnbinds: extraUnbinds)
    }

    var onInput: ((Data) -> Void)? {
        get { surface.onInput }
        set { surface.onInput = newValue }
    }

    var onResize: ((_ cols: Int, _ rows: Int) -> Void)? {
        get { surface.onResize }
        set { surface.onResize = newValue }
    }

    var onSurfaceReplaced: ((_ generation: UInt64) -> Void)? {
        get { surface.onSurfaceReplaced }
        set { surface.onSurfaceReplaced = newValue }
    }


    @discardableResult
    func replaceWithReplay(_ data: Data, generation: UInt64) -> Bool {
        surface.replaceWithReplay(data, generation: generation)
    }

    fileprivate var model: TerminalSurfaceModel { surface }
}

/// Installs the window-level file-drop overlay. Mount once per window.
struct AppTerminalDropOverlay: View {
    var body: some View { TerminalDropOverlayInstaller().frame(width: 0, height: 0) }
}

struct AppTerminalView: View {
    let model: AppTerminalModel
    let isFocused: Bool
    /// False for a mounted-but-hidden pane, which must stop drawing.
    var isRendering: Bool = true

    var body: some View {
        TerminalSurfaceView(model: model.model, isFocused: isFocused, isRendering: isRendering)
    }
}
