import SwiftUI

/// A clip that turns off without changing the view's identity (a view that switched between
/// clipped and unclipped would be rebuilt, losing its scroll position and state). Off, it clips
/// nothing, so a background runs on under the bars the system draws in the safe area, such as
/// iPhone Duo's side bar.
struct BleedClip: Shape {
    var clips: Bool
    var cornerRadius: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        clips ? Path(roundedRect: rect, cornerRadius: cornerRadius) : Path(rect.insetBy(dx: -rect.width, dy: -rect.height))
    }
}
