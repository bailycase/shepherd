import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Window-level file/image drop routing.
///
/// SwiftUI `.onDrop` cannot work here: every agent layout stays mounted
/// (opacity 0), drag routing ignores both opacity and `allowsHitTesting`, and
/// AppKit only bubbles a rejected drag up through superviews — never across
/// siblings — so a hidden pane stacked above the visible one either steals
/// the drop or kills the drag outright. The fix is one transparent NSView
/// above the whole content view that owns drag destination duty and routes the drop
/// itself. This is the minimal version of that: the overlay participates in
/// hit-testing only while a file/image drag is in flight, finds the *visible*
/// ghostty surface under the cursor, and delivers the drop to its model.
public struct TerminalDropOverlayInstaller: NSViewRepresentable {
    public init() {}

    public func makeNSView(context: Context) -> NSView { InstallerView() }
    public func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Zero-size view whose only job is to install the real overlay directly on
/// the window's content view, above the NSHostingView — an overlay *inside*
/// the SwiftUI hierarchy would sit below sibling hosting layers.
private final class InstallerView: NSView {
    private weak var overlay: TerminalDropOverlayView?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        overlay?.removeFromSuperview()
        guard let contentView = window?.contentView else { return }
        let view = TerminalDropOverlayView(frame: contentView.bounds)
        view.autoresizingMask = [.width, .height]
        contentView.addSubview(view, positioned: .above, relativeTo: nil)
        overlay = view
    }
}

private final class TerminalDropOverlayView: NSView {
    /// Concrete pasteboard types worth accepting. `registerForDraggedTypes`
    /// matches exact types, not UTI conformance, so `public.image` alone
    /// would miss the TIFF/PNG that screenshot drags actually carry.
    private static let draggedTypes: [NSPasteboard.PasteboardType] = [
        .fileURL, .tiff, .png,
        NSPasteboard.PasteboardType(UTType.jpeg.identifier),
        NSPasteboard.PasteboardType(UTType.gif.identifier),
        NSPasteboard.PasteboardType(UTType.image.identifier),
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(Self.draggedTypes)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override var acceptsFirstResponder: Bool { false }

    /// Participate in hit-testing only while AppKit's drag pasteboard carries
    /// a supported item. `NSApp.currentEvent` is not reliable during drag
    /// destination lookup (Finder commonly leaves it as mouseMoved or nil),
    /// which prevented this view from ever receiving `draggingEntered`.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let dragTypes = NSPasteboard(name: .drag).types ?? []
        guard dragTypes.contains(where: Self.draggedTypes.contains) else { return nil }
        return super.hitTest(point)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        targetModel(at: sender.draggingLocation) != nil ? .copy : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        targetModel(at: sender.draggingLocation) != nil ? .copy : []
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let model = targetModel(at: sender.draggingLocation) else { return false }
        let providers = TerminalImageDrop.providers(from: sender.draggingPasteboard)
        guard !providers.isEmpty else { return false }
        Task { @MainActor in
            let urls = await TerminalImageDrop.resolve(providers)
            guard !urls.isEmpty else { return }
            if model.sendDroppedFiles(urls) {
                model.takeKeyboardFocus()
            }
        }
        // The work is async, so accept now; resolve() drops anything unusable.
        return true
    }

    /// The model of the *visible* ghostty surface under a window-coordinate
    /// point. Hidden panes keep their NSViews mounted at the same coordinates;
    /// `renderingActive` is the app's authoritative "this pane is visible"
    /// bit, so it filters them out.
    private func targetModel(at windowPoint: NSPoint) -> TerminalSurfaceModel? {
        guard let contentView = window?.contentView else { return nil }
        for view in TerminalFirstResponder.surfaceViews(in: contentView) {
            let local = view.convert(windowPoint, from: nil)
            guard view.bounds.contains(local),
                  let model = TerminalSurfaceModel.model(for: view),
                  model.renderingActive,
                  model.acceptsFileDrops
            else { continue }
            return model
        }
        return nil
    }
}
