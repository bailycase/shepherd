import SwiftUI

extension SHSidebarMetrics {
    public static let sectionChevron: CGFloat = 9
    public static let sectionChevronStroke: CGFloat = sectionChevron / 8
    public static let sectionTop: CGFloat = 6
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

/// SidebarSectionHeader, SHNavigation: the disclosure, title and adjacent count are one
/// button. Done's action is a separate button, so it never toggles the disclosure.
public struct SHSidebarSectionHeader: View {
    let title: String
    let count: Int
    let isExpanded: Bool
    let attention: Bool
    let pulse: Bool
    let toggle: () -> Void
    let markAllSeen: (() -> Void)?
    /// A text chip trailing the title ("New project"), in the same pill as Mark all seen.
    let chip: (title: String, action: () -> Void)?
    @Environment(\.shDensity) private var density

    public init(_ title: String, count: Int, isExpanded: Bool, attention: Bool = false, pulse: Bool = false,
                toggle: @escaping () -> Void, markAllSeen: (() -> Void)? = nil, chip: (title: String, action: () -> Void)? = nil) {
        self.title = title
        self.count = count
        self.isExpanded = isExpanded
        self.attention = attention
        self.pulse = pulse
        self.toggle = toggle
        self.markAllSeen = markAllSeen
        self.chip = chip
    }

    public var body: some View {
        let _ = SHRenderProbe.tick("sidebar.header")
        HStack(spacing: SH.Space.s) {
            Button(action: toggle) {
                HStack(spacing: SH.Space.s) {
                    Path { path in
                        let unit = SHSidebarMetrics.sectionChevron / 16
                        path.move(to: CGPoint(x: 6 * unit, y: 3 * unit))
                        path.addLine(to: CGPoint(x: 11 * unit, y: 8 * unit))
                        path.addLine(to: CGPoint(x: 6 * unit, y: 13 * unit))
                    }
                        .stroke(Color.sh.textTertiary, style: StrokeStyle(lineWidth: SHSidebarMetrics.sectionChevronStroke,
                                                                        lineCap: .round, lineJoin: .round))
                        .frame(width: SHSidebarMetrics.sectionChevron, height: SHSidebarMetrics.sectionChevron)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .shAnimation(.disclosure, value: isExpanded)
                        .accessibilityHidden(true)
                    Text(title)
                        .font(.shSans(SHSidebarMetrics.sectionTitleFont, .medium))
                        .foregroundStyle(attention ? Color.sh.lanternText : Color.sh.textSecondary)
                        .lineLimit(1)
                        .fixedSize()
                    Text("\(count)")
                        .font(.shMono(SHSidebarMetrics.sectionCountFont))
                        .foregroundStyle(attention ? Color.sh.lanternText : Color.sh.textTertiary)
                        .monospacedDigit()
                        .shContentTransition(.numeric())
                        .shAnimation(.content, value: count)
                        .fixedSize()
                    if pulse && !isExpanded {
                        SHLayerGlowDot(color: .sh.running)
                            .frame(width: SHSidebarMetrics.sectionPulse, height: SHSidebarMetrics.sectionPulse)
                            .accessibilityHidden(true)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: max(density.rowHeight, SH.Height.controlS))
                .contentShape(Rectangle())
            }
            .buttonStyle(SHPlainPressStyle())
            .accessibilityLabel("\(title), \(count), \(isExpanded ? "expanded" : "collapsed")\(pulse && !isExpanded ? ", running" : "")")
            .accessibilityAddTraits(.isHeader)
            if let chip { SHSidebarHeaderChip(chip.title, action: chip.action) }
            if let markAllSeen {
                Button(action: markAllSeen) {
                    Text("Mark all seen")
                        .font(.shSans(SHSidebarMetrics.sectionActionFont))
                        .foregroundStyle(.sh.textSecondary)
                        .fixedSize()
                        .padding(.horizontal, SH.Space.s)
                        .frame(height: SHSidebarMetrics.markSeenHeight)
                        .background(Color.sh.bgHover, in: RoundedRectangle(cornerRadius: SH.Radius.xs))
                        .frame(minHeight: SH.Height.controlS)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SHPlainPressStyle())
                .accessibilityLabel("Mark all seen")
                .help("Move finished threads to Recents")
            }
        }
        .padding(.horizontal, density.sidebarRowPadding)
        .padding(.top, SHSidebarMetrics.sectionTop)
    }
}
