import SwiftUI

// A question from pi or an extension in the composer's place, for touch (MobileQuestion,
// iPadQuestion boards): "Agent is asking" in lantern, the question, then the asker's answers as
// numbered cards you choose and confirm with Answer. Shepherd has no permission model: the
// cards are the answers the asker offered, never an approval it did not.

public enum SHTouchQuestionMetrics {
    /// An option's number, in a rounded square.
    public static let numberSize: CGFloat = 24
    /// An option card's minimum height.
    public static let optionHeight: CGFloat = 56
    /// The width past which a wide panel lays options side by side (iPad).
    public static let columnMinWidth: CGFloat = 220
    /// How far a docked panel's fill and line run past its bottom, under the home indicator and
    /// off the screen.
    public static let dockOverhang: CGFloat = 64
    /// The docked panel's top corners (MobileQuestion).
    public static let dockRadius: CGFloat = 18
    /// Hide the question and Show the question on iPad's card: a 40pt circle, an 18pt chevron.
    public static let hideButton: CGFloat = 40
    public static let hideGlyph: CGFloat = 18
    /// The folded card's glyph.
    public static let hiddenGlyph: CGFloat = 14
    /// The docked panel's grabber (MobileQuestion): a 36×5 capsule, hit across a 44pt row.
    public static let grabber = CGSize(width: 36, height: 5)
    /// How far down a drag on the grabber must go to hide the question.
    public static let grabberDragToHide: CGFloat = 24
    /// A yes or a no, side by side.
    public static let yesNoHeight: CGFloat = 48
}

/// The panel: on a phone it is docked to the bottom edge with its top corners rounded, a lantern
/// line along them and a grabber (MobileQuestion); on iPad a card with a lantern line all around
/// (iPadQuestion). The head says "Agent is asking"; `count` shows "1 / N" when several questions wait. `hide` folds the question
/// and never answers it: on iPad a 40pt circle trailing the head (Hide the question), docked a
/// tap on the grabber or a drag down from it.
public struct SHQuestionCard<Content: View>: View {
    let docked: Bool
    let count: Int
    let hide: (() -> Void)?
    let content: Content

    public init(docked: Bool, count: Int = 1, hide: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.docked = docked
        self.count = count
        self.hide = hide
        self.content = content()
    }

    public var body: some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: SH.Space.l) {
            if docked {
                SHQuestionGrabber(hide: hide)
                    // The grabber's row sits in the panel's top padding, 8pt under its edge.
                    .padding(.top, -SH.Space.xs)
                    .padding(.bottom, -SH.Space.xs)
            }
            HStack(spacing: SH.Space.s) {
                HStack(spacing: SH.Space.s) {
                    SHQuestionAskerGlyph(size: SHQuestionHeadMetrics.glyph)
                    Text(SHQuestionHead.title).font(.sh(.caption, weight: .semibold)).foregroundStyle(sh.lanternText)
                        .lineLimit(1)
                    Spacer(minLength: SH.Space.m)
                    if count > 1 {
                        Text("1 / \(count)").font(.sh(.mono)).foregroundStyle(sh.textTertiary).monospacedDigit()
                            .shContentTransition(.numeric())
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(count > 1 ? "\(SHQuestionHead.title), 1 of \(count)" : SHQuestionHead.title)
                .accessibilityAddTraits(.isHeader)
                if !docked, let hide {
                    SHQuestionCardToggle(hidden: false, action: hide)
                        // The circle (a 44pt touch target on iOS) overhangs the head rather than
                        // making it taller.
                        .frame(height: SHQuestionHeadMetrics.height)
                }
            }
            .frame(minHeight: SHQuestionHeadMetrics.height)
            content
        }
        .padding(.horizontal, SH.Space.xl)
        .padding(.top, docked ? SH.Space.m : SH.Space.xl)
        .padding(.bottom, docked ? SH.Space.m : SH.Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { SHTouchQuestionCardChrome(docked: docked) }
        .accessibilityElement(children: .contain)
    }
}

/// The docked panel's grabber: a 36×5 capsule in `lineStrong`. With somewhere to go (`hide`),
/// a tap or a drag down folds the question; without, it only draws.
private struct SHQuestionGrabber: View {
    let hide: (() -> Void)?

    var body: some View {
        let capsule = Capsule().fill(Color.sh.lineStrong)
            .frame(width: SHTouchQuestionMetrics.grabber.width, height: SHTouchQuestionMetrics.grabber.height)
        if let hide {
            Button(action: hide) {
                capsule
                    .frame(maxWidth: .infinity, minHeight: SH.Height.touch - SH.Space.l)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .simultaneousGesture(DragGesture(minimumDistance: SH.Space.m).onEnded { value in
                if value.translation.height > SHTouchQuestionMetrics.grabberDragToHide { hide() }
            })
            .accessibilityLabel("Hide the question")
        } else {
            capsule.frame(maxWidth: .infinity).accessibilityHidden(true)
        }
    }
}

/// A question folded on iPad (Hide the question) so you can read the thread. It still holds
/// the composer's place, because the agent is still waiting: the card's lantern line around one
/// row of the question mark, the question (truncating), a small **Answer**, and Show the
/// question; either button unfolds it.
public struct SHQuestionCardHiddenLine: View {
    let question: String
    let show: () -> Void

    public init(question: String, show: @escaping () -> Void) {
        self.question = question
        self.show = show
    }

    public var body: some View {
        let sh = Color.sh
        HStack(spacing: SH.Space.l) {
            SHQuestionAskerGlyph(size: SHTouchQuestionMetrics.hiddenGlyph)
                .accessibilityHidden(true)
            Text(question).font(.sh(.headline)).foregroundStyle(sh.textPrimary)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("\(SHQuestionHead.title): \(question)")
            Button("Answer", action: show)
                .buttonStyle(.sh(.secondary, size: .m))
                .accessibilityLabel("Answer the question")
            SHQuestionCardToggle(hidden: true, action: show)
        }
        .padding(.leading, SH.Space.xl)
        .padding(.trailing, SH.Space.xs)
        .padding(.vertical, SH.Space.xxs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { SHTouchQuestionCardChrome(docked: false) }
        .accessibilityElement(children: .contain)
    }
}

/// Hide the question (a chevron down) or Show the question (up): a 40pt circle.
private struct SHQuestionCardToggle: View {
    let hidden: Bool
    let action: () -> Void

    var body: some View {
        let label = hidden ? "Show the question" : "Hide the question"
        Button(action: action) {
            Image(systemName: hidden ? "chevron.up" : "chevron.down")
                .font(.system(size: SHTouchQuestionMetrics.hideGlyph, weight: .medium))
        }
        .buttonStyle(.shIcon(size: SHTouchQuestionMetrics.hideButton))
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The card's fill and lantern line. Docked, the panel runs on under the home indicator: its
/// line runs only along the top and around its corners, and the thread's content is shadowed
/// under its edge (MobileQuestion).
private struct SHTouchQuestionCardChrome: View {
    let docked: Bool

    var body: some View {
        let sh = Color.sh
        if docked {
            let radius = SHTouchQuestionMetrics.dockRadius
            let shape = UnevenRoundedRectangle(cornerRadii: RectangleCornerRadii(topLeading: radius, topTrailing: radius))
            shape.fill(sh.bgRaised)
                .shFloatShadow()
                .overlay {
                    shape.strokeBorder(sh.lantern, lineWidth: SHThreadMetrics.ruleWidth)
                        .mask(alignment: .top) { Rectangle().frame(height: radius) }
                }
                .padding(.bottom, -SHTouchQuestionMetrics.dockOverhang)
                .allowsHitTesting(false)
        } else {
            let shape = RoundedRectangle(cornerRadius: SH.Radius.l)
            shape.fill(sh.bgRaised)
                .overlay { shape.strokeBorder(sh.lantern, lineWidth: SHThreadMetrics.ruleWidth) }
                .allowsHitTesting(false)
        }
    }
}

/// One answer the asker offered: its number, "Recommended" when the asker said so, the title,
/// and a description under it; a tap picks it (`action`). Picked, it takes a lantern line and
/// tint, and its number fills.
public struct SHQuestionOptionCard: View {
    let number: Int
    let title: String
    let detail: String?
    let recommended: Bool
    let selected: Bool
    let action: () -> Void

    public init(number: Int, title: String, detail: String? = nil, recommended: Bool = false, selected: Bool = false,
                action: @escaping () -> Void) {
        self.number = number
        self.title = title
        self.detail = detail
        self.recommended = recommended
        self.selected = selected
        self.action = action
    }

    public var body: some View {
        let sh = Color.sh
        let shape = RoundedRectangle(cornerRadius: SH.Radius.m)
        VStack(alignment: .leading, spacing: SH.Space.m) {
            Button(action: action) {
                HStack(alignment: .top, spacing: SH.Space.l) {
                    SHQuestionNumber(number, filled: selected)
                    VStack(alignment: .leading, spacing: SH.Space.xs) {
                        if recommended {
                            Text("Recommended").font(.sh(.caption, weight: .semibold)).foregroundStyle(sh.lanternText)
                                .padding(.horizontal, SH.Space.s)
                                .padding(.vertical, SH.Space.xxs)
                                .background(sh.lanternTint, in: RoundedRectangle(cornerRadius: SH.Radius.xs))
                        }
                        Text(title).font(.sh(.ui, weight: .semibold)).foregroundStyle(sh.textPrimary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        if let detail {
                            Text(detail).font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textSecondary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(number). \(title)\(recommended ? ", recommended" : "")")
            .accessibilityHint(detail ?? "")
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        }
        .padding(SH.Space.l)
        // Side by side (iPad), the cards of a row share its height.
        .frame(maxWidth: .infinity, minHeight: SHTouchQuestionMetrics.optionHeight, maxHeight: .infinity, alignment: .topLeading)
        .background(selected ? sh.lanternTint : sh.bgWindow, in: shape)
        .shBorder(selected ? sh.lantern : sh.lineSubtle, radius: SH.Radius.m)
        .shAnimation(.hover, value: selected)
        .contentShape(shape)
    }
}

/// An option's number in a rounded square: outlined, or filled with lantern once chosen.
public struct SHQuestionNumber: View {
    let number: Int
    let filled: Bool

    public init(_ number: Int, filled: Bool = false) {
        self.number = number
        self.filled = filled
    }

    public var body: some View {
        let sh = Color.sh
        let shape = RoundedRectangle(cornerRadius: SH.Radius.xs)
        Text("\(number)").font(.sh(.mono, weight: .medium)).monospacedDigit()
            .foregroundStyle(filled ? sh.textOnLantern : sh.textSecondary)
            // Grows with the text at large sizes rather than clipping the number.
            .padding(SH.Space.xxs)
            .frame(minWidth: SHTouchQuestionMetrics.numberSize, minHeight: SHTouchQuestionMetrics.numberSize)
            .background(filled ? sh.lantern : Color.clear, in: shape)
            .shBorder(filled ? sh.lantern : sh.lineStrong, in: shape)
            .accessibilityHidden(true)
    }
}
