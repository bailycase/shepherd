import SwiftUI

// A design system's page (DZSystem): its section list, token swatches, type specimens and
// component specimens, and the Designs page's "Build one from a repo" tile (NavDesigns). The
// specimens draw in the system's own look; everything around them is Night Watch.

/// The system page's section list (DZSystem): a 200pt column (18×10 padding, a hairline on its
/// trailing edge, rows 2pt apart). Each row is 30pt, 10pt padding, radius 6, its title in 12.5 and
/// its count trailing in mono 10.5 `textTertiary`; the current one on `bgSelected`, semibold, the
/// rest `textSecondary`.
public struct NWSectionRail: View {
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
        VStack(alignment: .leading, spacing: NW.Space.xxs) {
            ForEach(sections) { section in
                NWSectionRailRow(section: section, current: section.id == selection) { select(section.id) }
            }
        }
        .padding(.vertical, NWDesignMetrics.railPaddingVertical)
        .padding(.horizontal, NWDesignMetrics.railPaddingHorizontal)
        .frame(width: NWDesignMetrics.railWidth, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .trailing) { NWHairline(.vertical) }
    }
}

private struct NWSectionRailRow: View {
    let section: NWSectionRail.Section
    let current: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: NW.Radius.s)
        Button(action: action) {
            HStack(spacing: NW.Space.m) {
                Text(section.title)
                    .font(.nwSans(NWDesignMetrics.railTextSize, current ? .semibold : .regular))
                    .foregroundStyle(current ? Color.nw.textPrimary : Color.nw.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: NW.Space.m)
                if let count = section.count {
                    Text("\(count)")
                        .font(.nwMono(NWDesignMetrics.railCountSize))
                        .foregroundStyle(Color.nw.textTertiary)
                }
            }
            .padding(.horizontal, NWDesignMetrics.railRowPadding)
            .frame(height: NWDesignMetrics.railRowHeight)
            .background(current ? Color.nw.bgSelected : hovering ? Color.nw.bgHover : .clear, in: shape)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .nwAnimation(.hover, value: hovering)
        .accessibilityLabel(section.count.map { "\(section.title), \($0)" } ?? section.title)
        .accessibilityAddTraits(current ? .isSelected : [])
    }
}

/// A token read from a design system (NWTokenSwatch; DZSystem): a 56pt swatch (radius 8, a 1px
/// `bgSelected` inner line), the token's name in mono 11.5 semibold, and its value and the line
/// it came from in mono 10.5 `textTertiary` ("#4f46e5 · tokens.css:8"), 6pt apart.
public struct NWTokenSwatch: View {
    let name: String
    let detail: String
    let color: Color

    public init(_ name: String, detail: String, color: Color) {
        self.name = name
        self.detail = detail
        self.color = color
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: NWDesignMetrics.tokenSwatchRadius)
        VStack(alignment: .leading, spacing: NW.Space.s) {
            shape.fill(color)
                .overlay { shape.strokeBorder(Color.nw.bgSelected, lineWidth: NWDesignMetrics.lineWidth) }
                .frame(height: NWDesignMetrics.tokenSwatchHeight)
            Text(name)
                .font(.nwMono(NWDesignMetrics.tokenSwatchNameSize, .semibold))
                .foregroundStyle(Color.nw.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(detail)
                .font(.nwMono(NWDesignMetrics.tokenSwatchDetailSize))
                .foregroundStyle(Color.nw.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .help("\(name) \(detail)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(detail)")
    }
}

/// One of a system's type styles (DZSystem): its name in mono 11 `textTertiary` in a 90pt
/// column, a specimen drawn in the style (the system's face at its size and weight, in
/// `textPrimary`), and its size and weight trailing in mono 10.5 `textTertiary` ("26/700"), on a
/// row padded 8pt above and below with a hairline above it.
public struct NWTypeSpecimen<Specimen: View>: View {
    let name: String
    let spec: String
    let specimen: Specimen

    public init(_ name: String, spec: String, @ViewBuilder specimen: () -> Specimen) {
        self.name = name
        self.spec = spec
        self.specimen = specimen()
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: NW.Space.xl) {
            Text(name)
                .font(.nwMono(NWDesignMetrics.typeNameSize))
                .foregroundStyle(Color.nw.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: NWDesignMetrics.typeNameWidth, alignment: .leading)
            specimen
                .foregroundStyle(Color.nw.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: NW.Space.xl)
            Text(spec)
                .font(.nwMono(NWDesignMetrics.typeSpecSize))
                .foregroundStyle(Color.nw.textTertiary)
                .fixedSize()
        }
        .padding(.vertical, NW.Space.m)
        .overlay(alignment: .top) { NWHairline() }
        .accessibilityElement(children: .combine)
    }
}

/// One of a system's components (DZSystem): a 92pt specimen tile (radius 8, 12pt side padding,
/// on the system's own background) with the component drawn in the system, and 10pt under it
/// the component's name in 12.5 semibold with its template trailing in mono 10.5 `textTertiary`
/// ("partials/button.html").
public struct NWComponentSpecimen<Specimen: View>: View {
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
        VStack(alignment: .leading, spacing: NWDesignMetrics.specimenSpacing) {
            specimen
                .padding(.horizontal, NW.Space.l)
                .frame(maxWidth: .infinity)
                .frame(height: NWDesignMetrics.specimenHeight)
                .background(background)
                .clipShape(RoundedRectangle(cornerRadius: NWDesignMetrics.specimenRadius))
            HStack(spacing: NW.Space.m) {
                Text(name)
                    .font(.nwSans(NWDesignMetrics.specimenNameSize, .semibold))
                    .foregroundStyle(Color.nw.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: NW.Space.m)
                if let template {
                    Text(template)
                        .font(.nwMono(NWDesignMetrics.specimenTemplateSize))
                        .foregroundStyle(Color.nw.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([name, template].compactMap { $0 }.joined(separator: ", "))
    }
}

/// The last tile of the Designs page's systems (NavDesigns): dashed (1px `lineStrong`, radius 10,
/// 12×14 padding), a 12pt `plus` and its words in 12.5 `textSecondary`, 8pt apart, centered.
/// A label: the page makes it a button or a menu.
public struct NWDesignSystemBuildTile: View {
    let title: String
    @State private var hovering = false

    public init(_ title: String = "Build one from a repo") {
        self.title = title
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: NWDesignMetrics.cardRadius)
        HStack(spacing: NW.Space.m) {
            Image(systemName: "plus")
                .font(.nwSans(NWDesignMetrics.buildTileGlyph))
                .accessibilityHidden(true)
            Text(title)
                .font(.nwSans(NWDesignMetrics.systemNameSize))
                .lineLimit(1)
        }
        .foregroundStyle(Color.nw.textSecondary)
        .padding(.vertical, NWDesignMetrics.cardPaddingVertical)
        .padding(.horizontal, NWDesignMetrics.cardPaddingHorizontal)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(hovering ? Color.nw.bgHover : .clear, in: shape)
        .overlay {
            shape.strokeBorder(Color.nw.lineStrong, style: StrokeStyle(lineWidth: NWDesignMetrics.lineWidth,
                                                                        dash: NWDesignMetrics.directionTileDash))
        }
        .contentShape(shape)
        .onHover { hovering = $0 }
        .nwAnimation(.hover, value: hovering)
    }
}
