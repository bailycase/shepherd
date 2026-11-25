import AppKit
import QuartzCore

/// What a gesture's frames do to the window's Core Animation layers, counted so a budget holds on a busy machine:
/// layers whose size changed (a layout pass reached them), shadows Core Animation had to render again offscreen (a shadow with
/// no `shadowPath` is drawn from its layer's alpha, again whenever the layer's size or content changes), and layers whose
/// bitmap was replaced.
@MainActor
final class LayerWatch {
    struct Frame: Equatable {
        /// Visible layers whose size changed since the last frame.
        var resized = 0
        /// Visible layers casting a shadow with no `shadowPath` whose size or bitmap changed: each is an offscreen shadow render.
        var shadowRenders = 0
        /// Visible layers whose bitmap was replaced.
        var redrawn = 0
        /// Layers casting a shadow from a path sized at layout: no offscreen render, whatever changes.
        var pathShadows = 0
        /// Layers that round or mask what is inside them (a clip with a corner radius, a mask) with something in them that moved or
        /// changed: Core Animation draws such a group offscreen, then masks it, again for each frame it changes.
        var maskedGroups = 0

        static func + (a: Frame, b: Frame) -> Frame {
            Frame(resized: a.resized + b.resized, shadowRenders: a.shadowRenders + b.shadowRenders,
                  redrawn: a.redrawn + b.redrawn, pathShadows: a.pathShadows + b.pathShadows,
                  maskedGroups: a.maskedGroups + b.maskedGroups)
        }
    }

    private struct Seen {
        var size: CGSize
        var origin: CGPoint
        var position: CGPoint
        var contents: ObjectIdentifier?
    }

    private var seen: [ObjectIdentifier: Seen] = [:]
    private(set) var total = Frame()
    private(set) var frames = 0
    private(set) var worst = Frame()
    /// The shadows drawn again, by size and blur: what a failing budget names.
    private(set) var shadowKinds: [String: Int] = [:]

    init(_ window: OffscreenWindow) { _ = sample(window) }

    /// Records what changed since the last call as one frame.
    @discardableResult
    func frame(_ window: OffscreenWindow) -> Frame {
        let frame = sample(window)
        total = total + frame
        frames += 1
        worst = Frame(resized: max(worst.resized, frame.resized), shadowRenders: max(worst.shadowRenders, frame.shadowRenders),
                      redrawn: max(worst.redrawn, frame.redrawn), pathShadows: max(worst.pathShadows, frame.pathShadows),
                      maskedGroups: max(worst.maskedGroups, frame.maskedGroups))
        return frame
    }

    var summary: String {
        let n = Double(max(frames, 1))
        let kinds = shadowKinds.isEmpty ? "" : " [" + shadowKinds.sorted { $0.value > $1.value }.prefix(6).map { "\($0.key) ×\($0.value)" }.joined(separator: ", ") + "]"
        return String(format: "resized %.1f · shadow renders %.2f · redrawn %.1f · masked groups %.2f per frame (worst %d · %d · %d · %d), %d frames",
                      Double(total.resized) / n, Double(total.shadowRenders) / n, Double(total.redrawn) / n, Double(total.maskedGroups) / n,
                      worst.resized, worst.shadowRenders, worst.redrawn, worst.maskedGroups, frames) + kinds
    }

    private func note(_ layer: CALayer) {
        let kind = String(format: "%.0fx%.0f blur %.0f", layer.bounds.width.rounded(), layer.bounds.height.rounded(), layer.shadowRadius)
        shadowKinds[kind, default: 0] += 1
    }

    private func sample(_ window: OffscreenWindow) -> Frame {
        var frame = Frame()
        var next: [ObjectIdentifier: Seen] = [:]
        /// Whether anything in `layer`'s subtree changed since the last frame.
        @discardableResult
        func walk(_ layer: CALayer) -> Bool {
            guard !layer.isHidden else { return false }
            let id = ObjectIdentifier(layer)
            let contents = layer.contents.map { ObjectIdentifier($0 as AnyObject) }
            let now = Seen(size: layer.bounds.size, origin: layer.bounds.origin, position: layer.position, contents: contents)
            next[id] = now
            let casts = layer.shadowOpacity > 0
            if casts && layer.shadowPath != nil { frame.pathShadows += 1 }
            var changed = false
            if let before = seen[id] {
                let resized = before.size != now.size
                let replaced = before.contents != contents
                if resized { frame.resized += 1 }
                if replaced { frame.redrawn += 1 }
                if casts && layer.shadowPath == nil && (resized || replaced) { frame.shadowRenders += 1; note(layer) }
                changed = resized || replaced || before.origin != now.origin || before.position != now.position
            } else {
                changed = true
                if casts && layer.shadowPath == nil {
                    frame.shadowRenders += 1
                    note(layer)
                }
            }
            for sublayer in layer.sublayers ?? [] where walk(sublayer) { changed = true }
            let masks = (layer.cornerRadius > 0 && layer.masksToBounds) || layer.mask != nil || layer.shouldRasterize
            if masks && changed { frame.maskedGroups += 1 }
            return changed
        }
        window.host.layer.map { walk($0) }
        seen = next
        return frame
    }
}
