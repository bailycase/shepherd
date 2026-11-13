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

/// What a composer field last measured, kept while what it was measured for holds: the `key`, which is everything
/// but the width that the answer depends on (the text, by a revision that each edit bumps, and the style it is drawn
/// in), and the width. A layout pass asks a field's size more than once for the same edit; only the first ask has to
/// lay the text out.
public struct SHComposerFitCache<Key: Equatable, Answer> {
    /// The widths one edit keeps an answer for: the ones a layout pass tries in turn.
    public static var widths: Int { 4 }

    private var measuredFor: Key?
    private var answers: [CGFloat: Answer] = [:]

    public init() {}

    /// The answer at `width` for `key`. `measure` runs only when that is not the answer last given, and its result is kept.
    public mutating func answer(width: CGFloat, key: Key, measure: () -> Answer) -> Answer {
        if measuredFor == key {
            if let known = answers[width] { return known }
        } else {
            measuredFor = key
            answers.removeAll(keepingCapacity: true)
        }
        let answer = measure()
        if answers.count >= Self.widths { answers.removeAll(keepingCapacity: true) }
        answers[width] = answer
        return answer
    }
}
