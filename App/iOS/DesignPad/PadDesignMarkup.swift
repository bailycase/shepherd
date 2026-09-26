import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdUI

// The seam for Pencil markup (P5d; iPadDesign's ink, "Read your markup", Apply both · Keep as
// comments). Nothing is drawn here yet.
//
// - **Where it sits:** over the canvas, under the header, above the boards, rings and pins, and
//   the same size as the canvas (`PadDesignCanvasView`).
// - **What it gets:** `PadDesignMarkupContext`, the canvas's viewport (canvas ↔ screen points)
//   and every board's frame on the canvas, so a stroke maps onto a board and, through the
//   board's hit test (`PadDesignCanvas.host.hitTest`), onto an element: the anchor a proposed
//   comment carries (`DesignCommentDraft`).
// - **Which touches it gets:** the canvas takes fingers and pointers only
//   (`NWCanvasTouchInput.touchTypes`), so an Apple Pencil's touches fall through to this layer
//   whatever it holds; a PencilKit canvas here that allows `.pencil` alone never stops a finger
//   from panning.
// - **What it may write:** nothing directly. Proposed comments go through
//   `PadDesignCanvas.submitComment`-style writes (`designs.v1` `addComment`), the same server
//   path and checks as any comment, fenced as data for the agent.

/// What the markup layer knows about the canvas under it.
struct PadDesignMarkupContext: Equatable {
    var design: PadDesignRef
    var viewport: NWCanvasViewport
    /// Each board on the page, by path, in canvas points.
    var boards: [DesignPath: CGRect]
    /// The board presented focused (Present, Play), when one is: markup waits for the canvas.
    var presented: DesignPath?
}

/// The Pencil markup layer over the canvas. Empty until P5d builds it.
struct PadDesignMarkupLayer: View {
    let context: PadDesignMarkupContext

    var body: some View {
        EmptyView()
    }
}
