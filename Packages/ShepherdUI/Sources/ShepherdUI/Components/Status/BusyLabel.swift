import SwiftUI

/// A busy word: "Loading…", "Saving…", "Checking…". Nothing in Shepherd spins; work in progress is
/// words that shimmer (`shShimmer(active:)`, a Core Animation band that rests while its layout is
/// hidden and is plain under Reduce Motion). Use it where a busy place has no words of its own;
/// where it does, shimmer those instead.
public struct SHBusyLabel: View {
    let title: String
    let font: Font?

    public init(_ title: String, font: Font? = nil) {
        self.title = title
        self.font = font
    }

    public var body: some View {
        Text(title)
            .font(font ?? .sh(.caption))
            .lineLimit(1)
            .shShimmer(active: true)
    }
}
