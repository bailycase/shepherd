import SwiftUI

// A question from pi or an extension in the composer's place, for touch (MobileQuestion,
// iPadQuestion boards): "pi is asking" in lantern, the question, then the asker's answers as
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
}

/// The panel: on a phone it is docked to the bottom edge with its top corners rounded and a
/// lantern line along them (MobileQuestion); on iPad a card with a lantern line all around
/// (iPadQuestion). `count` shows "1 / N" when several questions wait.
public struct NWQuestionCard<Content: View>: View {
    let docked: Bool
    let count: Int
    let title: String
    let content: Content

    /// `title` names the asker: "pi is asking", or a subagent's name ("reviewer is asking").
    public init(docked: Bool, count: Int = 1, title: String = "pi is asking", @ViewBuilder content: () -> Content) {
        self.docked = docked
        self.count = count
        self.title = title
        self.content = content()
    }

    public var body: some View {
        let nw = Color.nw
        let shape = UnevenRoundedRectangle(cornerRadii: RectangleCornerRadii(
            topLeading: NW.Radius.l, bottomLeading: docked ? 0 : NW.Radius.l,
            bottomTrailing: docked ? 0 : NW.Radius.l, topTrailing: NW.Radius.l))
        VStack(alignment: .leading, spacing: NW.Space.l) {
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
            content
        }
        .padding(.horizontal, docked ? NW.Space.xl : NW.Space.xl)
        .padding(.top, NW.Space.xl)
        .padding(.bottom, docked ? NW.Space.m : NW.Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            // Docked, the panel runs on under the home indicator, so its line has no bottom edge.
            shape.fill(nw.bgRaised)
                .overlay { shape.strokeBorder(nw.lantern, lineWidth: NWThreadMetrics.ruleWidth) }
                .padding(.bottom, docked ? -NWTouchQuestionMetrics.dockOverhang : 0)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
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
