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

/// Coarse elapsed time for rows and meta: "12s", "4m", "2h", "3d".
public enum NWDuration {
    public static func short(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds))
        if whole < 60 { return "\(whole)s" }
        if whole < 3600 { return "\(whole / 60)m" }
        if whole < 86_400 { return "\(whole / 3600)h" }
        return "\(whole / 86_400)d"
    }

    /// The next moment `short(now - start)` reads differently: every second for the first
    /// minute, then on each minute, hour, or day boundary since `start`.
    public static func nextChange(after now: Date, since start: Date) -> Date {
        let elapsed = max(0, now.timeIntervalSince(start))
        let step: TimeInterval = elapsed < 60 ? 1 : elapsed < 3600 ? 60 : elapsed < 86_400 ? 3600 : 86_400
        let next = (floor(elapsed / step) + 1) * step
        return start.addingTimeInterval(next)
    }
}

/// A timeline that ticks only when an elapsed label would change (`NWDuration.nextChange`).
public struct NWElapsedSchedule: TimelineSchedule {
    let start: Date

    public init(since start: Date) { self.start = start }

    public func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        Entries(start: start, upcoming: startDate)
    }

    public struct Entries: Sequence, IteratorProtocol {
        let start: Date
        var upcoming: Date

        public mutating func next() -> Date? {
            let current = upcoming
            upcoming = NWDuration.nextChange(after: current, since: start)
            return current
        }
    }
}
