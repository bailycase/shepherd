import AppKit
import CoreML
import Vision
import Darwin
import Testing

// macOS 27's Vision GPU backend can fail to register its compute graph under test.
extension VNRecognizeTextRequest {
    func useCPUForTests() throws {
        revision = VNRecognizeTextRequestRevision2
        for (stage, devices) in try supportedComputeStageDevices {
            if let cpu = devices.first(where: { if case .cpu = $0 { true } else { false } }) {
                setComputeDevice(cpu, for: stage)
            }
        }
    }
}

/// WindowServer pixels without forcing a redraw. Capture only windows owned by this process.
/// The public CoreGraphics function is deprecated but remains available at runtime.
@MainActor
enum ThreadWindowCapture {
    static func image(_ window: NSWindow) throws -> CGImage {
        let id = CGWindowID(window.windowNumber)
        let info = try #require((CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]])?.first)
        #expect(info[kCGWindowOwnerPID as String] as? Int == Int(getpid()))
        try #require(info[kCGWindowOwnerPID as String] as? Int == Int(getpid()))
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let symbol = try #require(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"))
        let capture = unsafeBitCast(symbol, to: Capture.self)
        return try #require(capture(.null, CGWindowListOption.optionIncludingWindow.rawValue, id,
                                    CGWindowImageOption.boundsIgnoreFraming.rawValue)?.takeRetainedValue())
    }

    /// Failure-only native placement and paint state. Never lays out, redraws or reads text.
    static func placement(of root: NSView, in scroll: NSScrollView) -> [String: Any] {
        let clip = scroll.contentView
        func rect(_ value: CGRect) -> [Double] {
            [value.minX, value.minY, value.width, value.height].map(Double.init)
        }
        var visited = 0, fields: [[String: Any]] = []
        func inspect(_ view: NSView) {
            guard visited < 4096 else { return }
            visited += 1
            if (view is NSTextField || view is NSTextView), fields.count < 512 {
                let frame = view.convert(view.bounds, to: clip)
                    .offsetBy(dx: -clip.bounds.minX, dy: -clip.bounds.minY)
                var ancestors: [[String: Any]] = [], ancestor: NSView? = view
                while let current = ancestor, ancestors.count < 24 {
                    var state: [String: Any] = ["type": String(describing: type(of: current)),
                        "hidden": current.isHidden, "alpha": Double(current.alphaValue)]
                    if let layer = current.layer {
                        state["layerHidden"] = layer.isHidden
                        state["layerOpacity"] = Double(layer.opacity)
                        state["layerMasksToBounds"] = layer.masksToBounds
                        if let presentation = layer.presentation() {
                            state["presentationOpacity"] = Double(presentation.opacity)
                        }
                    }
                    ancestors.append(state)
                    ancestor = current.superview
                }
                fields.append(["type": String(describing: type(of: view)), "frame": rect(view.frame),
                    "viewportFrame": rect(frame), "visibleRect": rect(view.visibleRect),
                    "intersectsViewport": frame.intersects(CGRect(origin: .zero, size: clip.bounds.size)),
                    "hiddenInHierarchy": view.isHiddenOrHasHiddenAncestor,
                    "ancestorLimitReached": ancestor != nil, "ancestors": ancestors])
            }
            view.subviews.forEach(inspect)
        }
        inspect(scroll.documentView ?? root)
        return ["scope": scroll.documentView == nil ? "fallback-root" : "scroll-document",
            "clip": rect(clip.bounds), "document": scroll.documentView.map { rect($0.bounds) } ?? [],
            "visitedViews": visited, "viewLimitReached": visited >= 4096,
            "fieldLimitReached": fields.count >= 512, "fields": fields]
    }
}
