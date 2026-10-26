import SwiftUI

/// The host card's own measures (NavHosts).
public enum SHHostPageMetrics {
    /// The glyph tile leading the head.
    public static let tile: CGFloat = 30
    public static let tileGlyph: CGFloat = 15
    /// The fact rows' label column.
    public static let factLabelWidth: CGFloat = 110
    /// The name, in mono.
    public static let nameSize: CGFloat = 14
    /// The head's padding above and below; the sides are 16.
    public static let headVertical: CGFloat = 14
    /// The facts' and the actions' padding above and below.
    public static let blockVertical: CGFloat = 10
    /// The actions' sides.
    public static let actionsSide: CGFloat = 14
    /// Between the head's items.
    public static let headSpacing: CGFloat = 10
}

/// One fact on a host's card ("Running", "2 threads").
public struct SHHostFact: Identifiable, Equatable, Sendable {
    public var label: String
    public var value: String
    public var id: String { label }

    public init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

/// A host on the Hosts page (NavHosts): a head with the display glyph in its tile, the name in
/// mono over what runs there (and how long it has been offline), and the connection trailing;
/// then facts (Running, Worktrees, Repos, or Waiting, Last seen, Address), an optional note
/// (why a connection failed), and actions under a hairline.
public struct SHHostPageCard<Actions: View>: View {
    let name: String
    let subtitle: String
    let offlineSince: Date?
    let status: String
    let state: AgentState
    let facts: [SHHostFact]
    let note: String?
    let hasActions: Bool
    let actions: Actions

    /// `offlineSince` appends "offline 3h" to the subtitle, kept current. `state` colors the
    /// connection: done while connected, running while connecting, failed while unreachable.
    public init(name: String, subtitle: String, offlineSince: Date? = nil, status: String, state: AgentState,
                facts: [SHHostFact], note: String? = nil, @ViewBuilder actions: () -> Actions) {
        self.name = name
        self.subtitle = subtitle
        self.offlineSince = offlineSince
        self.status = status
        self.state = state
        self.facts = facts
        self.note = note
        self.hasActions = true
        self.actions = actions()
    }

    public var body: some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: 0) {
            head
                .overlay(alignment: .bottom) { SHHairline() }
            if !facts.isEmpty || note != nil {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(facts) { fact in
                        SHPageFact(fact.label, value: fact.value, labelWidth: SHHostPageMetrics.factLabelWidth)
                    }
                    if let note {
                        Text(note)
                            .shText(.caption)
                            .foregroundStyle(state == .failed ? sh.failed : sh.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, SH.Space.xs)
                    }
                }
                .padding(.vertical, SHHostPageMetrics.blockVertical)
                .padding(.horizontal, SH.Space.xl)
            }
            if hasActions {
                Spacer(minLength: 0)
                HStack(spacing: SH.Space.m) { actions }
                    .padding(.vertical, SHHostPageMetrics.blockVertical)
                    .padding(.horizontal, SHHostPageMetrics.actionsSide)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) { SHHairline() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .shPageCard()
        .accessibilityElement(children: .contain)
    }

    private var head: some View {
        let sh = Color.sh
        return HStack(spacing: SHHostPageMetrics.headSpacing) {
            Image(systemName: "desktopcomputer")
                .font(.shSans(SHHostPageMetrics.tileGlyph))
                .foregroundStyle(sh.textSecondary)
                .frame(width: SHHostPageMetrics.tile, height: SHHostPageMetrics.tile)
                .shCard(radius: SH.Radius.m, fill: sh.bgSunken, line: sh.lineSubtle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(name)
                    .font(.shMono(SHHostPageMetrics.nameSize, .semibold))
                    .foregroundStyle(sh.textPrimary)
                    .lineLimit(1)
                subtitleText
                    .font(.sh(.caption))
                    .foregroundStyle(sh.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: SH.Space.s)
            HStack(spacing: SH.Space.s) {
                SHStatusDot(state, size: SHPageMetrics.dot)
                Text(status).font(.shSans(12)).foregroundStyle(state.textColor).lineLimit(1)
            }
            .fixedSize()
        }
        .padding(.vertical, SHHostPageMetrics.headVertical)
        .padding(.horizontal, SH.Space.xl)
    }

    @ViewBuilder private var subtitleText: some View {
        if let offlineSince {
            TimelineView(SHElapsedSchedule(start: offlineSince)) { context in
                Text(subtitle + " · offline " + SHDuration.text(context.date.timeIntervalSince(offlineSince)))
            }
        } else {
            Text(subtitle)
        }
    }
}

extension SHHostPageCard where Actions == EmptyView {
    /// A card with no actions row (This Mac).
    public init(name: String, subtitle: String, offlineSince: Date? = nil, status: String, state: AgentState,
                facts: [SHHostFact], note: String? = nil) {
        self.name = name
        self.subtitle = subtitle
        self.offlineSince = offlineSince
        self.status = status
        self.state = state
        self.facts = facts
        self.note = note
        self.hasActions = false
        self.actions = EmptyView()
    }
}
