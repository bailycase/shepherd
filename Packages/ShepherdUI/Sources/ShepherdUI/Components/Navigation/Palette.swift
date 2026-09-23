import SwiftUI

/// The command palette's placement (Composer board, `.nwCommandPalette`): 620pt wide, 18% from
/// the top of the window over the scrim, and never taller than the window leaves room for.
public enum NWPaletteMetrics {
    public static let width: CGFloat = 620
    public static let topFraction: CGFloat = 0.18
    public static let searchHeight: CGFloat = 44
    public static let sectionHeight: CGFloat = 24
    /// The card's inner padding around the results.
    public static let padding: CGFloat = 6
    /// Kept clear below the card and beside it in a narrow window.
    public static let margin: CGFloat = 16
    /// The tallest list, in rows, before it scrolls.
    public static let maxVisibleRows = 14

    public struct Placement: Equatable, Sendable {
        public let top: CGFloat
        public let width: CGFloat
        /// The results list's height cap (the card adds the search row and padding).
        public let maxListHeight: CGFloat
    }

    /// Where the card sits in a container of `size`, with rows of `rowHeight`. The list keeps
    /// room for at least one row however short the window.
    public static func placement(in size: CGSize, rowHeight: CGFloat) -> Placement {
        let top = (max(0, size.height) * topFraction).rounded()
        let width = max(0, min(Self.width, size.width - 2 * margin))
        let room = size.height - top - margin - searchHeight - 2 * padding
        let natural = rowHeight * CGFloat(maxVisibleRows)
        return Placement(top: top, width: width, maxListHeight: max(rowHeight, min(natural, room)))
    }
}

extension EnvironmentValues {
    /// The results list's height cap inside `.nwCommandPalette`.
    @Entry public var nwPaletteMaxListHeight: CGFloat = 392
}

extension View {
    /// Presents `content` (the palette card) over a scrim, 18% from the top and capped to the
    /// window. Clicking the scrim dismisses.
    public func nwCommandPalette<Content: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        overlay {
            if isPresented.wrappedValue {
                NWPaletteOverlay(dismiss: { isPresented.wrappedValue = false }, content: content)
            }
        }
    }
}

private struct NWPaletteOverlay<Content: View>: View {
    let dismiss: () -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.nwDensity) private var density

    var body: some View {
        GeometryReader { geo in
            let placement = NWPaletteMetrics.placement(in: geo.size, rowHeight: density.rowHeight)
            ZStack(alignment: .top) {
                Color.nw.scrim
                    .contentShape(Rectangle())
                    .onTapGesture(perform: dismiss)
                    .accessibilityHidden(true)
                content()
                    .frame(width: placement.width)
                    .environment(\.nwPaletteMaxListHeight, placement.maxListHeight)
                    .padding(.top, placement.top)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .ignoresSafeArea()
    }
}

/// The palette card: the search row across the top, a rule, then the results inset by 6pt.
/// `.nwPopover()` chrome at radius 12.
public struct NWPaletteCard<Search: View, Results: View>: View {
    @ViewBuilder let search: () -> Search
    @ViewBuilder let results: () -> Results

    public init(@ViewBuilder search: @escaping () -> Search, @ViewBuilder results: @escaping () -> Results) {
        self.search = search
        self.results = results
    }

    public var body: some View {
        VStack(spacing: 0) {
            search()
                .frame(height: NWPaletteMetrics.searchHeight)
            NWHairline()
            results()
                .padding(NWPaletteMetrics.padding)
        }
        .nwPopover(radius: NW.Radius.l)
    }
}

/// The palette's search row: a 15pt glass and field, with the scope control trailing.
public struct NWPaletteSearchRow<Accessory: View>: View {
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
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.nw.textSecondary)
                .accessibilityHidden(true)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.nwSans(15))
                .foregroundStyle(.nw.textPrimary)
                .tint(.nw.lantern)
                .focused(focus)
                .onSubmit(submit)
                .accessibilityLabel(placeholder)
            accessory()
        }
        .padding(.horizontal, 10)
    }
}

/// A results group label ("COMMANDS"): 10pt mono caps in tertiary, 24pt.
public struct NWPaletteSectionHeader: View {
    let title: String

    public init(_ title: String) { self.title = title }

    public var body: some View {
        Text(title)
            .font(.nwMono(10, .medium))
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(.nw.textTertiary)
            .lineLimit(1)
            .padding(.horizontal, NW.Space.m)
            .frame(maxWidth: .infinity, minHeight: NWPaletteMetrics.sectionHeight, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One palette result: icon, label, dim context, and the real shortcut as keycaps. The
/// highlighted row is running tint with a running icon. A button.
public struct NWPaletteRow<Detail: View>: View {
    let systemImage: String
    let title: String
    let context: String?
    let shortcut: String?
    let highlighted: Bool
    let iconColor: Color?
    let action: () -> Void
    @ViewBuilder let detail: () -> Detail
    @Environment(\.nwDensity) private var density

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
        Button(action: action) {
            VStack(alignment: .leading, spacing: NW.Space.xxs) {
                HStack(spacing: 10) {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(iconColor ?? (highlighted ? Color.nw.running : Color.nw.textSecondary))
                        .frame(width: 14)
                    Text(title)
                        .font(density.rowTitleFont())
                        .foregroundStyle(.nw.textPrimary)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if let context {
                        Text(context)
                            .font(.nwSans(12))
                            .foregroundStyle(.nw.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: NW.Space.l)
                    if let shortcut { NWKeycap(shortcut) }
                }
                .frame(minHeight: density.rowHeight)
                detail()
            }
            .padding(.horizontal, NW.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(highlighted ? Color.nw.runningTint : .clear, in: RoundedRectangle(cornerRadius: NW.Radius.s))
            .contentShape(RoundedRectangle(cornerRadius: NW.Radius.s))
        }
        .buttonStyle(NWPlainPressStyle())
        .accessibilityLabel([title, context].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(highlighted ? .isSelected : [])
    }
}

extension NWPaletteRow where Detail == EmptyView {
    public init(_ title: String, systemImage: String, context: String? = nil, shortcut: String? = nil,
                highlighted: Bool = false, iconColor: Color? = nil, action: @escaping () -> Void) {
        self.init(title, systemImage: systemImage, context: context, shortcut: shortcut, highlighted: highlighted,
                  iconColor: iconColor, action: action, detail: { EmptyView() })
    }
}
