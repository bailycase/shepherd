import SwiftUI
import ShepherdUI

// The surfaces the touch boards share (the gt- cards, rows, switch and floating bar of
// MobileChanges, MobilePRDetail, MobileIssue, MobileIPList): the Changes, Commit and Issues & PRs
// screens all draw them.

/// A card of rows: 16pt corners on the lift, a hairline between rows inset to the text.
struct ReviewCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content()) { subviews in
                ForEach(subviews) { subview in
                    if subview.id != subviews.first?.id { ReviewRowRule() }
                    subview
                }
            }
        }
        .shCard(radius: MobileLayout.touchCardRadius, lift: true)
    }
}

/// `ReviewCard` for a list that can run long: one view per element of a lazy stack.
struct ReviewLazyCard<Data: RandomAccessCollection, Row: View>: View where Data.Element: Identifiable {
    let data: Data
    @ViewBuilder let row: (Data.Element) -> Row

    init(_ data: Data, @ViewBuilder row: @escaping (Data.Element) -> Row) {
        self.data = data
        self.row = row
    }

    var body: some View {
        let first = data.first?.id
        LazyVStack(spacing: 0) {
            ForEach(data) { element in
                VStack(spacing: 0) {
                    if element.id != first { ReviewRowRule() }
                    row(element)
                }
            }
        }
        .shCard(radius: MobileLayout.touchCardRadius, lift: true)
    }
}

/// The rule between a card's rows, inset to where their text starts.
struct ReviewRowRule: View {
    var body: some View {
        SHHairline().padding(.leading, MobileLayout.gutter)
    }
}

/// A card's padded block (a comment, a note): 14 over 16.
extension View {
    func reviewCardPadding() -> some View {
        padding(.horizontal, MobileLayout.gutter).padding(.vertical, SH.Space.l + SH.Space.xxs)
    }
}

/// A section's head above a card (the boards' quiet head): "Files" in 13 secondary, a count after
/// it, a note at the trailing edge.
struct ReviewSectionHead: View {
    let title: String
    var count: String? = nil
    var note: String? = nil
    /// What the note says where the head is too narrow for it (the half-open Duo).
    var shortNote: String? = nil

    var body: some View {
        let sh = Color.sh
        HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
            Text(title).font(.shSans(MobileLayout.touchDetailFont, .medium)).foregroundStyle(sh.textSecondary)
            if let count {
                Text(count).font(.shSans(MobileLayout.touchDetailFont)).foregroundStyle(sh.textTertiary)
            }
            Spacer(minLength: SH.Space.s)
            if let note {
                ViewThatFits(in: .horizontal) {
                    Text(note).lineLimit(1)
                    Text(shortNote ?? note).lineLimit(1).minimumScaleFactor(0.8)
                }
                .font(.shSans(MobileLayout.touchDetailFont, .medium))
                .foregroundStyle(sh.textSecondary)
            }
        }
        .padding(.horizontal, SH.Space.xs)
        .padding(.top, SH.Space.m)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The floating bar at a screen's bottom (MobileChanges' Send 1 comment | Commit…, MobilePRDetail's
/// Ask agent | Review… | Merge…): a 52pt glass capsule, its items equal, a rule between them. It
/// rides the bottom safe area, so the page scrolls under it.
struct ReviewGlassBar<Content: View>: View {
    var horizontalInset: CGFloat = MobileLayout.gutter
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 0) {
            Group(subviews: content()) { subviews in
                ForEach(subviews) { subview in
                    if subview.id != subviews.first?.id {
                        SHHairline(.vertical).frame(height: MobileLayout.touchBarRuleHeight)
                    }
                    subview
                }
            }
        }
        .reviewGlassCapsule(horizontalInset: horizontalInset)
    }
}

extension View {
    /// The bar's body: a 52pt glass capsule inset from the sides, on a fade out of the page above.
    func reviewGlassCapsule(horizontalInset: CGFloat = MobileLayout.gutter) -> some View {
        padding(.horizontal, SH.Space.xs)
            .frame(minHeight: MobileLayout.touchBarHeight)
            .glassEffect(.regular, in: Capsule())
            .padding(.horizontal, horizontalInset)
            .padding(.top, MobileLayout.touchBarFade)
            .padding(.bottom, SH.Space.xs)
            .background(
                LinearGradient(colors: [Color.sh.bgWindow.opacity(0), Color.sh.bgWindow], startPoint: .top, endPoint: .center)
                    .allowsHitTesting(false)
            )
    }
}

/// Unposted or unsent comments (MobilePRLineComments): the count, Discard and the action in the
/// glass bar, the action on an ink pill.
struct ReviewCommentsBar: View {
    let count: String
    let detail: String
    var sending = false
    let sendTitle: String
    let onDiscard: () -> Void
    let onSend: () -> Void

    var body: some View {
        let sh = Color.sh
        HStack(spacing: SH.Space.l) {
            Image(systemName: "bubble.left")
                .font(.shSans(MobileLayout.touchBodyFont + 2))
                .foregroundStyle(sh.textSecondary)
                .padding(.leading, SH.Space.m)
                .accessibilityHidden(true)
            (Text(count).font(.shSans(MobileLayout.touchBodyFont, .semibold)).foregroundStyle(sh.textPrimary)
                + Text(detail.isEmpty ? "" : " \(detail)").font(.shSans(MobileLayout.touchDetailFont)).foregroundStyle(sh.textSecondary))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: SH.Space.s)
            Button("Discard", action: onDiscard)
                .font(.shSans(MobileLayout.touchBodyFont))
                .foregroundStyle(sh.textSecondary)
                .buttonStyle(.plain)
                .disabled(sending)
                .accessibilityHint("Deletes the comments you haven't sent")
            Button(action: onSend) { Text(sendTitle).shShimmer(active: sending) }
                .buttonStyle(.reviewCompactPill)
                .disabled(sending)
        }
        .padding(.trailing, SH.Space.xs)
        .reviewGlassCapsule()
    }
}

/// One item of the glass bar: its title over the item's whole share of the bar. `emphasis` is the
/// bar's main action in semibold; `dim` an action set back in secondary.
struct ReviewGlassBarItem: View {
    enum Emphasis { case regular, main, dim }

    let title: String
    var emphasis: Emphasis = .regular
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let sh = Color.sh
        Button(action: action) {
            Text(title)
                .font(.shSans(MobileLayout.touchBodyFont, emphasis == .main ? .semibold : emphasis == .dim ? .regular : .medium))
                .foregroundStyle(emphasis == .dim ? sh.textSecondary : sh.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: SH.Height.touch)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : MobileLayout.touchDisabledOpacity)
    }
}

/// The full-width switch (Issues | Pull requests, Summary | Changes | Checks): a 36pt capsule on
/// the selected tint, the chosen segment a raised pill on the lift. Each segment's count or word
/// follows its title in tertiary.
struct ReviewSegmented<Value: Hashable>: View {
    struct Option: Identifiable {
        let value: Value
        let title: String
        /// "5" or "1 failed".
        var note: String? = nil
        var id: Value { value }
    }

    @Binding var selection: Value
    let options: [Option]

    var body: some View {
        let sh = Color.sh
        HStack(spacing: SH.Space.xxs) {
            ForEach(options) { option in
                let selected = option.value == selection
                Button { selection = option.value } label: {
                    HStack(spacing: SH.Space.xs) {
                        Text(option.title)
                            .font(.shSans(MobileLayout.touchDetailFont, .medium))
                            .foregroundStyle(selected ? sh.textPrimary : sh.textSecondary)
                            .lineLimit(1)
                        if let note = option.note {
                            Text(note).font(.shSans(MobileLayout.touchDetailFont)).foregroundStyle(sh.textTertiary).lineLimit(1)
                        }
                    }
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background {
                        Capsule().fill(Color.sh.bgRaised)
                            .shadow(color: .sh.liftNear, radius: 1, y: 1)
                            .opacity(selected ? 1 : 0)
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.note.map { "\(option.title), \($0)" } ?? option.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(MobileLayout.touchSegmentInset)
        .frame(height: MobileLayout.touchSegmentHeight)
        .background(sh.bgSelected, in: Capsule())
    }
}

/// The sheet's one big action (Commit & push, Merge when ready, Submit review): a 50pt ink capsule
/// at 15 semibold; unavailable it goes to the selected tint with tertiary words, not faded.
struct ReviewPrimaryPillStyle: ButtonStyle {
    /// The iPad's popover and bars size it to its words, 40pt tall; the phone's fills the width.
    var compact = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let sh = Color.sh
        configuration.label
            .font(.shSans(MobileLayout.touchBodyFont, .semibold))
            .foregroundStyle(enabled ? sh.textOnPrimary : sh.textTertiary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, compact ? SH.Space.xl + SH.Space.xs : 0)
            .frame(maxWidth: compact ? nil : .infinity, minHeight: compact ? MobileLayout.touchCompactHeight : MobileLayout.touchPrimaryHeight)
            .background(enabled ? (configuration.isPressed ? sh.primaryPressed : sh.primary) : sh.bgSelected, in: Capsule())
            .contentShape(Capsule())
    }
}

extension ButtonStyle where Self == ReviewPrimaryPillStyle {
    static var reviewPrimaryPill: ReviewPrimaryPillStyle { ReviewPrimaryPillStyle() }
    static var reviewCompactPill: ReviewPrimaryPillStyle { ReviewPrimaryPillStyle(compact: true) }
}

/// A reason, as a card (MobilePRMerge's "Merging is blocked"): a red glyph, the title in semibold,
/// the words under it in secondary.
struct ReviewNoticeCard: View {
    let title: String
    let message: String

    var body: some View {
        let sh = Color.sh
        HStack(alignment: .top, spacing: SH.Space.l) {
            Image(systemName: "exclamationmark.triangle")
                .font(.shSans(MobileLayout.touchBodyFont + 1))
                .foregroundStyle(sh.failed)
                .padding(.top, SH.Space.xxs)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SH.Space.xs) {
                Text(title).font(.shSans(MobileLayout.touchBodyFont, .semibold)).foregroundStyle(sh.textPrimary)
                Text(message)
                    .font(.shSans(MobileLayout.touchBodyFont))
                    .lineSpacing(SH.Space.xxs)
                    .foregroundStyle(sh.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .reviewCardPadding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .shCard(radius: MobileLayout.touchCardRadius, lift: true)
        .accessibilityElement(children: .combine)
    }
}
