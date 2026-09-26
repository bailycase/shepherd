#if os(iOS)
import SwiftUI
import UIKit

/// Every touch over the canvas on iPad (iPadDesign): a drag pans (with Select, a drag that starts
/// on a board's label, or on a board selected whole, moves the board), a pinch zooms about its
/// middle, a trackpad's two-finger scroll pans, and a tap selects. On top of the boards, so none
/// of their pages ever takes a touch.
///
/// Fingers and pointers only: an Apple Pencil's touches pass through to whatever sits over the
/// canvas for them (the Pencil markup layer), so ink never pans the canvas.
struct NWCanvasTouchInput: UIViewRepresentable {
    struct Handlers {
        var pan: (CGSize) -> Void
        var zoom: (CGFloat, CGPoint) -> Void
        var tap: (CGPoint) -> Void
        /// With Select, the board a drag starting here moves; nil pans.
        var grab: (CGPoint) -> String?
        /// A board being moved: how far the finger has gone since the drag started, and whether
        /// it has ended.
        var drag: (String, CGSize, Bool) -> Void
        var zooming: (Bool) -> Void
    }

    let tool: NWCanvasTool
    let handlers: Handlers

    /// The touch types the canvas takes: fingers, and a trackpad's or mouse's pointer.
    static let touchTypes: [NSNumber] = [UITouch.TouchType.direct, .indirect, .indirectPointer].map { NSNumber(value: $0.rawValue) }

    func makeUIView(context: Context) -> InputView {
        let view = InputView()
        view.handlers = handlers
        view.tool = tool
        return view
    }

    func updateUIView(_ view: InputView, context: Context) {
        view.handlers = handlers
        view.tool = tool
    }

    final class InputView: UIView, UIGestureRecognizerDelegate {
        var handlers: Handlers?
        var tool: NWCanvasTool = .select
        private var lastTranslation: CGPoint = .zero
        private var grabbed: String?
        private var lastScale: CGFloat = 1

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
            pan.allowedTouchTypes = NWCanvasTouchInput.touchTypes
            pan.allowedScrollTypesMask = .continuous
            pan.maximumNumberOfTouches = 2
            pan.delegate = self
            addGestureRecognizer(pan)
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
            pinch.allowedTouchTypes = NWCanvasTouchInput.touchTypes
            pinch.delegate = self
            addGestureRecognizer(pinch)
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
            tap.allowedTouchTypes = NWCanvasTouchInput.touchTypes
            addGestureRecognizer(tap)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        func gestureRecognizer(_ a: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith b: UIGestureRecognizer) -> Bool {
            // A pinch pans as it goes: its fingers' middle moves the canvas too.
            (a is UIPanGestureRecognizer && b is UIPinchGestureRecognizer) || (a is UIPinchGestureRecognizer && b is UIPanGestureRecognizer)
        }

        @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
            let translation = recognizer.translation(in: self)
            switch recognizer.state {
            case .began:
                lastTranslation = .zero
                let start = CGPoint(x: recognizer.location(in: self).x - translation.x, y: recognizer.location(in: self).y - translation.y)
                grabbed = tool == .select && recognizer.numberOfTouches <= 1 ? handlers?.grab(start) : nil
                fallthrough
            case .changed:
                if let grabbed {
                    handlers?.drag(grabbed, CGSize(width: translation.x, height: translation.y), false)
                } else {
                    handlers?.pan(CGSize(width: translation.x - lastTranslation.x, height: translation.y - lastTranslation.y))
                }
                lastTranslation = translation
            case .ended, .cancelled, .failed:
                if let grabbed { handlers?.drag(grabbed, CGSize(width: translation.x, height: translation.y), true) }
                grabbed = nil
                lastTranslation = .zero
            default:
                break
            }
        }

        @objc private func pinched(_ recognizer: UIPinchGestureRecognizer) {
            switch recognizer.state {
            case .began:
                lastScale = 1
                handlers?.zooming(true)
                fallthrough
            case .changed:
                let factor = recognizer.scale / lastScale
                lastScale = recognizer.scale
                handlers?.zoom(factor, recognizer.location(in: self))
            case .ended, .cancelled, .failed:
                lastScale = 1
                handlers?.zooming(false)
            default:
                break
            }
        }

        @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            handlers?.tap(recognizer.location(in: self))
        }
    }
}
#endif
