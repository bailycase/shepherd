import SwiftUI

// A question from pi or an extension in the composer's place, for touch (the Mobile, iPad and Duo
// question boards): a raised card with the attention dot and the question, its details folded, then
// the asker's answers as radio rows you choose and confirm with Answer (or Skip). Shepherd has no
// permission model: the rows are the answers the asker offered, never an approval it did not.

public enum SHTouchQuestionMetrics {
    /// An option's number, in a rounded square (a yes or a no).
    public static let numberSize: CGFloat = 24
    /// A yes or a no card's minimum height.
    public static let optionHeight: CGFloat = 56
    /// The card (the boards' `.gt-dcard`): radius 20, 14pt over its head, 8pt at the sides, 10pt under its footer.
    public static let cardRadius: CGFloat = 20
    public static let cardPadding = EdgeInsets(top: 14, leading: SH.Space.m, bottom: 10, trailing: SH.Space.m)
    /// The head: the 8pt dot 7pt down, 10pt before the question, which sits 8pt in from the card's padding.
    public static let dot: CGFloat = 8
    public static let dotTop: CGFloat = 7
    public static let headSpacing: CGFloat = 10
    public static let headInset: CGFloat = SH.Space.m
    /// An answer row (`.gt-op`): 10pt over and under, 8pt at the sides, 12pt after its radio, radius 12.
    public static let rowPadding = EdgeInsets(top: 10, leading: SH.Space.m, bottom: 10, trailing: SH.Space.m)
    public static let rowSpacing: CGFloat = SH.Space.l
    public static let rowRadius: CGFloat = SH.Radius.l
    public static let detailSize: CGFloat = 13
    /// The radio: 20pt with a 1.5pt line; picked, a 6pt ring.
    public static let radio: CGFloat = 20
    public static let radioLine: CGFloat = 1.5
    public static let radioPickedRing: CGFloat = 6
    /// Skip and Answer, 16pt apart, 8pt under the rows.
    public static let footerSpacing: CGFloat = SH.Space.xl
    public static let footerTop: CGFloat = SH.Space.m
    /// Hide the question and Show the question: a 40pt circle, an 18pt chevron.
    public static let hideButton: CGFloat = 40
    public static let hideGlyph: CGFloat = 18
    /// A pill button (Answer, a subagent's suggested reply): 36pt, 14pt at its sides.
    public static let pillHeight: CGFloat = 36
    public static let pillPadding: CGFloat = 14
    /// A yes or a no, side by side.
    public static let yesNoHeight: CGFloat = 48
}

/// The card: the head is the attention dot over the question (`SHQuestionHeading`), with Hide the question at its trailing end
/// when `hide` is given, a button that folds the question and never answers it. `count` says "1 of N" when several wait.
public struct SHQuestionCard<Content: View>: View {
    let count: Int
    let question: String
    let hide: (() -> Void)?
    let content: Content

    public init(count: Int = 1, question: String, hide: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.count = count
        self.question = question
        self.hide = hide
        self.content = content()
    }

    public var body: some View {
        let M = SHTouchQuestionMetrics.self
        VStack(alignment: .leading, spacing: SH.Space.l) {
            HStack(alignment: .top, spacing: SH.Space.s) {
                SHQuestionHeading(count: count, question: question)
                if let hide {
                    SHQuestionCardToggle(hidden: false, action: hide)
                        // The circle (a 44pt touch target on iOS) overhangs the head rather than making it taller.
                        .frame(height: SHQuestionHeadMetrics.height)
                }
            }
            .padding(.horizontal, M.headInset)
            content
        }
        .padding(M.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { SHQuestionCardFill() }
        .accessibilityElement(children: .contain)
    }
}

/// A question folded on iPad (Hide the question) so you can read the thread. It still holds
/// the composer's place, because the agent is still waiting: the question card around one
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
            SHStatusDot(.attention, size: SHTouchQuestionMetrics.dot)
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
        .background { SHQuestionCardFill() }
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
            SHTurningChevron(isOpen: !hidden, closed: .up, open: .down)
                .font(.system(size: SHTouchQuestionMetrics.hideGlyph, weight: .medium))
        }
        .buttonStyle(.shIcon(size: SHTouchQuestionMetrics.hideButton))
        .help(label)
        .accessibilityLabel(label)
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

/// A pill button on touch (the boards' `.gt-btn`): 36pt tall, 14pt at its sides, 14 medium. `.primary` is the ink fill (Answer);
/// `.secondary` is `bgSelected` (a suggested reply). It dims with its press and while disabled.
public struct SHTouchPillStyle: ButtonStyle {
    public enum Kind: Sendable { case primary, secondary }

    let kind: Kind

    public init(_ kind: Kind) { self.kind = kind }

    public func makeBody(configuration: Configuration) -> some View {
        SHTouchPill(configuration: configuration, kind: kind)
    }
}

extension ButtonStyle where Self == SHTouchPillStyle {
    public static func shTouchPill(_ kind: SHTouchPillStyle.Kind) -> SHTouchPillStyle { SHTouchPillStyle(kind) }
}

private struct SHTouchPill: View {
    let configuration: ButtonStyleConfiguration
    let kind: SHTouchPillStyle.Kind
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let sh = Color.sh
        let primary = kind == .primary
        let M = SHTouchQuestionMetrics.self
        configuration.label
            .font(.sh(.ui))
            .lineLimit(1)
            .foregroundStyle(primary ? (enabled ? sh.textOnPrimary : sh.textTertiary) : sh.textPrimary)
            .padding(.horizontal, M.pillPadding)
            .frame(minHeight: M.pillHeight)
            .background(primary ? (enabled ? sh.primary : sh.bgSelected) : sh.bgSelected, in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Capsule())
            .shTouchTarget(height: M.pillHeight)
    }
}
