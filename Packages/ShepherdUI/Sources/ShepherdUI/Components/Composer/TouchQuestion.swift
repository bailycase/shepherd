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
    /// Hide the question and Show the question on iPad's card: a 40pt circle, an 18pt chevron.
    public static let hideButton: CGFloat = 40
    public static let hideGlyph: CGFloat = 18
    /// The folded card's glyph.
    public static let hiddenGlyph: CGFloat = 14
}

/// The panel: on a phone it is docked to the bottom edge with its top corners rounded and a
/// lantern line along them (MobileQuestion); on iPad a card with a lantern line all around
/// (iPadQuestion). `count` shows "1 / N" when several questions wait. On iPad, `hide` adds Hide
/// the question, a 40pt circle trailing the head, which folds the card
/// (`NWQuestionCardHiddenLine`) and never answers it.
public struct NWQuestionCard<Content: View>: View {
    let docked: Bool
    let count: Int
    let title: String
    let hide: (() -> Void)?
    let content: Content

    /// `title` names the asker: "Agent is asking", or a subagent's name ("reviewer is asking").
    public init(docked: Bool, count: Int = 1, title: String = "Agent is asking", hide: (() -> Void)? = nil,
                @ViewBuilder content: () -> Content) {
        self.docked = docked
        self.count = count
        self.title = title
        self.hide = hide
        self.content = content()
    }

    public var body: some View {
        let nw = Color.nw
        VStack(alignment: .leading, spacing: NW.Space.l) {
            HStack(spacing: NW.Space.s) {
                HStack(spacing: NW.Space.s) {
                    Label(title, systemImage: "questionmark.circle")
                        .font(.nw(.ui, weight: .semibold)).foregroundStyle(nw.lanternText)
                    Spacer(minLength: NW.Space.m)
                    if count > 1 {
                        Text("1 / \(count)").font(.nw(.mono)).foregroundStyle(nw.textTertiary).monospacedDigit()
                            .nwContentTransition(.numeric())
                    }
                }
                .accessibilityElement(children: .combine)
                if let hide {
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
        .padding(.top, NW.Space.xl)
        .padding(.bottom, docked ? NW.Space.m : NW.Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { NWQuestionCardChrome(docked: docked) }
        .accessibilityElement(children: .contain)
    }
}

/// A question folded on iPad (Hide the question) so you can read the thread. It still holds
/// the composer's place, because the agent is still waiting: the card's lantern line around one
/// row of the asker's glyph, the question (truncating), a small **Answer**, and Show the
/// question; either button unfolds it.
public struct NWQuestionCardHiddenLine: View {
    let question: String
    let show: () -> Void

    public init(question: String, show: @escaping () -> Void) {
        self.question = question
        self.show = show
    }

    public var body: some View {
        let nw = Color.nw
        HStack(spacing: NW.Space.l) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: NWTouchQuestionMetrics.hiddenGlyph, weight: .medium))
                .foregroundStyle(nw.lanternText)
                .accessibilityHidden(true)
            Text(question).font(.nw(.headline)).foregroundStyle(nw.textPrimary)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Agent is asking: \(question)")
            Button("Answer", action: show)
                .buttonStyle(.nw(.secondary, size: .m))
                .accessibilityLabel("Answer the question")
            NWQuestionCardToggle(hidden: true, action: show)
        }
        .padding(.leading, NW.Space.xl)
        .padding(.trailing, NW.Space.xs)
        .padding(.vertical, NW.Space.xxs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { NWQuestionCardChrome(docked: false) }
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

/// The card's fill and lantern line. Docked, the panel runs on under the home indicator, so its
/// line has no bottom edge.
private struct NWQuestionCardChrome: View {
    let docked: Bool

    var body: some View {
        let nw = Color.nw
        let shape = UnevenRoundedRectangle(cornerRadii: RectangleCornerRadii(
            topLeading: NW.Radius.l, bottomLeading: docked ? 0 : NW.Radius.l,
            bottomTrailing: docked ? 0 : NW.Radius.l, topTrailing: NW.Radius.l))
        shape.fill(nw.bgRaised)
            .overlay { shape.strokeBorder(nw.lantern, lineWidth: NWThreadMetrics.ruleWidth) }
            .padding(.bottom, docked ? -NWTouchQuestionMetrics.dockOverhang : 0)
            .allowsHitTesting(false)
    }
}

/// One answer the asker offered: its number, "Recommended" when the asker said so, the title,
/// and a description under it. Chosen, it takes a lantern line and tint, and its number fills.
public struct NWQuestionOptionCard: View {
    let number: Int
    let title: String
    let detail: String?
    let recommended: Bool
    let selected: Bool

    public init(number: Int, title: String, detail: String? = nil, recommended: Bool = false, selected: Bool = false) {
        self.number = number
        self.title = title
        self.detail = detail
        self.recommended = recommended
        self.selected = selected
    }

    public var body: some View {
        let nw = Color.nw
        let shape = RoundedRectangle(cornerRadius: NW.Radius.m)
        HStack(alignment: .top, spacing: NW.Space.l) {
            NWQuestionNumber(number, filled: selected)
            VStack(alignment: .leading, spacing: NW.Space.xs) {
                if recommended {
                    Text("Recommended").font(.nw(.caption, weight: .medium)).foregroundStyle(nw.lanternText)
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
        .padding(NW.Space.l)
        // Side by side (iPad), the cards of a row share its height.
        .frame(maxWidth: .infinity, minHeight: NWTouchQuestionMetrics.optionHeight, maxHeight: .infinity, alignment: .topLeading)
        .background(selected ? nw.lanternTint : nw.bgWindow, in: shape)
        .nwBorder(selected ? nw.lantern : nw.lineStrong, radius: NW.Radius.m)
        .nwAnimation(.hover, value: selected)
        .contentShape(shape)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
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
