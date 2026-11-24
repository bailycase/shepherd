import SwiftUI

/// The command palette's measures (GXPalette): a 680pt card 112pt from the top of the window over the
/// scrim, never taller than the window leaves room for. A 58pt search row, 40pt result rows, a 42pt
/// footer naming the row that ↵ runs.
public enum SHPaletteMetrics {
    public static let width: CGFloat = 680
    public static let top: CGFloat = 112
    public static let searchHeight: CGFloat = 58
    #if os(macOS)
    public static let sectionHeight: CGFloat = 30
    #else
    public static let sectionHeight: CGFloat = 24
    #endif
    public static let rowHeight: CGFloat = 40
    public static let footerHeight: CGFloat = 42
    /// The results' inset inside the card: 2pt above, 8pt beside and below.
    public static let listTop: CGFloat = 2
    public static let listSide: CGFloat = 8
    public static let listBottom: CGFloat = 8
    /// Kept clear below the card and beside it in a narrow window.
    public static let margin: CGFloat = 16
    /// The tallest list, in rows, before it scrolls.
    public static let maxVisibleRows = 14
    /// A row's icon tile and the gap after it; a row's detail line starts at `titleInset`, under the title.
    public static let tile: CGFloat = 26
    public static let tileGlyph: CGFloat = 13
    public static let iconGap: CGFloat = 12
    public static var titleInset: CGFloat { tile + iconGap }
    public static let rowRadius: CGFloat = 9
    public static let rowInset: CGFloat = 10
    /// The search row: its glyph, field size and insets.
    public static let searchGlyph: CGFloat = 17
    public static let searchFont: CGFloat = 18
    public static let searchLeading: CGFloat = 18
    public static let searchTrailing: CGFloat = 14
    public static let searchGap: CGFloat = 12
    /// The scope control: segments 24pt tall, radius 6.
    public static let scopeHeight: CGFloat = 24
    public static let scopeInset: CGFloat = 9
    public static let scopeRadius: CGFloat = 6
    public static let keyRadius: CGFloat = 5
    public static let keySize: CGFloat = 20
    public static let keyPadding: CGFloat = 5
    /// A row's shortcut: 12pt with 0.04em of tracking.
    public static let shortcutTracking: CGFloat = 0.48
    public static let footerLeading: CGFloat = 18
    /// The card's rows, search and footer: what the list leaves out of the card's height.
    public static var chrome: CGFloat { searchHeight + footerHeight + listTop + listBottom }

    public struct Placement: Equatable, Sendable {
        public let top: CGFloat
        public let width: CGFloat
        /// The results list's height cap (the card adds the search row, footer and padding).
        public let maxListHeight: CGFloat
    }

    /// Where the card sits in a container of `size`, with rows of `rowHeight`. The list keeps
    /// room for at least one row however short the window.
    public static func placement(in size: CGSize, rowHeight: CGFloat) -> Placement {
        let width = max(0, min(Self.width, size.width - 2 * margin))
        let room = size.height - top - margin - chrome
        let natural = rowHeight * CGFloat(maxVisibleRows)
        return Placement(top: top, width: width, maxListHeight: max(rowHeight, min(natural, room)))
    }
}

extension EnvironmentValues {
    /// The results list's height cap inside `.shCommandPalette`.
    @Entry public var shPaletteMaxListHeight: CGFloat = 392
}

extension View {
    /// Presents `content` (the palette card) over a scrim, 112pt from the top and capped to the
    /// window. Clicking the scrim dismisses. The card grows from its top edge and the scrim fades
    /// (`.overlay`; a cross-fade under Reduce Motion) whichever path presents or dismisses it.
    public func shCommandPalette<Content: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        overlay {
            SHPaletteOverlay(isPresented: isPresented.wrappedValue, dismiss: { isPresented.wrappedValue = false }, content: content)
        }
    }
}

private struct SHPaletteOverlay<Content: View>: View {
    let isPresented: Bool
    let dismiss: () -> Void
    @ViewBuilder let content: () -> Content

    /// Always mounted, so the scrim and the card come and go with their transitions.
    var body: some View {
        let _ = SHRenderProbe.tick("paletteOverlay")
        GeometryReader { geo in
            let placement = SHPaletteMetrics.placement(in: geo.size, rowHeight: SHPaletteMetrics.rowHeight)
            ZStack(alignment: .top) {
                if isPresented {
                    Color.sh.paletteScrim
                        .contentShape(Rectangle())
                        .onTapGesture(perform: dismiss)
                        .accessibilityHidden(true)
                        .shTransition(.content)
                    content()
                        .frame(width: placement.width)
                        .environment(\.shPaletteMaxListHeight, placement.maxListHeight)
                        // VoiceOver stays inside the palette while it is up.
                        .accessibilityAddTraits(.isModal)
                        .shTransition(.overlay, anchor: .top)
                        .padding(.top, placement.top)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .ignoresSafeArea()
        .allowsHitTesting(isPresented)
        .shAnimation(.overlay, value: isPresented)
    }
}

/// The palette card: the search row across the top, the results inset by 8pt, and the footer. A raised
/// card at radius 16 on a `lineSubtle` border.
public struct SHPaletteCard<Search: View, Results: View, Footer: View>: View {
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
                .frame(height: M.searchHeight)
            results()
                .padding(.top, M.listTop)
                .padding(.horizontal, M.listSide)
                .padding(.bottom, M.listBottom)
            footer()
        }
        .shPopover(radius: SH.Radius.xxl, line: .sh.lineSubtle)
    }
}

/// The palette's search row: a glass and the field at 18pt, with the scope control trailing.
public struct SHPaletteSearchRow<Accessory: View>: View {
    let placeholder: String
    @Binding var text: String
    let focus: FocusState<Bool>.Binding
    let submit: () -> Void
    @ViewBuilder let accessory: () -> Accessory

    public init(_ placeholder: String, text: Binding<String>, focus: FocusState<Bool>.Binding,
                submit: @escaping () -> Void, @ViewBuilder accessory: @escaping () -> Accessory) {
        self.placeholder = placeholder
        _text = text
        self.focus = focus
        self.submit = submit
        self.accessory = accessory
    }

    public var body: some View {
        let M = SHPaletteMetrics.self
        HStack(spacing: M.searchGap) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: M.searchGlyph, weight: .regular))
                .foregroundStyle(.sh.textPrimary)
                .accessibilityHidden(true)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.shSans(M.searchFont))
                .foregroundStyle(.sh.textPrimary)
                .tint(.sh.lantern)
                .focused(focus)
                .onSubmit(submit)
                .accessibilityLabel(placeholder)
            accessory()
        }
        .padding(.leading, M.searchLeading)
        .padding(.trailing, M.searchTrailing)
    }
}

/// The scope control beside the search field (All · Commands · Agents): 12pt words, the chosen one in
/// medium ink on a `bgSelected` pill.
public struct SHPaletteScope<Value: Hashable>: View {
    @Binding var selection: Value
    let label: String
    let options: [(value: Value, title: String)]

    public init(_ label: String, selection: Binding<Value>, options: [(Value, String)]) {
        self.label = label
        _selection = selection
        self.options = options.map { (value: $0.0, title: $0.1) }
    }

    public var body: some View {
        let M = SHPaletteMetrics.self
        HStack(spacing: SH.Space.xxs) {
            ForEach(Array(options.enumerated()), id: \.element.value) { _, option in
                let chosen = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.title)
                        .font(.sh(.caption, weight: chosen ? .medium : .regular))
                        .foregroundStyle(chosen ? Color.sh.textPrimary : Color.sh.textSecondary)
                        .lineLimit(1)
                        .padding(.horizontal, M.scopeInset)
                        .frame(height: M.scopeHeight)
                        .background(chosen ? Color.sh.bgSelected : .clear, in: RoundedRectangle(cornerRadius: M.scopeRadius))
                        .contentShape(RoundedRectangle(cornerRadius: M.scopeRadius))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// A results group label ("Commands"): 12pt medium in tertiary, 30pt tall with the words at its foot. The
/// phone and iPad palettes keep their 10pt mono caps.
public struct SHPaletteSectionHeader: View {
    let title: String

    public init(_ title: String) { self.title = title }

    public var body: some View {
        #if os(macOS)
        Text(title)
            .font(.sh(.caption, weight: .medium))
            .foregroundStyle(.sh.textTertiary)
            .lineLimit(1)
            .padding(.horizontal, SHPaletteMetrics.rowInset)
            .padding(.bottom, SH.Space.s)
            .frame(maxWidth: .infinity, minHeight: SHPaletteMetrics.sectionHeight, alignment: .bottomLeading)
            .accessibilityAddTraits(.isHeader)
        #else
        Text(title)
            .font(.shMono(10, .medium))
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(.sh.textTertiary)
            .lineLimit(1)
            .padding(.horizontal, SH.Space.m)
            .frame(maxWidth: .infinity, minHeight: SHPaletteMetrics.sectionHeight, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
        #endif
    }
}

/// One palette result: a 26pt tile with the icon, the label, dim context, and the real shortcut as plain
/// text. The highlighted row is `bgSelected`. A button.
public struct SHPaletteRow<Detail: View>: View {
    let systemImage: String
    let title: String
    let context: String?
    let shortcut: String?
    let highlighted: Bool
    let iconColor: Color?
    let action: () -> Void
    @ViewBuilder let detail: () -> Detail

    public init(_ title: String, systemImage: String, context: String? = nil, shortcut: String? = nil,
                highlighted: Bool = false, iconColor: Color? = nil, action: @escaping () -> Void,
                @ViewBuilder detail: @escaping () -> Detail) {
        self.systemImage = systemImage
        self.title = title
        self.context = context
        self.shortcut = shortcut
        self.highlighted = highlighted
        self.iconColor = iconColor
        self.action = action
        self.detail = detail
    }

    public var body: some View {
        let _ = SHRenderProbe.tick("palette.row")
        let M = SHPaletteMetrics.self
        Button(action: action) {
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                HStack(spacing: M.iconGap) {
                    Image(systemName: systemImage)
                        .font(.system(size: M.tileGlyph, weight: .regular))
                        .foregroundStyle(iconColor ?? Color.sh.textSecondary)
                        .frame(width: M.tile, height: M.tile)
                        .background(Color.sh.bgHover, in: RoundedRectangle(cornerRadius: SH.Radius.s))
                        .shBorder(Color.sh.lineSubtle, radius: SH.Radius.s)
                        .accessibilityHidden(true)
                    Text(title)
                        .font(.sh(.body))
                        .foregroundStyle(.sh.textPrimary)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if let context {
                        Text(context)
                            .font(.sh(.ui, weight: .regular))
                            .foregroundStyle(.sh.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: SH.Space.l)
                    if let shortcut {
                        Text(shortcut)
                            .font(.sh(.caption))
                            .tracking(M.shortcutTracking)
                            .foregroundStyle(.sh.textTertiary)
                            .lineLimit(1)
                    }
                }
                .frame(minHeight: M.rowHeight)
                detail()
            }
            .padding(.horizontal, M.rowInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(highlighted ? Color.sh.bgSelected : .clear, in: RoundedRectangle(cornerRadius: M.rowRadius))
            .contentShape(RoundedRectangle(cornerRadius: M.rowRadius))
        }
        .buttonStyle(SHPlainPressStyle())
        .accessibilityLabel([title, context].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(highlighted ? .isSelected : [])
    }
}

extension SHPaletteRow where Detail == EmptyView {
    public init(_ title: String, systemImage: String, context: String? = nil, shortcut: String? = nil,
                highlighted: Bool = false, iconColor: Color? = nil, action: @escaping () -> Void) {
        self.init(title, systemImage: systemImage, context: context, shortcut: shortcut, highlighted: highlighted,
                  iconColor: iconColor, action: action, detail: { EmptyView() })
    }
}

/// The card's foot: "Esc to close" on the left, and on the right the row ↵ runs, in medium ink beside
/// its key. On `bgHover` under a rule.
public struct SHPaletteFooter: View {
    let runs: String?

    public init(runs: String?) { self.runs = runs }

    public var body: some View {
        let M = SHPaletteMetrics.self
        HStack(spacing: SH.Space.l) {
            Text("Esc to close")
                .font(.sh(.caption))
                .foregroundStyle(.sh.textTertiary)
            Spacer(minLength: SH.Space.l)
            if let runs {
                HStack(spacing: SH.Space.m) {
                    Text(runs)
                        .font(.sh(.ui, weight: .medium))
                        .foregroundStyle(.sh.textPrimary)
                        .lineLimit(1)
                    Text("↵")
                        .font(.sh(.micro, weight: .regular))
                        .foregroundStyle(.sh.textSecondary)
                        .padding(.horizontal, M.keyPadding)
                        .frame(minWidth: M.keySize, minHeight: M.keySize)
                        .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: M.keyRadius))
                        .shBorder(Color.sh.lineSubtle, radius: M.keyRadius)
                        .accessibilityHidden(true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Return runs \(runs)")
            }
        }
        .padding(.leading, M.footerLeading)
        .padding(.trailing, M.rowInset)
        .frame(height: M.footerHeight)
        .background(Color.sh.bgHover)
        .overlay(alignment: .top) { SHHairline() }
    }
}
