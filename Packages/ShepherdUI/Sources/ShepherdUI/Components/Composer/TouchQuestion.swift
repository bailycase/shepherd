import SwiftUI

// A question from pi or an extension in the composer's place, for touch (MobileQuestion,
// iPadQuestion boards): "Agent is asking" in lantern, the question, then the asker's answers as
// numbered cards you choose and confirm with Answer. Shepherd has no permission model: the
// cards are the answers the asker offered, never an approval it did not.

public enum NWTouchQuestionMetrics {
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
    /// Something else…'s card, at least this tall (MobileQuestion's 46pt).
    public static let otherHeight: CGFloat = 46
    /// A yes or a no, side by side.
    public static let yesNoHeight: CGFloat = 48
}

/// The panel: on a phone it is docked to the bottom edge with its top corners rounded, a lantern
/// line along them and a grabber (MobileQuestion); on iPad a card with a lantern line all around
/// (iPadQuestion). The head names the asker ("Agent is asking", or a subagent's name with the
/// branch glyph); `count` shows "1 / N" when several questions wait. `hide` folds the question
/// and never answers it: on iPad a 40pt circle trailing the head (Hide the question), docked a
/// tap on the grabber or a drag down from it.
public struct NWQuestionCard<Content: View>: View {
    let docked: Bool
    let count: Int
    let asker: NWQuestionAsker
    let hide: (() -> Void)?
    let content: Content

    public init(docked: Bool, count: Int = 1, asker: NWQuestionAsker = .agent, hide: (() -> Void)? = nil,
                @ViewBuilder content: () -> Content) {
        self.docked = docked
        self.count = count
        self.asker = asker
        self.hide = hide
        self.content = content()
    }

    public var body: some View {
        let nw = Color.nw
        VStack(alignment: .leading, spacing: NW.Space.l) {
            if docked {
                NWQuestionGrabber(hide: hide)
                    // The grabber's row sits in the panel's top padding, 8pt under its edge.
                    .padding(.top, -NW.Space.xs)
                    .padding(.bottom, -NW.Space.xs)
            }
            HStack(spacing: NW.Space.s) {
                HStack(spacing: NW.Space.s) {
                    NWQuestionAskerGlyph(asker: asker, size: NWQuestionHeadMetrics.glyph)
                    Text(asker.title).font(.nw(.caption, weight: .semibold)).foregroundStyle(nw.lanternText)
                        .lineLimit(1)
                    Spacer(minLength: NW.Space.m)
                    if count > 1 {
                        Text("1 / \(count)").font(.nw(.mono)).foregroundStyle(nw.textTertiary).monospacedDigit()
                            .nwContentTransition(.numeric())
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(count > 1 ? "\(asker.title), 1 of \(count)" : asker.title)
                .accessibilityAddTraits(.isHeader)
                if !docked, let hide {
                    NWQuestionCardToggle(hidden: false, action: hide)
                        // The circle (a 44pt touch target on iOS) overhangs the head rather than
                        // making it taller.
                        .frame(height: NWQuestionHeadMetrics.height)
                }
            }
            .frame(minHeight: NWQuestionHeadMetrics.height)
            content
        }
        .padding(.horizontal, NW.Space.xl)
        .padding(.top, docked ? NW.Space.m : NW.Space.xl)
        .padding(.bottom, docked ? NW.Space.m : NW.Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { NWTouchQuestionCardChrome(docked: docked) }
        .accessibilityElement(children: .contain)
    }
}

/// The docked panel's grabber: a 36×5 capsule in `lineStrong`. With somewhere to go (`hide`),
/// a tap or a drag down folds the question; without, it only draws.
private struct NWQuestionGrabber: View {
    let hide: (() -> Void)?

    var body: some View {
        let capsule = Capsule().fill(Color.nw.lineStrong)
            .frame(width: NWTouchQuestionMetrics.grabber.width, height: NWTouchQuestionMetrics.grabber.height)
        if let hide {
            Button(action: hide) {
                capsule
                    .frame(maxWidth: .infinity, minHeight: NW.Height.touch - NW.Space.l)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .simultaneousGesture(DragGesture(minimumDistance: NW.Space.m).onEnded { value in
                if value.translation.height > NWTouchQuestionMetrics.grabberDragToHide { hide() }
            })
            .accessibilityLabel("Hide the question")
        } else {
            capsule.frame(maxWidth: .infinity).accessibilityHidden(true)
        }
    }
}

/// A question folded on iPad (Hide the question) so you can read the thread. It still holds
/// the composer's place, because the agent is still waiting: the card's lantern line around one
/// row of the asker's glyph, the question (truncating), a small **Answer**, and Show the
/// question; either button unfolds it.
public struct NWQuestionCardHiddenLine: View {
    let asker: NWQuestionAsker
    let question: String
    let show: () -> Void

    public init(asker: NWQuestionAsker = .agent, question: String, show: @escaping () -> Void) {
        self.asker = asker
        self.question = question
        self.show = show
    }

    public var body: some View {
        let nw = Color.nw
        HStack(spacing: NW.Space.l) {
            NWQuestionAskerGlyph(asker: asker, size: NWTouchQuestionMetrics.hiddenGlyph)
                .accessibilityHidden(true)
            Text(question).font(.nw(.headline)).foregroundStyle(nw.textPrimary)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("\(asker.title): \(question)")
            Button("Answer", action: show)
                .buttonStyle(.nw(.secondary, size: .m))
                .accessibilityLabel("Answer the question")
            NWQuestionCardToggle(hidden: true, action: show)
        }
        .padding(.leading, NW.Space.xl)
        .padding(.trailing, NW.Space.xs)
        .padding(.vertical, NW.Space.xxs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { NWTouchQuestionCardChrome(docked: false) }
        .accessibilityElement(children: .contain)
    }
}

/// Hide the question (a chevron down) or Show the question (up): a 40pt circle.
private struct NWQuestionCardToggle: View {
    let hidden: Bool
    let action: () -> Void

    var body: some View {
        let label = hidden ? "Show the question" : "Hide the question"
        Button(action: action) {
            Image(systemName: hidden ? "chevron.up" : "chevron.down")
                .font(.system(size: NWTouchQuestionMetrics.hideGlyph, weight: .medium))
        }
        .buttonStyle(.nwIcon(size: NWTouchQuestionMetrics.hideButton))
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The card's fill and lantern line. Docked, the panel runs on under the home indicator: its
/// line runs only along the top and around its corners, and the thread's content is shadowed
/// under its edge (MobileQuestion).
private struct NWTouchQuestionCardChrome: View {
    let docked: Bool

    var body: some View {
        let nw = Color.nw
        if docked {
            let radius = NWTouchQuestionMetrics.dockRadius
            let shape = UnevenRoundedRectangle(cornerRadii: RectangleCornerRadii(topLeading: radius, topTrailing: radius))
            shape.fill(nw.bgRaised)
                .nwFloatShadow()
                .overlay {
                    shape.strokeBorder(nw.lantern, lineWidth: NWThreadMetrics.ruleWidth)
                        .mask(alignment: .top) { Rectangle().frame(height: radius) }
                }
                .padding(.bottom, -NWTouchQuestionMetrics.dockOverhang)
                .allowsHitTesting(false)
        } else {
            let shape = RoundedRectangle(cornerRadius: NW.Radius.l)
            shape.fill(nw.bgRaised)
                .overlay { shape.strokeBorder(nw.lantern, lineWidth: NWThreadMetrics.ruleWidth) }
                .allowsHitTesting(false)
        }
    }
}

/// One answer the asker offered: its number, "Recommended" when the asker said so, the title,
/// and a description under it; a tap picks it (`action`). Picked, it takes a lantern line and
/// tint, and its number fills. `footer` sits inside the card under the text, outside the tap:
/// the picked option's note field (`NWQuestionNoteField`) for an asker that takes one.
public struct NWQuestionOptionCard<Footer: View>: View {
    let number: Int
    let title: String
    let detail: String?
    let recommended: Bool
    let selected: Bool
    let action: () -> Void
    let footer: Footer

    public init(number: Int, title: String, detail: String? = nil, recommended: Bool = false, selected: Bool = false,
                action: @escaping () -> Void, @ViewBuilder footer: () -> Footer) {
        self.number = number
        self.title = title
        self.detail = detail
        self.recommended = recommended
        self.selected = selected
        self.action = action
        self.footer = footer()
    }

    public var body: some View {
        let nw = Color.nw
        let shape = RoundedRectangle(cornerRadius: NW.Radius.m)
        VStack(alignment: .leading, spacing: NW.Space.m) {
            Button(action: action) {
                HStack(alignment: .top, spacing: NW.Space.l) {
                    NWQuestionNumber(number, filled: selected)
                    VStack(alignment: .leading, spacing: NW.Space.xs) {
                        if recommended {
                            Text("Recommended").font(.nw(.caption, weight: .semibold)).foregroundStyle(nw.lanternText)
                                .padding(.horizontal, NW.Space.s)
                                .padding(.vertical, NW.Space.xxs)
                                .background(nw.lanternTint, in: RoundedRectangle(cornerRadius: NW.Radius.xs))
                        }
                        Text(title).font(.nw(.ui, weight: .semibold)).foregroundStyle(nw.textPrimary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        if let detail {
                            Text(detail).font(.nw(.ui, weight: .regular)).foregroundStyle(nw.textSecondary)
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
            footer
        }
        .padding(NW.Space.l)
        // Side by side (iPad), the cards of a row share its height.
        .frame(maxWidth: .infinity, minHeight: NWTouchQuestionMetrics.optionHeight, maxHeight: .infinity, alignment: .topLeading)
        .background(selected ? nw.lanternTint : nw.bgWindow, in: shape)
        .nwBorder(selected ? nw.lantern : nw.lineSubtle, radius: NW.Radius.m)
        .nwAnimation(.hover, value: selected)
        .contentShape(shape)
    }
}

extension NWQuestionOptionCard where Footer == EmptyView {
    public init(number: Int, title: String, detail: String? = nil, recommended: Bool = false, selected: Bool = false,
                action: @escaping () -> Void) {
        self.init(number: number, title: title, detail: detail, recommended: recommended, selected: selected,
                  action: action) { EmptyView() }
    }
}

/// The picked option's note (QuestionPick): a field inside its card, "Add a note…", sent with
/// the answer.
public struct NWQuestionNoteField: View {
    @Binding var text: String

    public init(text: Binding<String>) {
        _text = text
    }

    public var body: some View {
        TextField("Add a note…", text: $text, axis: .vertical)
            .lineLimit(1...4)
            .font(.nw(.ui))
            .tint(Color.nw.lantern)
            .textFieldStyle(.plain)
            .padding(.horizontal, NW.Space.m)
            .padding(.vertical, NW.Space.s)
            .background(Color.nw.bgWindow, in: RoundedRectangle(cornerRadius: NW.Radius.s))
            .nwBorder(Color.nw.lineStrong, radius: NW.Radius.s)
            .accessibilityLabel("Note with your answer")
    }
}

/// Something else… (MobileQuestion): the last row, its number and a field in place for an answer
/// in the person's own words. Typing there picks it; picked, it takes the picked style.
public struct NWQuestionOtherCard<Field: View>: View {
    let number: Int
    let selected: Bool
    let field: Field

    /// `field`: the caller's `TextField` (so it keeps the focus), drawn plain in the card.
    public init(number: Int, selected: Bool, @ViewBuilder field: () -> Field) {
        self.number = number
        self.selected = selected
        self.field = field()
    }

    public var body: some View {
        let nw = Color.nw
        HStack(spacing: NW.Space.l) {
            NWQuestionNumber(number, filled: selected)
            field
                .font(.nw(.ui))
                .tint(nw.lantern)
                .textFieldStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, NW.Space.l)
        .padding(.vertical, NW.Space.m)
        .frame(maxWidth: .infinity, minHeight: NWTouchQuestionMetrics.otherHeight, alignment: .leading)
        .background(selected ? nw.lanternTint : nw.bgWindow, in: RoundedRectangle(cornerRadius: NW.Radius.m))
        .nwBorder(selected ? nw.lantern : nw.lineSubtle, radius: NW.Radius.m)
        .nwAnimation(.hover, value: selected)
    }
}

/// An option's number in a rounded square: outlined, or filled with lantern once chosen.
public struct NWQuestionNumber: View {
    let number: Int
    let filled: Bool

    public init(_ number: Int, filled: Bool = false) {
        self.number = number
        self.filled = filled
    }

    public var body: some View {
        let nw = Color.nw
        let shape = RoundedRectangle(cornerRadius: NW.Radius.xs)
        Text("\(number)").font(.nw(.mono, weight: .medium)).monospacedDigit()
            .foregroundStyle(filled ? nw.textOnLantern : nw.textSecondary)
            // Grows with the text at large sizes rather than clipping the number.
            .padding(NW.Space.xxs)
            .frame(minWidth: NWTouchQuestionMetrics.numberSize, minHeight: NWTouchQuestionMetrics.numberSize)
            .background(filled ? nw.lantern : Color.clear, in: shape)
            .nwBorder(filled ? nw.lantern : nw.lineStrong, in: shape)
            .accessibilityHidden(true)
    }
}
