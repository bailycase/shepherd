import SwiftUI

/// Jump to a board (JumpInContext): the toolbar's field over a design, and the card it opens.
/// Measures as the board draws them.
public enum NWJumpMetrics {
    // The toolbar's field: 260 by 30, radius 8, 10pt in, a 14pt glass, the words in 12.5 and the
    // chord in mono 10.5; a 1px `running` ring while the card is open.
    public static let fieldWidth: CGFloat = 260
    public static let fieldMinWidth: CGFloat = 80
    public static let fieldHeight: CGFloat = 30
    public static let fieldRadius: CGFloat = NW.Radius.m
    public static let fieldPadding: CGFloat = 10
    public static let fieldGlyph: CGFloat = 14
    public static let fieldTextSize: CGFloat = 12.5
    public static let fieldChordSize: CGFloat = 10.5
    /// The board's 14pt glass is a 16-unit icon with a 1.5 stroke; the SF Symbol matches it 2pt
    /// smaller in its 14pt frame.
    public static let glyphInset: CGFloat = 2

    // The card: 620 wide, 15% down the window (150 of the board's 1000) over the sheet's scrim.
    public static let width: CGFloat = 620
    public static let topFraction: CGFloat = 0.15
    /// The search row: 48pt, 14pt in, a 14pt glass 10pt before the field in 14.
    public static let searchHeight: CGFloat = 48
    public static let searchPadding: CGFloat = 14
    public static let searchGlyph: CGFloat = 14
    public static let searchTextSize: CGFloat = 14
    /// The scope pills: 24pt, 10pt in, radius 12, 12pt words, 2pt apart.
    public static let scopeHeight: CGFloat = 24
    public static let scopePadding: CGFloat = 10
    public static let scopeTextSize: CGFloat = 12
    public static let scopeSpacing: CGFloat = 2
    /// Above and below a pill: its hit area clears the desktop's 24pt minimum.
    public static let scopeHitSlop: CGFloat = 1
    /// The list: 4pt above, 8pt at the sides and below.
    public static let listTop: CGFloat = 4
    public static let listInset: CGFloat = NW.Space.m
    /// A section's caps: mono 10.5 tracked 0.06em, 10pt in, 10pt above and 4pt below.
    public static let sectionTextSize: CGFloat = 10.5
    public static let sectionTracking: CGFloat = 0.63
    public static let sectionTop: CGFloat = 10
    public static let sectionBottom: CGFloat = 4
    /// A row: 44pt, 10pt in, radius 8, 12pt between its picture and words; the picture 44 by 28 at
    /// radius 4; the name in 13 (semibold while highlighted), its line in mono 10.5.
    public static let rowHeight: CGFloat = 44
    public static let rowPadding: CGFloat = 10
    public static let rowRadius: CGFloat = NW.Radius.m
    public static let rowSpacing: CGFloat = 12
    public static let picture = CGSize(width: 44, height: 28)
    public static let pictureRadius: CGFloat = NW.Radius.xs
    public static let titleSize: CGFloat = 13
    public static let metaSize: CGFloat = 10.5
    /// The highlighted row's ⏎: mono 10.5 in a 1px `lineStrong` box, radius 4, 1 by 6 padding.
    public static let returnPaddingH: CGFloat = NW.Space.s
    public static let returnPaddingV: CGFloat = 1
    /// The footer: 34pt, 14pt in, hints 14pt apart in 11.5.
    public static let footerHeight: CGFloat = 34
    public static let footerSpacing: CGFloat = 14
    public static let footerTextSize: CGFloat = 11.5
    /// Rows the card shows before its list scrolls.
    public static let maxVisibleRows = 9
}

/// The toolbar's "Jump to a board…" field over a design: a button that opens the card, with the
/// chord that does the same. Lit with a `running` ring while the card is open.
public struct NWJumpField: View {
    let shortcut: String?
    let isOpen: Bool
    let action: () -> Void

    public init(shortcut: String?, isOpen: Bool, action: @escaping () -> Void) {
        self.shortcut = shortcut
        self.isOpen = isOpen
        self.action = action
    }

    public var body: some View {
        let M = NWJumpMetrics.self
        let nw = Color.nw
        let shape = RoundedRectangle(cornerRadius: M.fieldRadius)
        Button(action: action) {
            HStack(spacing: NW.Space.m) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: M.fieldGlyph - NWJumpMetrics.glyphInset))
                    .frame(width: M.fieldGlyph, height: M.fieldGlyph)
                Text("Jump to a board…")
                    .font(.nwSans(M.fieldTextSize))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if let shortcut {
                    Text(shortcut)
                        .font(.nwMono(M.fieldChordSize))
                        .foregroundStyle(nw.textTertiary)
                        .fixedSize()
                }
            }
            .foregroundStyle(nw.textSecondary)
            .padding(.horizontal, M.fieldPadding)
            .frame(maxWidth: M.fieldWidth, minHeight: M.fieldHeight, maxHeight: M.fieldHeight)
            .background(nw.bgRaised, in: shape)
            .nwBorder(nw.lineStrong, in: shape)
            .overlay {
                if isOpen { shape.inset(by: -1).strokeBorder(nw.running, lineWidth: 1).allowsHitTesting(false) }
            }
            .contentShape(shape)
        }
        .buttonStyle(NWPlainPressStyle())
        .frame(minWidth: M.fieldMinWidth, maxWidth: M.fieldWidth)
        .accessibilityLabel("Jump to a board")
        .nwHelp("Jump to a board", shortcut: shortcut)
    }
}

/// The card (JumpInContext): the search row with its scope pills, a rule, the list, a rule, and
/// the footer's hints. `.nwPopover()` chrome at radius 12.
public struct NWJumpCard<Search: View, Results: View, Footer: View>: View {
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
        let M = NWJumpMetrics.self
        VStack(spacing: 0) {
            search()
                .padding(.horizontal, M.searchPadding)
                .frame(height: M.searchHeight)
            NWHairline()
            results()
                .padding(.top, M.listTop)
                .padding([.horizontal, .bottom], M.listInset)
            NWHairline()
            footer()
                .font(.nwSans(M.footerTextSize))
                .foregroundStyle(Color.nw.textTertiary)
                .padding(.horizontal, M.searchPadding)
                .frame(maxWidth: .infinity, minHeight: M.footerHeight, alignment: .leading)
        }
        .nwPopover(radius: NW.Radius.l)
    }
}

/// The search row's glass and field ("Jump to a board or a design…").
public struct NWJumpSearchField: View {
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
        let M = NWJumpMetrics.self
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: M.searchGlyph - NWJumpMetrics.glyphInset))
                .foregroundStyle(.nw.textSecondary)
                .frame(width: M.searchGlyph, height: M.searchGlyph)
                .accessibilityHidden(true)
            // The board's placeholder is `textTertiary`; a plain field would draw it in the
            // field's own color.
            TextField(placeholder, text: $text, prompt: Text(placeholder).foregroundStyle(Color.nw.textTertiary))
                .textFieldStyle(.plain)
                .font(.nwSans(M.searchTextSize))
                .foregroundStyle(.nw.textPrimary)
                .tint(.nw.lantern)
                .focused(focus)
                .onSubmit(submit)
                .accessibilityLabel(placeholder)
        }
    }
}

/// The scope pills ("This design", "All designs"): the chosen one on `bgBubble` with a
/// `lineStrong` line in `textPrimary` medium, the others clear in `textSecondary`.
public struct NWJumpScopes<ID: Hashable>: View {
    let options: [(id: ID, title: String)]
    @Binding var selection: ID

    public init(_ options: [(id: ID, title: String)], selection: Binding<ID>) {
        self.options = options
        _selection = selection
    }

    public var body: some View {
        let M = NWJumpMetrics.self
        let nw = Color.nw
        HStack(spacing: M.scopeSpacing) {
            ForEach(options, id: \.id) { option in
                let on = option.id == selection
                Button { selection = option.id } label: {
                    Text(option.title)
                        .font(.nwSans(M.scopeTextSize, on ? .medium : .regular))
                        .foregroundStyle(on ? nw.textPrimary : nw.textSecondary)
                        .padding(.horizontal, M.scopePadding)
                        .frame(height: M.scopeHeight)
                        .background(on ? nw.bgBubble : .clear, in: Capsule())
                        .nwBorder(on ? nw.lineStrong : .clear, in: Capsule())
                        // The pill draws 24pt; its hit area keeps the desktop's 24pt minimum
                        // with a point to spare, so rounding never takes it under.
                        .padding(.vertical, NWJumpMetrics.scopeHitSlop)
                        .contentShape(Rectangle())
                }
                .buttonStyle(NWPlainPressStyle())
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Scope")
    }
}

/// A section's caps ("RECENT", "OTHER BOARDS 3"): mono 10.5 tracked, `textTertiary`.
public struct NWJumpSectionHeader: View {
    let title: String
    let count: Int?

    public init(_ title: String, count: Int? = nil) {
        self.title = title
        self.count = count
    }

    public var body: some View {
        let M = NWJumpMetrics.self
        HStack(spacing: NW.Space.s) {
            Text(title).textCase(.uppercase).tracking(M.sectionTracking)
            if let count { Text("\(count)") }
        }
        .font(.nwMono(M.sectionTextSize))
        .foregroundStyle(.nw.textTertiary)
        .lineLimit(1)
        .padding(.horizontal, M.rowPadding)
        .padding(.top, M.sectionTop)
        .padding(.bottom, M.sectionBottom)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One board or design: its picture, its name over its line in mono, and, trailing, ⏎ while
/// highlighted or its tag ("this board"). The highlight fills `bgSelected`. A button.
public struct NWJumpRow: View {
    let title: String
    let meta: String
    let tag: String?
    let picture: NWReferenceImage?
    let highlighted: Bool
    let action: () -> Void

    public init(_ title: String, meta: String, tag: String? = nil, picture: NWReferenceImage?, highlighted: Bool,
                action: @escaping () -> Void) {
        self.title = title
        self.meta = meta
        self.tag = tag
        self.picture = picture
        self.highlighted = highlighted
        self.action = action
    }

    public var body: some View {
        let M = NWJumpMetrics.self
        let nw = Color.nw
        let shape = RoundedRectangle(cornerRadius: M.rowRadius)
        Button(action: action) {
            HStack(spacing: M.rowSpacing) {
                NWReferenceThumbnail(picture, size: M.picture, radius: M.pictureRadius)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.nwSans(M.titleSize, highlighted ? .semibold : .regular))
                        .foregroundStyle(nw.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(meta)
                        .font(.nwMono(M.metaSize))
                        .foregroundStyle(nw.textTertiary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if highlighted {
                    Text("⏎")
                        .font(.nwMono(M.metaSize))
                        .foregroundStyle(nw.textSecondary)
                        .padding(.horizontal, M.returnPaddingH)
                        .padding(.vertical, M.returnPaddingV)
                        .nwBorder(nw.lineStrong, radius: NW.Radius.xs)
                        .accessibilityHidden(true)
                } else if let tag {
                    Text(tag)
                        .font(.nwMono(M.metaSize))
                        .foregroundStyle(nw.textTertiary)
                }
            }
            .padding(.horizontal, M.rowPadding)
            .frame(maxWidth: .infinity, minHeight: M.rowHeight, alignment: .leading)
            .background(highlighted ? nw.bgSelected : .clear, in: shape)
            .contentShape(shape)
        }
        .buttonStyle(NWPlainPressStyle())
        .accessibilityLabel([title, meta, tag].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(highlighted ? .isSelected : [])
    }
}

/// A footer hint: its keys in mono, then what they do ("↑↓ move").
public struct NWJumpHint: View {
    let keys: String
    let label: String

    public init(_ keys: String, _ label: String) {
        self.keys = keys
        self.label = label
    }

    public var body: some View {
        HStack(spacing: NW.Space.xs) {
            Text(keys).font(.nwMono(NWJumpMetrics.footerTextSize))
            Text(label)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}
