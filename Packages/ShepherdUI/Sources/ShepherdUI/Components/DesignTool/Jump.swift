import SwiftUI

/// Jump to a board (JumpInContext): the toolbar's field over a design, and the card it opens: the
/// command palette's card, with boards for its rows. Measures as the boards draw them.
public enum SHJumpMetrics {
    // The toolbar's field: 300 by 32 (`SHDesignChrome`), radius 16, 12pt in, a 14pt glass, the words in 13 and the
    // chord in 12; a 3pt `bgSelected` ring and a `textTertiary` line while the card is open.
    public static let fieldWidth: CGFloat = SHDesignChrome.jumpWidth
    public static let fieldMinWidth: CGFloat = SHDesignChrome.jumpMinWidth
    public static let fieldHeight: CGFloat = SHDesignChrome.jumpHeight
    public static let fieldRadius: CGFloat = SHDesignChrome.jumpRadius
    public static let fieldPadding: CGFloat = SHDesignChrome.jumpPadding
    public static let fieldGlyph: CGFloat = SHDesignChrome.jumpGlyph
    public static let fieldTextSize: CGFloat = SHDesignChrome.jumpTextSize
    public static let fieldChordSize: CGFloat = SHDesignChrome.jumpChordSize
    public static let fieldRing: CGFloat = SH.Space.xs - 1

    // The card is the palette's: 680 wide, 112pt down, a 58pt search row, 46pt rows, a 42pt footer.
    public static let width: CGFloat = SHPaletteMetrics.width
    public static let top: CGFloat = SHPaletteMetrics.top
    public static let searchHeight: CGFloat = SHPaletteMetrics.searchHeight
    /// A row: 46pt, 10pt in, radius 9, 12pt between its picture and words; the picture 44 by 28 at
    /// radius 5; the name in 14, its line in 12.
    public static let rowHeight: CGFloat = 46
    public static let rowPadding: CGFloat = SHPaletteMetrics.rowInset
    public static let rowRadius: CGFloat = SHPaletteMetrics.rowRadius
    public static let rowSpacing: CGFloat = SHPaletteMetrics.iconGap
    public static let picture = CGSize(width: 44, height: 28)
    public static let pictureRadius: CGFloat = 5
    public static let titleSize: CGFloat = 14
    public static let metaSize: CGFloat = 12
    public static let footerHeight: CGFloat = SHPaletteMetrics.footerHeight
    public static let footerSpacing: CGFloat = SH.Space.xl
    public static let footerTextSize: CGFloat = 12
    /// Rows the card shows before its list scrolls.
    public static let maxVisibleRows = 9
    public static let margin: CGFloat = SHPaletteMetrics.margin

    // The toast after a jump lands (JumpLanded): 40pt high, 14pt in before the words and 8 after
    // its close, 12pt apart, radius 12, the words in 13 and the chord in 12, 22pt above the
    // canvas's bottom.
    public static let backHeight: CGFloat = 40
    public static let backPaddingLeading: CGFloat = 14
    public static let backPaddingTrailing: CGFloat = SH.Space.m
    public static let backSpacing: CGFloat = SH.Space.l
    public static let backRadius: CGFloat = SH.Radius.l
    public static let backTextSize: CGFloat = 13
    public static let backChordSize: CGFloat = 12
    public static let backBottom: CGFloat = 22
    public static let backClose: CGFloat = SH.Height.controlS
}

/// The toast after a jump lands (JumpLanded): "Jumped to <board>", Back with its chord, and a close.
/// A raised card on the popover's shadow; it closes by itself too.
public struct SHJumpBackToast: View {
    let title: String
    let shortcut: String?
    let back: () -> Void
    let close: (() -> Void)?

    public init(title: String, shortcut: String?, back: @escaping () -> Void, close: (() -> Void)? = nil) {
        self.title = title
        self.shortcut = shortcut
        self.back = back
        self.close = close
    }

    public var body: some View {
        let M = SHJumpMetrics.self
        HStack(spacing: M.backSpacing) {
            Text("Jumped to \(Text(title).fontWeight(.semibold))")
                .font(.shSans(M.backTextSize))
                .foregroundStyle(Color.sh.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: SH.Space.m) {
                Button("Back", action: back)
                    .buttonStyle(.plain)
                    .font(.shSans(M.backTextSize, .medium))
                    .foregroundStyle(Color.sh.textPrimary)
                    .shHelp("Back to where you were", shortcut: shortcut)
                if let shortcut {
                    Text(shortcut)
                        .font(.shSans(M.backChordSize))
                        .foregroundStyle(Color.sh.textTertiary)
                        .accessibilityHidden(true)
                }
            }
            if let close {
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.shIcon(size: M.backClose))
                    .shHelp("Dismiss")
                    .accessibilityLabel("Dismiss")
            }
        }
        .padding(.leading, M.backPaddingLeading)
        .padding(.trailing, close == nil ? M.backPaddingLeading : M.backPaddingTrailing)
        .frame(height: M.backHeight)
        .shPopover(radius: M.backRadius, line: .sh.lineSubtle)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
    }
}

/// The toolbar's "Jump to a board…" field over a design: a button that opens the card, with the
/// chord that does the same. Lit with a ring while the card is open.
public struct SHJumpField: View {
    let shortcut: String?
    let isOpen: Bool
    let action: () -> Void

    public init(shortcut: String?, isOpen: Bool, action: @escaping () -> Void) {
        self.shortcut = shortcut
        self.isOpen = isOpen
        self.action = action
    }

    public var body: some View {
        let M = SHJumpMetrics.self
        let sh = Color.sh
        let shape = RoundedRectangle(cornerRadius: M.fieldRadius)
        Button(action: action) {
            HStack(spacing: SH.Space.m) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: M.fieldGlyph - 1))
                    .frame(width: M.fieldGlyph, height: M.fieldGlyph)
                Text("Jump to a board…")
                    .font(.shSans(M.fieldTextSize))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if let shortcut {
                    Text(shortcut)
                        .font(.shSans(M.fieldChordSize))
                        .fixedSize()
                }
            }
            .foregroundStyle(sh.textTertiary)
            .padding(.horizontal, M.fieldPadding)
            .frame(maxWidth: M.fieldWidth, minHeight: M.fieldHeight, maxHeight: M.fieldHeight)
            .shLift(shape)
            .shBorder(isOpen ? sh.textTertiary : sh.lineSubtle, in: shape)
            .overlay {
                if isOpen { shape.inset(by: -M.fieldRing / 2).strokeBorder(sh.bgSelected, lineWidth: M.fieldRing).allowsHitTesting(false) }
            }
            .contentShape(shape)
        }
        .buttonStyle(SHPlainPressStyle())
        .frame(minWidth: M.fieldMinWidth, maxWidth: M.fieldWidth)
        .accessibilityLabel("Jump to a board")
        .shHelp("Jump to a board", shortcut: shortcut)
    }
}

/// The card (JumpInContext): the palette's: the search row with its scope pills, the list inset
/// 8pt, and the footer's hints on `bgHover` under a rule.
public struct SHJumpCard<Search: View, Results: View, Footer: View>: View {
    @ViewBuilder let search: () -> Search
    @ViewBuilder let results: () -> Results
    @ViewBuilder let footer: () -> Footer

    public init(@ViewBuilder search: @escaping () -> Search, @ViewBuilder results: @escaping () -> Results,
                @ViewBuilder footer: @escaping () -> Footer) {
        self.search = search
        self.results = results
        self.footer = footer
    }

    public var body: some View {
        let M = SHPaletteMetrics.self
        VStack(spacing: 0) {
            search()
                .padding(.leading, M.searchLeading)
                .padding(.trailing, M.searchTrailing)
                .frame(height: M.searchHeight)
            results()
                .padding(.top, M.listTop)
                .padding(.horizontal, M.listSide)
                .padding(.bottom, M.listBottom)
            footer()
                .font(.shSans(SHJumpMetrics.footerTextSize))
                .foregroundStyle(Color.sh.textTertiary)
                .padding(.leading, M.footerLeading)
                .padding(.trailing, M.rowInset)
                .frame(maxWidth: .infinity, minHeight: M.footerHeight, alignment: .leading)
                .background(Color.sh.bgHover)
                .overlay(alignment: .top) { SHHairline() }
        }
        .shPopover(radius: SH.Radius.xxl, line: .sh.lineSubtle)
    }
}

/// The search row's glass and field ("Jump to a board or a design…"), as the palette's.
public struct SHJumpSearchField: View {
    let placeholder: String
    @Binding var text: String
    let focus: FocusState<Bool>.Binding
    let submit: () -> Void

    public init(_ placeholder: String, text: Binding<String>, focus: FocusState<Bool>.Binding, submit: @escaping () -> Void) {
        self.placeholder = placeholder
        _text = text
        self.focus = focus
        self.submit = submit
    }

    public var body: some View {
        let M = SHPaletteMetrics.self
        HStack(spacing: M.searchGap) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: M.searchGlyph, weight: .regular))
                .foregroundStyle(.sh.textPrimary)
                .accessibilityHidden(true)
            // The board's placeholder is `textTertiary`; a plain field would draw it in the
            // field's own color.
            TextField(placeholder, text: $text, prompt: Text(placeholder).foregroundStyle(Color.sh.textTertiary))
                .textFieldStyle(.plain)
                .font(.shSans(M.searchFont))
                .foregroundStyle(.sh.textPrimary)
                .tint(.sh.lantern)
                .focused(focus)
                .onSubmit(submit)
                .accessibilityLabel(placeholder)
        }
    }
}

/// The scope pills ("This design", "All designs"): the palette's, the chosen one on `bgSelected` in
/// `textPrimary` medium, the others clear in `textSecondary`.
public struct SHJumpScopes<ID: Hashable>: View {
    let options: [(id: ID, title: String)]
    @Binding var selection: ID

    public init(_ options: [(id: ID, title: String)], selection: Binding<ID>) {
        self.options = options
        _selection = selection
    }

    public var body: some View {
        SHPaletteScope("Scope", selection: $selection, options: options.map { ($0.id, $0.title) })
    }
}

/// A section's label ("Recent", "Other boards 3"): the palette's, 12 medium `textTertiary`, a count after it.
public struct SHJumpSectionHeader: View {
    let title: String
    let count: Int?

    public init(_ title: String, count: Int? = nil) {
        self.title = title
        self.count = count
    }

    public var body: some View {
        HStack(spacing: SH.Space.s) {
            Text(title).fontWeight(.medium)
            if let count { Text("\(count)").fontWeight(.regular) }
        }
        .font(.sh(.caption))
        .foregroundStyle(.sh.textTertiary)
        .lineLimit(1)
        .padding(.horizontal, SHPaletteMetrics.rowInset)
        .padding(.bottom, SH.Space.s)
        .frame(maxWidth: .infinity, minHeight: SHPaletteMetrics.sectionHeight, alignment: .bottomLeading)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One board or design: its picture, its name over its line, and, trailing, ↵ while highlighted or
/// its tag ("this board"). The highlight fills `bgSelected`. A button.
public struct SHJumpRow: View {
    let title: String
    let meta: String
    let tag: String?
    let picture: SHReferenceImage?
    let highlighted: Bool
    let action: () -> Void

    public init(_ title: String, meta: String, tag: String? = nil, picture: SHReferenceImage?, highlighted: Bool,
                action: @escaping () -> Void) {
        self.title = title
        self.meta = meta
        self.tag = tag
        self.picture = picture
        self.highlighted = highlighted
        self.action = action
    }

    public var body: some View {
        let M = SHJumpMetrics.self
        let sh = Color.sh
        let shape = RoundedRectangle(cornerRadius: M.rowRadius)
        Button(action: action) {
            HStack(spacing: M.rowSpacing) {
                SHReferenceThumbnail(picture, size: M.picture, radius: M.pictureRadius)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.shSans(M.titleSize))
                        .foregroundStyle(sh.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(meta)
                        .font(.shSans(M.metaSize))
                        .foregroundStyle(sh.textTertiary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if highlighted {
                    Text("↵")
                        .font(.sh(.micro, weight: .regular))
                        .foregroundStyle(sh.textSecondary)
                        .padding(.horizontal, SHPaletteMetrics.keyPadding)
                        .frame(minWidth: SHPaletteMetrics.keySize - SH.Space.xxs, minHeight: SHPaletteMetrics.keySize - SH.Space.xxs)
                        .background(sh.bgRaised, in: RoundedRectangle(cornerRadius: SHPaletteMetrics.keyRadius))
                        .shBorder(sh.lineSubtle, radius: SHPaletteMetrics.keyRadius)
                        .accessibilityHidden(true)
                } else if let tag {
                    Text(tag)
                        .font(.shSans(M.metaSize))
                        .foregroundStyle(sh.textTertiary)
                }
            }
            .padding(.horizontal, M.rowPadding)
            .frame(maxWidth: .infinity, minHeight: M.rowHeight, alignment: .leading)
            .background(highlighted ? sh.bgSelected : .clear, in: shape)
            .contentShape(shape)
        }
        .buttonStyle(SHPlainPressStyle())
        .accessibilityLabel([title, meta, tag].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(highlighted ? .isSelected : [])
    }
}

/// A footer hint: its keys, then what they do ("↑↓ move").
public struct SHJumpHint: View {
    let keys: String
    let label: String

    public init(_ keys: String, _ label: String) {
        self.keys = keys
        self.label = label
    }

    public var body: some View {
        HStack(spacing: SH.Space.xs) {
            Text(keys)
            Text(label)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}
