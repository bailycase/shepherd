import SwiftUI

// A design system's page (DZSystem): its section list, token swatches, type specimens and
// component specimens, and the Designs page's "Build one from a repo" tile (NavDesigns). The
// specimens draw in the system's own look; everything around them is Shepherd Design.

/// The system page's section list: a 200pt column (16×8 padding, rows 2pt apart) with no rule beside it, as the
/// sidebar's rows are. Each row is 30pt, 10pt padding, radius 7, its title in 13 and its count trailing in 12
/// `textTertiary`; the current one on `bgSelected`, medium, in ink, the rest `textSecondary`.
public struct SHSectionRail: View {
    public struct Section: Identifiable, Equatable, Sendable {
        public let id: String
        public let title: String
        public let count: Int?

        public init(id: String, title: String, count: Int? = nil) {
            self.id = id
            self.title = title
            self.count = count
        }
    }

    let sections: [Section]
    let selection: String?
    let select: (String) -> Void

    public init(_ sections: [Section], selection: String?, select: @escaping (String) -> Void = { _ in }) {
        self.sections = sections
        self.selection = selection
        self.select = select
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.xxs) {
            ForEach(sections) { section in
                SHSectionRailRow(section: section, current: section.id == selection) { select(section.id) }
            }
        }
        .padding(.vertical, SH.Space.xl)
        .padding(.horizontal, SH.Space.m)
        .frame(width: SHDesignMetrics.railWidth, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct SHSectionRailRow: View {
    let section: SHSectionRail.Section
    let current: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SH.Radius.s)
        Button(action: action) {
            HStack(spacing: SH.Space.m) {
                Text(section.title)
                    .font(.shSans(SHDesignChrome.toolbarTextSize, current ? .medium : .regular))
                    .foregroundStyle(current ? Color.sh.textPrimary : Color.sh.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: SH.Space.m)
                if let count = section.count {
                    Text("\(count)")
                        .font(.shSans(SHDesignChrome.paneCountSize))
                        .foregroundStyle(Color.sh.textTertiary)
                }
            }
            .padding(.horizontal, SHDesignMetrics.railRowPadding)
            .frame(height: SHDesignMetrics.railRowHeight)
            .background(current ? Color.sh.bgSelected : hovering ? Color.sh.bgHover : .clear, in: shape)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .shAnimation(.hover, value: hovering)
        .accessibilityLabel(section.count.map { "\(section.title), \($0)" } ?? section.title)
        .accessibilityAddTraits(current ? .isSelected : [])
    }
}

/// A card of rows on a design system's page (DZSystem): the card fill and `lift` at radius 14 with a `lineSubtle`
/// line, holding its rows (`SHTypeSpecimen` and the like) with nothing between them.
public struct SHDesignSystemTable<Content: View>: View {
    let content: Content

    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .shCard(radius: SH.Radius.xl, lift: true)
    }
}

/// A token read from a design system (SHTokenSwatch; DZSystem): a 44pt swatch (radius 8, a 1px
/// `lineSubtle` inner line), the token's name in mono 12, and its value and the line it came from
/// in 12 `textTertiary` ("#4f46e5 · tokens.css:8", wrapping), 6pt apart.
public struct SHTokenSwatch: View {
    let name: String
    let detail: String
    let color: Color

    public init(_ name: String, detail: String, color: Color) {
        self.name = name
        self.detail = detail
        self.color = color
    }

    public var body: some View {
        let _ = SHRenderProbe.tick("design.swatch")
        let shape = RoundedRectangle(cornerRadius: SHDesignMetrics.tokenSwatchRadius)
        VStack(alignment: .leading, spacing: SH.Space.s) {
            shape.fill(color)
                .overlay { shape.strokeBorder(Color.sh.lineSubtle, lineWidth: SHDesignMetrics.lineWidth) }
                .frame(height: SHDesignChrome.systemSwatchHeight)
            Text(name)
                .font(.shMono(SHDesignChrome.paneCountSize))
                .foregroundStyle(Color.sh.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            // The value leads; where it came from follows it onto a second line.
            Text(detail)
                .font(.shSans(SHDesignChrome.paneCountSize))
                .foregroundStyle(Color.sh.textTertiary)
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, -SH.Space.xs)
        }
        .help("\(name) \(detail)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(detail)")
    }
}

/// One of a system's type styles (DZSystem), a row of `SHDesignSystemTable`: its name in mono 12
/// `textTertiary` in a 90pt column, a specimen drawn in the style (the system's face at its size and weight, in
/// `textPrimary`), and its size and weight trailing in 12 `textTertiary` ("26/700"), a row at least 40pt tall
/// with 16pt sides and a hairline above it unless it is the card's first.
public struct SHTypeSpecimen<Specimen: View>: View {
    let name: String
    let spec: String
    let divided: Bool
    let specimen: Specimen

    public init(_ name: String, spec: String, divided: Bool = true, @ViewBuilder specimen: () -> Specimen) {
        self.name = name
        self.spec = spec
        self.divided = divided
        self.specimen = specimen()
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: SH.Space.xl) {
            Text(name)
                .font(.shMono(SHDesignChrome.paneCountSize))
                .foregroundStyle(Color.sh.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: SHDesignMetrics.typeNameWidth, alignment: .leading)
            specimen
                .foregroundStyle(Color.sh.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: SH.Space.xl)
            Text(spec)
                .font(.shSans(SHDesignChrome.paneCountSize))
                .foregroundStyle(Color.sh.textTertiary)
                .fixedSize()
        }
        .padding(.horizontal, SH.Space.xl)
        .padding(.vertical, SH.Space.s)
        .frame(minHeight: SHDesignChrome.systemRowHeight)
        .overlay(alignment: .top) { if divided { SHHairline() } }
        .accessibilityElement(children: .combine)
    }
}

/// One of a system's components (DZSystem): a card (radius 10, a `lineSubtle` line) with a 92pt specimen
/// (12pt side padding, on the system's own background) holding the component drawn in the system, and under it
/// the component's name in 13 medium with its template trailing in mono 12 `textTertiary` ("partials/button.html").
public struct SHComponentSpecimen<Specimen: View>: View {
    let name: String
    let template: String?
    let background: Color
    let specimen: Specimen

    public init(_ name: String, template: String?, background: Color, @ViewBuilder specimen: () -> Specimen) {
        self.name = name
        self.template = template
        self.background = background
        self.specimen = specimen()
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: SH.Radius.m + 2)
        VStack(alignment: .leading, spacing: 0) {
            specimen
                .padding(.horizontal, SH.Space.l)
                .frame(maxWidth: .infinity)
                .frame(height: SHDesignMetrics.specimenHeight)
                .background(background)
            HStack(spacing: SH.Space.m) {
                Text(name)
                    .font(.shSans(SHDesignChrome.toolbarTextSize, .medium))
                    .foregroundStyle(Color.sh.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: SH.Space.m)
                if let template {
                    Text(template)
                        .font(.shMono(SHDesignChrome.paneCountSize))
                        .foregroundStyle(Color.sh.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .padding(.horizontal, SH.Space.l)
            .padding(.vertical, SH.Space.m)
        }
        .clipShape(shape)
        .shBorder(Color.sh.lineSubtle, in: shape)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([name, template].compactMap { $0 }.joined(separator: ", "))
    }
}

/// The last tile of the Designs page's systems (NavDesigns): dashed (1px `lineStrong`, radius 10,
/// 12×14 padding), a 12pt `plus` and its words in 12.5 `textSecondary`, 8pt apart, centered.
/// A label: the page makes it a button or a menu.
public struct SHDesignSystemBuildTile: View {
    let title: String
    let enabled: Bool
    @State private var hovering = false

    public init(_ title: String = "Build one from a repo", enabled: Bool = true) {
        self.title = title
        self.enabled = enabled
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: SHDesignMetrics.cardRadius)
        HStack(spacing: SH.Space.m) {
            Image(systemName: "plus")
                .font(.shSans(SHDesignMetrics.buildTileGlyph))
                .accessibilityHidden(true)
            Text(title)
                .font(.shSans(SHDesignMetrics.systemNameSize))
                .lineLimit(1)
        }
        .foregroundStyle(Color.sh.textSecondary)
        .padding(.vertical, SHDesignMetrics.cardPaddingVertical)
        .padding(.horizontal, SHDesignMetrics.cardPaddingHorizontal)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(hovering && enabled ? Color.sh.bgHover : .clear, in: shape)
        .overlay {
            shape.strokeBorder(Color.sh.lineStrong, style: StrokeStyle(lineWidth: SHDesignMetrics.lineWidth,
                                                                        dash: SHDesignMetrics.directionTileDash))
        }
        .contentShape(shape)
        .shEnabledOpacity(enabled)
        .onHover { hovering = $0 }
        .shAnimation(.hover, value: hovering)
    }
}
