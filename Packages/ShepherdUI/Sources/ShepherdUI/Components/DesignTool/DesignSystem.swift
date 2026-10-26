import SwiftUI

// A design system's page (DZSystem): its section list, token swatches, type specimens and
// component specimens, and the Designs page's "Build one from a repo" tile (NavDesigns). The
// specimens draw in the system's own look; everything around them is Shepherd Design.

/// The system page's section list (DZSystem): a 200pt column (18×10 padding, a hairline on its
/// trailing edge, rows 2pt apart). Each row is 30pt, 10pt padding, radius 6, its title in 12.5 and
/// its count trailing in mono 10.5 `textTertiary`; the current one on `bgSelected`, semibold, the
/// rest `textSecondary`.
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
        .padding(.vertical, SHDesignMetrics.railPaddingVertical)
        .padding(.horizontal, SHDesignMetrics.railPaddingHorizontal)
        .frame(width: SHDesignMetrics.railWidth, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .trailing) { SHHairline(.vertical) }
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
                    .font(.shSans(SHDesignMetrics.railTextSize, current ? .semibold : .regular))
                    .foregroundStyle(current ? Color.sh.textPrimary : Color.sh.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: SH.Space.m)
                if let count = section.count {
                    Text("\(count)")
                        .font(.shMono(SHDesignMetrics.railCountSize))
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

/// A token read from a design system (SHTokenSwatch; DZSystem): a 56pt swatch (radius 8, a 1px
/// `bgSelected` inner line), the token's name in mono 11.5 semibold, and its value and the line
/// it came from in mono 10.5 `textTertiary` ("#4f46e5 · tokens.css:8"), 6pt apart.
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
                .overlay { shape.strokeBorder(Color.sh.bgSelected, lineWidth: SHDesignMetrics.lineWidth) }
                .frame(height: SHDesignMetrics.tokenSwatchHeight)
            Text(name)
                .font(.shMono(SHDesignMetrics.tokenSwatchNameSize, .semibold))
                .foregroundStyle(Color.sh.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            // The value leads and stays whole; where it came from gives way first.
            Text(detail)
                .font(.shMono(SHDesignMetrics.tokenSwatchDetailSize))
                .foregroundStyle(Color.sh.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
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
public struct SHTypeSpecimen<Specimen: View>: View {
    let name: String
    let spec: String
    let specimen: Specimen

    public init(_ name: String, spec: String, @ViewBuilder specimen: () -> Specimen) {
        self.name = name
        self.spec = spec
        self.specimen = specimen()
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: SH.Space.xl) {
            Text(name)
                .font(.shMono(SHDesignMetrics.typeNameSize))
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
                .font(.shMono(SHDesignMetrics.typeSpecSize))
                .foregroundStyle(Color.sh.textTertiary)
                .fixedSize()
        }
        .padding(.vertical, SH.Space.m)
        .overlay(alignment: .top) { SHHairline() }
        .accessibilityElement(children: .combine)
    }
}

/// One of a system's components (DZSystem): a 92pt specimen tile (radius 8, 12pt side padding,
/// on the system's own background) with the component drawn in the system, and 10pt under it
/// the component's name in 12.5 semibold with its template trailing in mono 10.5 `textTertiary`
/// ("partials/button.html").
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
        VStack(alignment: .leading, spacing: SHDesignMetrics.specimenSpacing) {
            specimen
                .padding(.horizontal, SH.Space.l)
                .frame(maxWidth: .infinity)
                .frame(height: SHDesignMetrics.specimenHeight)
                .background(background)
                .clipShape(RoundedRectangle(cornerRadius: SHDesignMetrics.specimenRadius))
            HStack(spacing: SH.Space.m) {
                Text(name)
                    .font(.shSans(SHDesignMetrics.specimenNameSize, .semibold))
                    .foregroundStyle(Color.sh.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: SH.Space.m)
                if let template {
                    Text(template)
                        .font(.shMono(SHDesignMetrics.specimenTemplateSize))
                        .foregroundStyle(Color.sh.textTertiary)
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
