import SwiftUI
import ShepherdCore
import ShepherdRemote
import ShepherdUI

// The pieces the Fleet screens share: tone colors, a gauge, a Mac's dot, and the Dispatches card.

extension FleetTone {
    /// The color of words in this tone.
    @MainActor var textColor: Color {
        let sh = Color.sh
        return switch self {
        case .primary: sh.textPrimary
        case .secondary: sh.textSecondary
        case .tertiary: sh.textTertiary
        case .good: sh.done
        case .warn: sh.lanternText
        case .bad: sh.failed
        case .active: sh.running
        }
    }

    /// The color of a gauge, a dot, or a room word in this tone.
    @MainActor var fillColor: Color {
        let sh = Color.sh
        return switch self {
        case .primary, .secondary, .tertiary: sh.textTertiary
        case .good: sh.done
        case .warn: sh.lantern
        case .bad: sh.failed
        case .active: sh.running
        }
    }
}

extension FleetMacCard {
    /// The room word's color: Asleep is quiet whatever the last reading said.
    @MainActor var roomColor: Color { status == .asleep ? Color.sh.textTertiary : room.tone.fillColor }
}

/// A rounded gauge: `fraction` of the track in `color`.
struct FleetGauge: View {
    let fraction: Double
    let color: Color
    let height: CGFloat

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: SH.Radius.xs).fill(Color.sh.lineSubtle)
                RoundedRectangle(cornerRadius: SH.Radius.xs).fill(color)
                    .frame(width: proxy.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: height)
        .shComponentAnimation(.content, value: fraction)
        .accessibilityHidden(true)
    }
}

/// A Mac's dot: the color of its room.
struct FleetDot: View {
    let color: Color

    var body: some View {
        Circle().fill(color).frame(width: MobileLayout.statusDot, height: MobileLayout.statusDot).accessibilityHidden(true)
    }
}

/// "Next goes to Mac mini", the name in `done`; the page's own summary while no Mac counts.
struct FleetSubtitle: View {
    let page: FleetPage

    var body: some View {
        let sh = Color.sh
        Group {
            if let next = page.nextGoesTo {
                Text("Next goes to \(Text(next).fontWeight(.semibold).foregroundStyle(sh.done))")
            } else {
                Text(page.summary)
            }
        }
        .font(.sh(.ui, weight: .regular))
        .foregroundStyle(sh.textSecondary)
    }
}

/// A section's label: caption, semibold, tertiary; the phone's and the iPad's in capitals.
struct FleetSectionLabel: View {
    let title: String
    var capitals = false

    var body: some View {
        Text(title)
            .font(.sh(.caption, weight: .semibold))
            .textCase(capitals ? .uppercase : nil)
            .tracking(capitals ? SHTextStyle.caption.size * 0.06 : 0)
            .foregroundStyle(Color.sh.textTertiary)
            .padding(.horizontal, SH.Space.xs)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The Dispatches log. Nothing sends work yet (slice 4d), so it holds its empty state, as the Mac's does.
struct FleetDispatchesCard: View {
    var body: some View {
        SHListCard {
            Text("Nothing sent yet. When a thread sends work to another Mac, it shows here with why it went there.")
                .font(.sh(.ui, weight: .regular))
                .foregroundStyle(Color.sh.textTertiary)
                .padding(.vertical, SH.Space.xl)
                .padding(.horizontal, SH.Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
