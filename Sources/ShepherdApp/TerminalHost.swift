import SwiftUI
import ShepherdDesign
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
            appearance: Self.appearance(terminal),
            extraUnbinds: extraUnbinds,
            acceptsFileDrops: acceptsFileDrops
        )
    }

    /// Ghostty takes its scalar colors as bare hex; the palette keeps its `#`.
    private static func appearance(_ terminal: ShepherdTheme.Terminal) -> TerminalAppearance {
        func bare(_ hex: String) -> String { hex.hasPrefix("#") ? String(hex.dropFirst()) : hex }
        return TerminalAppearance(
            background: bare(terminal.background),
            foreground: bare(terminal.foreground),
            cursorColor: bare(terminal.cursor),
            selectionBackground: terminal.selectionBackground.map(bare),
            selectionForeground: terminal.selectionForeground.map(bare),
            palette: terminal.palette
        )
    }

    func feed(_ data: Data) {
        surface.feed(data)
    }

    func updateAppearance(_ terminal: ShepherdTheme.Terminal) {
        surface.updateAppearance(
            Self.appearance(terminal)
        )
    }

    @discardableResult
    func updateConfiguration(fontSize: CGFloat, fontFamily: String, extraUnbinds: [String]) -> Bool {
        surface.updateConfiguration(fontSize: fontSize, fontFamily: fontFamily, extraUnbinds: extraUnbinds)
    }

    var maximumDropBytes: Int? {
        get { surface.maximumDropBytes }
        set { surface.maximumDropBytes = newValue }
    }

    var onFileDropError: ((String) -> Void)? {
        get { surface.onFileDropError }
        set { surface.onFileDropError = newValue }
    }

    var onFileDrop: (([URL]) -> Void)? {
        get { surface.onFileDrop }
        set { surface.onFileDrop = newValue }
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


    var onSurfaceAttachmentChanged: ((_ generation: UInt64?) -> Void)? {
        get { surface.onSurfaceAttachmentChanged }
        set { surface.onSurfaceAttachmentChanged = newValue }
    }

    @discardableResult
    func replaceWithReplay(_ data: Data, generation: UInt64) -> Bool {
        surface.replaceWithReplay(data, generation: generation)
    }

    var model: TerminalSurfaceModel { surface }
}

/// Image drops outside a terminal (the native composer) go through the same resize
/// rules as terminal drops: longest edge 2000px, JPEG stays JPEG, else PNG.
enum AppImageDrop {
    static func resolve(_ providers: [NSItemProvider]) async -> [URL] {
        await TerminalImageDrop.resolve(providers)
    }
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
