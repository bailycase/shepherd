import AppKit
import GhosttyTerminal
import UniformTypeIdentifiers

/// Drag routing belongs to the native surface: no window overlay, named-pasteboard lifetime
/// guess, or walk through hidden agent hosts. AppKit supplies the actual drag's pasteboard.
@MainActor
enum TerminalSurfaceDrop {
    static let draggedTypes: [NSPasteboard.PasteboardType] = [
        .fileURL, .tiff, .png,
        NSPasteboard.PasteboardType(UTType.jpeg.identifier),
        NSPasteboard.PasteboardType(UTType.gif.identifier),
        NSPasteboard.PasteboardType(UTType.image.identifier),
    ]

    static func install(on view: AppTerminalView, model: TerminalSurfaceModel) {
        view.registerForDraggedTypes(draggedTypes)
        view.acceptsHostDrop = { [weak view, weak model] in
            guard let view, let model else { return false }
            return view.window != nil && !view.isHiddenOrHasHiddenAncestor && model.renderingActive && model.acceptsFileDrops
        }
        view.onHostDrop = { [weak model] pasteboard in
            guard let model, model.renderingActive, model.acceptsFileDrops else { return false }
            let providers = TerminalImageDrop.providers(from: pasteboard)
            guard !providers.isEmpty else { return false }
            Task { @MainActor in
                do {
                    let urls = try await TerminalImageDrop.resolve(providers, maximumBytes: model.maximumDropBytes)
                    guard !urls.isEmpty else { return }
                    if model.sendDroppedFiles(urls) { model.takeKeyboardFocus() }
                } catch { model.onFileDropError?(error.localizedDescription) }
            }
            return true
        }
    }
}
