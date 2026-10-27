import SwiftUI
import ShepherdUI

/// Native counterparts of NavMissions and MXStart/Goal/Map/Run/Review/Done, in points
/// (the boards are 2× captures).
extension AppLayout {
    // List (NavMissions)
    static let missionColumns: [NWTableColumns.Column] = [.flex(1.7), .flex(1.2), .fixed(160), .fixed(150), .fixed(110)]
    /// Below `missionNarrowWidth`: Mission, Route and Spend only.
    static let missionNarrowColumns: [NWTableColumns.Column] = [.flex(1), missionColumns[2], missionColumns[3]]
    static let missionRouteWidth: CGFloat = 150
    static let missionRouteSegment: CGFloat = 4
    static let missionTabHeight: CGFloat = 28
    static let missionTabPadding: CGFloat = 10
    static let missionChipHeight: CGFloat = 20
    static let missionGlyph: CGFloat = 14
    static let missionChipGlyph: CGFloat = 10

    // Start and Goal (MXStart, MXGoal)
    static let missionStartWidth: CGFloat = 720
    static let missionComposerHeight: CGFloat = 144
    static let missionReplyHeight: CGFloat = 104
    static let missionTranscriptWidth: CGFloat = 720
    static let missionBriefWidth: CGFloat = 540
    static let missionEditorHeight: CGFloat = 120
    static let missionBriefLaneName: CGFloat = 164

    // Header
    static let missionMeterWidth: CGFloat = 92
    static let missionMeterBar: CGFloat = 2
    static let missionStepNumber: CGFloat = 10

    // Map (MXMap, MXDone)
    static let missionInspectorWidth: CGFloat = 440
    static let missionLaneWidth: CGFloat = 218
    static let missionLaneHeader: CGFloat = 64
    static let missionNodeWidth: CGFloat = 190
    static let missionNodeHeight: CGFloat = 44
    static let missionCheckHeight: CGFloat = 32
    static let missionRankHeight: CGFloat = 84
    static let missionNodeIcon: CGFloat = 24
    static let missionWireWidth: CGFloat = 1.5
    static let missionBarWidth: CGFloat = 3
    static let missionSelectedBorder: CGFloat = 2
    static let missionDataDash: [CGFloat] = [4, 3]
    static let missionLoopInset: CGFloat = 14
    static let missionZoomRange: ClosedRange<CGFloat> = 0.5...2
    /// The smallest automatic fit: micro labels (10.5) stay at 8.4pt or more. Below it the map
    /// switches to the compact route rather than shrinking further; you can still zoom out by hand.
    static let missionReadableZoom: CGFloat = 0.8
    static let missionZoomStep: CGFloat = 0.1
    static let missionFloatingInputWidth: CGFloat = 440
    static let missionLegendSwatch: CGFloat = 20

    // Run (MXRun): the compact graph keeps 40% of the width.
    static let missionRunGraphShare: CGFloat = 0.4
    static let missionCompactLaneWidth: CGFloat = 112
    static let missionCompactNodeWidth: CGFloat = 100
    static let missionCompactNodeHeight: CGFloat = 26
    static let missionCompactRankHeight: CGFloat = 40
    static let missionCompactLaneHeader: CGFloat = 32

    // Review (MXReview)
    static let missionFilesWidth: CGFloat = 320
    static let missionContractWidth: CGFloat = 420
    /// Full board widths (320 · 420) from a 1600pt main area; narrower windows share the room.
    static let missionFilesShare: CGFloat = 0.25
    static let missionContractShare: CGFloat = 0.3
    static let missionSpendBar: CGFloat = 4

    static let missionBudgetRefresh: TimeInterval = 1

    /// A side column's width: the board's, shrinking with a narrow window so the main column keeps room.
    static let missionSideMinimum: CGFloat = 260
    static let missionSideShare: CGFloat = 0.42
    static func missionSide(_ ideal: CGFloat, in width: CGFloat, share: CGFloat = missionSideShare) -> CGFloat {
        min(ideal, max(missionSideMinimum, width * share))
    }
    /// Below this a mission page shows its side column (Goal's brief, Map's inspector, Run's
    /// station, Review's contract) in place of the main one, and the list drops its secondary columns.
    static let missionNarrowWidth: CGFloat = 1100
}
