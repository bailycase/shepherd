import CoreGraphics

/// How far a composer field's text must be laid out for its height. The field is as tall as its
/// words need, up to `SHComposerMetrics.fieldMaxLines`: a text with a line past the last one shown
/// is that tall however much more follows, so a sample of the text's start decides it, and the
/// sample grows only while it ends before a line past the ceiling.
public enum SHComposerFit {
    /// What the first sample holds, in the caller's units (Characters on the Mac, UTF-16 on iOS).
    public static let firstSample = 2_048

    /// The field's height. `measure` lays out the text's first `count` units and reports the height
    /// they need at the ceiling, whether they are the whole text, and whether they hold a line past
    /// the ceiling (`final`: more text cannot change the height).
    public static func height(measure: (_ count: Int) -> (height: CGFloat, whole: Bool, final: Bool)) -> CGFloat {
        var count = firstSample
        while true {
            let sample = measure(count)
            if sample.whole || sample.final { return sample.height }
            count *= 4
        }
    }
}
