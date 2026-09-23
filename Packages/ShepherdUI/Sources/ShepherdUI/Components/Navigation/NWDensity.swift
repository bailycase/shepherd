import SwiftUI

/// Row density for sidebars and menus (Navigation board, `.nwDensity(_:)`): Compact 22 ·
/// Standard 28 · Comfortable 36, each then scaled by Settings ▸ Appearance ▸ Density. Rows read
/// it from the environment and use it as a minimum height, so larger text still fits.
public enum NWDensity: String, CaseIterable, Identifiable, Sendable {
    case compact, standard, comfortable

    public var id: Self { self }

    public var title: String {
        switch self {
        case .compact: "Compact"
        case .standard: "Standard"
        case .comfortable: "Comfortable"
        }
    }

    /// The designed row height, before the density scale.
    public var baseRowHeight: CGFloat {
        switch self {
        case .compact: 22
        case .standard: 28
        case .comfortable: 36
        }
    }

    /// The row height at the current density scale (whole points).
    @MainActor public var rowHeight: CGFloat {
        switch self {
        case .compact: NW.Height.rowCompact
        case .standard: NW.Height.row
        case .comfortable: NW.Height.rowComfortable
        }
    }

    /// Row titles: 12.5 (`ui` at regular weight), 12 in compact rows.
    @MainActor public func rowTitleFont(weight: Font.Weight = .regular) -> Font {
        self == .compact ? .nwSans(12, weight) : .nw(.ui, weight: weight)
    }
}

extension EnvironmentValues {
    /// The row density sidebars and menus lay out at. Standard unless set.
    @Entry public var nwDensity: NWDensity = .standard
}

extension View {
    /// Sets the row density for the sidebars and menus inside this view.
    public func nwDensity(_ density: NWDensity) -> some View {
        environment(\.nwDensity, density)
    }
}
