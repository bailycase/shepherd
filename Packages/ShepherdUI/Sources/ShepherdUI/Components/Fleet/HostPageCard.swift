import SwiftUI

/// The host card's own measures (NavHosts).
public enum NWHostPageMetrics {
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
public struct NWHostFact: Identifiable, Equatable, Sendable {
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
public struct NWHostPageCard<Actions: View>: View {
    let name: String
    let subtitle: String
    let offlineSince: Date?
    let status: String
    let state: AgentState
    let facts: [NWHostFact]
    let note: String?
    let hasActions: Bool
    let actions: Actions

    /// `offlineSince` appends "offline 3h" to the subtitle, kept current. `state` colors the
    /// connection: done while connected, running while connecting, failed while unreachable.
    public init(name: String, subtitle: String, offlineSince: Date? = nil, status: String, state: AgentState,
                facts: [NWHostFact], note: String? = nil, @ViewBuilder actions: () -> Actions) {
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
        let nw = Color.nw
        VStack(alignment: .leading, spacing: 0) {
            head
                .overlay(alignment: .bottom) { NWHairline() }
            if !facts.isEmpty || note != nil {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(facts) { fact in
                        NWPageFact(fact.label, value: fact.value, labelWidth: NWHostPageMetrics.factLabelWidth)
                    }
                    if let note {
                        Text(note)
                            .nwText(.caption)
                            .foregroundStyle(state == .failed ? nw.failed : nw.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, NW.Space.xs)
                    }
                }
                .padding(.vertical, NWHostPageMetrics.blockVertical)
                .padding(.horizontal, NW.Space.xl)
            }
            if hasActions {
                Spacer(minLength: 0)
                HStack(spacing: NW.Space.m) { actions }
                    .padding(.vertical, NWHostPageMetrics.blockVertical)
                    .padding(.horizontal, NWHostPageMetrics.actionsSide)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) { NWHairline() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .nwPageCard()
        .accessibilityElement(children: .contain)
    }

    private var head: some View {
        let nw = Color.nw
        return HStack(spacing: NWHostPageMetrics.headSpacing) {
            Image(systemName: "desktopcomputer")
                .font(.nwSans(NWHostPageMetrics.tileGlyph))
                .foregroundStyle(nw.textSecondary)
                .frame(width: NWHostPageMetrics.tile, height: NWHostPageMetrics.tile)
                .nwCard(radius: NW.Radius.m, fill: nw.bgSunken, line: nw.lineSubtle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: NW.Space.xxs) {
                Text(name)
                    .font(.nwMono(NWHostPageMetrics.nameSize, .semibold))
                    .foregroundStyle(nw.textPrimary)
                    .lineLimit(1)
                subtitleText
                    .font(.nw(.caption))
                    .foregroundStyle(nw.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: NW.Space.s)
            HStack(spacing: NW.Space.s) {
                NWStatusDot(state, size: NWPageMetrics.dot)
                Text(status).font(.nwSans(12)).foregroundStyle(state.textColor).lineLimit(1)
            }
            .fixedSize()
        }
        .padding(.vertical, NWHostPageMetrics.headVertical)
        .padding(.horizontal, NW.Space.xl)
    }

    @ViewBuilder private var subtitleText: some View {
        if let offlineSince {
            TimelineView(NWElapsedSchedule(start: offlineSince)) { context in
                Text(subtitle + " · offline " + NWDuration.text(context.date.timeIntervalSince(offlineSince)))
            }
        } else {
            Text(subtitle)
        }
    }
}

extension NWHostPageCard where Actions == EmptyView {
    /// A card with no actions row (This Mac).
    public init(name: String, subtitle: String, offlineSince: Date? = nil, status: String, state: AgentState,
                facts: [NWHostFact], note: String? = nil) {
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
