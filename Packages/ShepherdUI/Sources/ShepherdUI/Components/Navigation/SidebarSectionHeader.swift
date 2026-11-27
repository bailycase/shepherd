import SwiftUI

extension SHSidebarMetrics {
    public static let sectionChevron: CGFloat = 9
    public static let sectionChevronStroke: CGFloat = sectionChevron / 8
    public static let sectionTop: CGFloat = 6
    /// A header's trailing plus: the boards' 20pt `.grp .r .ib`.
    public static let sectionAction: CGFloat = 20
    public static let sectionPulse: CGFloat = 5
    public static let markSeenHeight: CGFloat = 20
    public static let activityWidth: CGFloat = 28
    public static let activityHeight: CGFloat = 12
    public static let accessoryFont: CGFloat = 10
    public static let sectionTitleFont: CGFloat = 11.5
    public static let sectionCountFont: CGFloat = 10.5
    public static let sectionActionFont: CGFloat = 10.5
}

/// Ten measured rates, padded with inactivity before the first sample.
struct SHSidebarActivityLine: Shape {
    var samples: [Double]

    func path(in rect: CGRect) -> Path {
        let values = Array(repeating: 0.0, count: max(0, 10 - samples.count)) + samples.suffix(10)
        let ceiling = max(values.max() ?? 1, 1)
        let bounds = rect.insetBy(dx: 0, dy: 1)
        return Path { path in
            for (index, value) in values.enumerated() {
                let point = CGPoint(x: bounds.minX + bounds.width * CGFloat(index) / CGFloat(values.count - 1),
                                    y: bounds.maxY - bounds.height * CGFloat(max(0, min(value / ceiling, 1))))
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
    }
}

/// A list's header (the boards' `.grp`): the title in `caption` medium and its count in `caption`,
/// both `textTertiary`, 28pt tall and 10pt below what is above. The title and count are one button
/// that folds the list; a folded list shows a trailing chevron. Done's Mark all seen is a separate
/// text button, so it never folds the list; a chip ("New project") is a trailing plus.
public struct SHSidebarSectionHeader: View {
    let title: String
    let count: Int
    let isExpanded: Bool
    let attention: Bool
    let pulse: Bool
    let toggle: () -> Void
    let markAllSeen: (() -> Void)?
    /// A trailing action ("New project"), drawn as a plus with the title as its tip.
    let chip: (title: String, action: () -> Void)?
    /// A trailing text button that opens somewhere else ("Answer in Needs you" on the iPhone), set like Mark all seen.
    let textAction: (title: String, action: () -> Void)?
    @Environment(\.shDensity) private var density

    public init(_ title: String, count: Int, isExpanded: Bool, attention: Bool = false, pulse: Bool = false,
                toggle: @escaping () -> Void, markAllSeen: (() -> Void)? = nil, chip: (title: String, action: () -> Void)? = nil,
                textAction: (title: String, action: () -> Void)? = nil) {
        self.title = title
        self.count = count
        self.isExpanded = isExpanded
        self.attention = attention
        self.pulse = pulse
        self.toggle = toggle
        self.markAllSeen = markAllSeen
        self.chip = chip
        self.textAction = textAction
    }

    public var body: some View {
        let _ = SHRenderProbe.tick("sidebar.header")
        HStack(spacing: SH.Space.s) {
            Button(action: toggle) {
                HStack(spacing: SH.Space.s) {
                    Text(title)
                        .font(.sh(.caption, weight: .medium))
                        .foregroundStyle(Color.sh.textTertiary)
                        .lineLimit(1)
                        .fixedSize()
                    Text("\(count)")
                        .font(.sh(.caption))
                        .foregroundStyle(Color.sh.textTertiary)
                        .monospacedDigit()
                        .shContentTransition(.numeric())
                        .shAnimation(.content, value: count)
                        .fixedSize()
                    // A folded Working list still says something works.
                    if pulse && !isExpanded {
                        SHLayerGlowDot(color: .sh.running)
                            .frame(width: SHSidebarMetrics.sectionPulse, height: SHSidebarMetrics.sectionPulse)
                            .accessibilityHidden(true)
                    }
                    Spacer(minLength: 0)
                    if !isExpanded {
                        Image(systemName: "chevron.right")
                            .font(.system(size: SHSidebarMetrics.sectionChevron, weight: .semibold))
                            .foregroundStyle(Color.sh.textTertiary)
                            .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: max(SHSidebarMetrics.rowHeight(density), SH.Height.controlS))
                .contentShape(Rectangle())
            }
            .buttonStyle(SHPlainPressStyle())
            .accessibilityLabel("\(title), \(count), \(isExpanded ? "expanded" : "collapsed")\(pulse && !isExpanded ? ", running" : "")")
            .accessibilityAddTraits(.isHeader)
            if let chip {
                Button(action: chip.action) { Image(systemName: "plus") }
                    .buttonStyle(.shIcon(size: SHSidebarMetrics.sectionAction, pressSize: SH.Height.controlS))
                    .shHelp(chip.title)
                    .accessibilityLabel(chip.title)
            }
            if let markAllSeen {
                Button(action: markAllSeen) {
                    Text("Mark all seen")
                        .font(.sh(.caption))
                        .foregroundStyle(.sh.textTertiary)
                        .fixedSize()
                        .frame(minHeight: SH.Height.controlS)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SHPlainPressStyle())
                .accessibilityLabel("Mark all seen")
                .help("Move finished threads to Recents")
            }
            if let textAction {
                Button(action: textAction.action) {
                    Text(textAction.title)
                        .font(.sh(.caption))
                        .foregroundStyle(.sh.textTertiary)
                        .fixedSize()
                        .frame(minHeight: SH.Height.controlS)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SHPlainPressStyle())
                .accessibilityLabel(textAction.title)
            }
        }
        .padding(.horizontal, density.sidebarRowPadding)
        .padding(.top, density.sidebarHeaderTop)
    }
}
