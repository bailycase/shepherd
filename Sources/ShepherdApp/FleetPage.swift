import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

// The Fleet page (FleetA): the Macs paired with this one as cards, with their room, CPU, memory,
// power, readiness and agents, a Send work here choice each, and the Dispatches log. Plain values
// in (`FleetPage`, from `FleetPagePresentation`); what a button does is the caller's.

/// What the page's controls do.
struct FleetPageActions {
    var choose: (FleetSendWeight, UUID) -> Void
    var retry: (UUID) -> Void
    var openSettings: () -> Void
    var addMac: () -> Void
    /// A Mac card's Check…: the Check tab, on the first thing that Mac needs.
    var openCheck: (UUID) -> Void = { _ in }
    /// A Mac card's Update…: the Check tab, on the Shepherd row, where Update Shepherd on that Mac is.
    var openUpdate: (UUID) -> Void = { _ in }
    /// A row of the list: its Mac's detail shows.
    var select: (UUID) -> Void = { _ in }
    /// What a lone Mac offers (FleetEmpty): Add on a Mac found on this network, Add over SSH… and Join with a code….
    var addFound: (FoundMac) -> Void = { _ in }
    var addOverSSH: () -> Void = {}
    var joinWithCode: () -> Void = {}
}

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

    /// The color of a gauge or dot in this tone.
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

/// The page: the header, then the Macs tab (the Auto line, a list of Macs beside the chosen one's detail, and the Recent work log) or the Check tab.
struct FleetPageContent: View {
    let page: FleetPage
    let layout: FleetMacsLayout
    let actions: FleetPageActions
    var chrome = PageHeaderChrome()
    /// What the buttons on dispatch cards do (FleetStates).
    var cardActions: FleetThreadActions?
    /// Macs or Check.
    var tab: Binding<FleetPageModel.Tab> = .constant(.macs)
    var check = FleetCheckState()
    var checkActions = FleetCheckActions.none
    /// The Mac the sidebar's Fleet corner opened the page on, or the one picked in the list: its detail shows.
    var focusedMac: UUID?
    /// Macs this one found on its network that aren't in the fleet yet (only what a lone Mac offers).
    var found: [FoundMac] = []

    init(page: FleetPage, layout: FleetMacsLayout? = nil, actions: FleetPageActions, chrome: PageHeaderChrome = PageHeaderChrome(),
         cardActions: FleetThreadActions? = nil, tab: Binding<FleetPageModel.Tab> = .constant(.macs), check: FleetCheckState = FleetCheckState(),
         checkActions: FleetCheckActions = .none, focusedMac: UUID? = nil, found: [FoundMac] = []) {
        self.page = page
        self.layout = layout ?? FleetMacsLayout.make(page)
        self.actions = actions
        self.chrome = chrome
        self.cardActions = cardActions
        self.tab = tab
        self.check = check
        self.checkActions = checkActions
        self.focusedMac = focusedMac
        self.found = found
    }

    /// A Mac alone in its fleet has no list to choose from: the page invites the others.
    private var alone: Bool { page.cards.count <= 1 && page.dispatches.isEmpty && page.attention.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            FleetPageHeader(page: page, layout: layout, actions: actions, tab: tab, check: check, checkActions: checkActions, alone: alone, chrome: chrome)
            if tab.wrappedValue == .check {
                FleetCheckContent(check: page.check, state: check, actions: checkActions)
            } else if alone {
                FleetInviteView(found: found, actions: actions)
            } else {
                macsBody
            }
        }
        .background(Color.sh.bgWindow)
    }

    private var macsBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SH.Space.xl) {
                ForEach(layout.limits) { line in
                    FleetLimitStripView(line: line)
                }
                if !page.attention.isEmpty || !page.behind.isEmpty {
                    VStack(spacing: SH.Space.l) {
                        ForEach(page.attention) { card in
                            FleetDispatchCardView(card: card, actions: cardActions).equatable()
                        }
                        ForEach(page.behind) { mac in
                            FleetBehindMacCard(mac: mac)
                        }
                    }
                }
                FleetAutoLine(autoDispatch: page.autoDispatch, nextGoesTo: page.nextGoesTo)
                HStack(alignment: .top, spacing: AppLayout.fleetBodyGap) {
                    FleetMacList(groups: layout.groups, selected: layout.detail(focusedMac)?.id, choose: actions.select)
                        .equatable()
                        .frame(width: AppLayout.fleetListWidth)
                    if let detail = layout.detail(focusedMac) {
                        FleetMacDetailView(detail: detail, actions: actions).equatable()
                            .frame(maxWidth: .infinity)
                    }
                }
                if !page.dispatches.isEmpty { FleetDispatchesCard(rows: page.dispatches) }
            }
            .padding(.top, SH.Space.s)
            .padding(.bottom, SH.Space.xxl)
            .padding(.trailing, SH.Space.xxl)
            .padding(.leading, AppLayout.fleetPageLeading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The page's header (the boards' `.tbar.pgb`): the title, the Macs and Check tabs with what the fleet is doing, and a capsule of words.
struct FleetPageHeader: View {
    let page: FleetPage
    let layout: FleetMacsLayout
    let actions: FleetPageActions
    let tab: Binding<FleetPageModel.Tab>
    let check: FleetCheckState
    let checkActions: FleetCheckActions
    let alone: Bool
    let chrome: PageHeaderChrome

    var body: some View {
        let checking = tab.wrappedValue == .check
        HStack(spacing: SH.Space.m) {
            if let sidebar = chrome.showSidebar {
                Button(action: sidebar) { Image(systemName: "sidebar.left") }
                    .buttonStyle(.shIcon)
                    .shHelp("Show sidebar")
                    .accessibilityLabel("Show sidebar")
                    .padding(.trailing, SH.Space.l)
            }
            Text("Fleet").font(.sh(.title)).foregroundStyle(Color.sh.textPrimary).lineLimit(1).accessibilityAddTraits(.isHeader)
            if !alone {
                SHLiftSegments("Fleet view", selection: tab, segments: [
                    SHLiftSegment(.macs, "Macs"),
                    SHLiftSegment(.check, "Check", count: page.check.count > 0 ? "\(page.check.count)" : nil),
                ])
                .padding(.leading, SH.Space.s)
                Text(checking ? layout.checkSummary : layout.summary)
                    .font(.sh(.ui, weight: .regular))
                    .foregroundStyle(Color.sh.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: SH.Space.l)
            if checking, let ago = page.check.checkedAgo {
                Text(ago).font(.sh(.ui, weight: .regular)).foregroundStyle(Color.sh.textTertiary).lineLimit(1).padding(.trailing, SH.Space.s)
            }
            SHToolbarCapsule {
                if checking {
                    if page.check.updatable.count > 1 {
                        FleetCapsuleWord("Update every Mac") { checkActions.updateAll(page.check.updatable) }
                        SHHairline(.vertical).frame(height: AppLayout.fleetCapsuleRule)
                    }
                    FleetCapsuleWord(check.checking ? "Checking…" : "Check now", action: checkActions.checkNow)
                        .disabled(check.checking)
                } else {
                    FleetCapsuleWord("Fleet settings", action: actions.openSettings)
                    SHHairline(.vertical).frame(height: AppLayout.fleetCapsuleRule)
                    FleetCapsuleWord("Add a Mac", systemImage: "plus", action: actions.addMac)
                }
            }
            .layoutPriority(1)
        }
        .padding(.leading, (chrome.showSidebar == nil ? SHToolbarMetrics.leadingPadding : SH.Space.xxl) + chrome.leadingInset)
        .padding(.trailing, SHToolbarMetrics.trailingPadding)
        .frame(height: SHToolbarMetrics.height)
        .frame(maxWidth: .infinity)
        .background(Color.sh.bgWindow)
        .contentShape(Rectangle())
    }
}

/// A word in the header's capsule (the boards' `.pgb2`): 28pt, an optional glyph before it.
struct FleetCapsuleWord: View {
    let title: String
    var systemImage: String?
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, systemImage: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: SH.Space.s) {
                if let systemImage { Image(systemName: systemImage).font(.sh(.caption, weight: .medium)).accessibilityHidden(true) }
                Text(title).font(.sh(.caption, weight: .regular))
            }
            .foregroundStyle(Color.sh.textPrimary)
            .padding(.horizontal, SH.Space.l - SH.Space.xxs)
            .frame(height: SH.Height.controlM)
            .background(hovering ? Color.sh.bgHover : .clear, in: RoundedRectangle(cornerRadius: SH.Radius.s))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .shAnimation(.hover, value: hovering)
    }
}

/// "Auto is on. New threads go to…" and, at the end, where the next one goes (the boards' `.gfl-auto`). Nothing is sent from here.
private struct FleetAutoLine: View {
    let autoDispatch: Bool
    let nextGoesTo: String?

    var body: some View {
        let sh = Color.sh
        HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
            Text(autoDispatch ? "Auto is on." : "Auto is off.").font(.sh(.ui, weight: .semibold)).foregroundStyle(sh.textPrimary)
            Text(autoDispatch ? "New threads go to the Mac with the most room that has their models and tools."
                 : "New threads start on This Mac. Pick a Mac in the composer, or turn Auto on in Fleet settings.")
                .font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textSecondary)
                .lineLimit(1)
            Spacer(minLength: SH.Space.m)
            if autoDispatch, let nextGoesTo {
                HStack(spacing: SH.Space.xs) {
                    Text("Next goes to").foregroundStyle(sh.textSecondary)
                    Text(nextGoesTo).font(.sh(.ui, weight: .semibold)).foregroundStyle(sh.textPrimary)
                }
                .font(.sh(.ui, weight: .regular))
                .fixedSize()
            }
        }
        .padding(.horizontal, SH.Space.xs)
        .accessibilityElement(children: .combine)
    }
}

/// "Anthropic is limiting your account…": a provider is limiting the fleet's requests, so new threads for it wait on every Mac.
struct FleetLimitStripView: View {
    let line: FleetLimitLine

    var body: some View {
        let sh = Color.sh
        HStack(alignment: .top, spacing: SH.Space.l) {
            Image(systemName: "hourglass")
                .font(.sh(.caption, weight: .regular))
                .foregroundStyle(sh.textSecondary)
                .padding(.top, SH.Space.xxs)
                .accessibilityHidden(true)
            (Text(line.lead + " ").font(.sh(.ui, weight: .semibold)).foregroundColor(sh.textPrimary)
                + Text(line.rest).font(.sh(.ui, weight: .regular)).foregroundColor(sh.textSecondary))
                .lineSpacing(AppLayout.fleetProseSpacing)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let waiting = line.waiting {
                Text(waiting).font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textSecondary).fixedSize()
            }
        }
        .padding(.vertical, SH.Space.l)
        .padding(.horizontal, SH.Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .shCard(radius: SH.Radius.xl, fill: sh.bgRaised, line: sh.lineStrong, lift: true)
        .accessibilityElement(children: .combine)
    }
}

/// A 20pt pill: a dot and a word on a tint.
struct FleetPill: View {
    let label: String
    let dot: Color
    let foreground: Color
    let fill: Color

    init(text label: String, dot: Color, text foreground: Color, fill: Color) {
        self.label = label
        self.dot = dot
        self.foreground = foreground
        self.fill = fill
    }

    var body: some View {
        HStack(spacing: SH.Space.s) {
            Circle().fill(dot).frame(width: AppLayout.fleetDotSize, height: AppLayout.fleetDotSize)
            Text(label).font(.sh(.caption, weight: .medium)).foregroundStyle(foreground).lineLimit(1)
        }
        .padding(.horizontal, SH.Space.s)
        .frame(height: AppLayout.fleetPillHeight)
        .background(fill, in: RoundedRectangle(cornerRadius: SH.Radius.xs))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
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

// MARK: The list and the detail

/// The Macs, one row each (the boards' `.gfl-list`), in groups once there are more than a few.
struct FleetMacList: View, Equatable {
    let groups: [FleetMacGroup]
    let selected: UUID?
    let choose: (UUID) -> Void

    nonisolated static func == (a: FleetMacList, b: FleetMacList) -> Bool { a.groups == b.groups && a.selected == b.selected }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: SH.Space.xxs) {
            ForEach(groups) { group in
                if let title = group.title {
                    HStack {
                        Text(title)
                        Spacer(minLength: SH.Space.m)
                        Text("\(group.rows.count)")
                    }
                    .font(.sh(.caption, weight: .medium))
                    .foregroundStyle(Color.sh.textTertiary)
                    .padding(.horizontal, AppLayout.fleetRowInset)
                    .padding(.top, SH.Space.l)
                    .padding(.bottom, SH.Space.xs)
                    .accessibilityAddTraits(.isHeader)
                }
                ForEach(group.rows) { row in
                    FleetListRowView(row: row, selected: row.id == selected) { choose(row.id) }
                        .equatable()
                }
            }
        }
    }
}

/// One Mac in the list: its glyph, its name over a line, and a word at the end.
struct FleetListRowView: View, Equatable {
    let row: FleetListRow
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    nonisolated static func == (a: FleetListRowView, b: FleetListRowView) -> Bool { a.row == b.row && a.selected == b.selected }

    var body: some View {
        let sh = Color.sh
        Button(action: action) {
            HStack(spacing: SH.Space.l) {
                Image(systemName: "desktopcomputer")
                    .font(.sh(.ui, weight: .regular))
                    .foregroundStyle(sh.textSecondary)
                    .frame(width: AppLayout.fleetRowGlyph)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: SH.Space.xxs / 2) {
                    Text(row.name).font(.sh(.ui, weight: .medium)).foregroundStyle(row.dim ? sh.textSecondary : sh.textPrimary).lineLimit(1)
                    Text(row.subtitle).font(.sh(.caption, weight: .regular)).foregroundStyle(sh.textTertiary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(row.word).font(.sh(.caption, weight: .regular)).foregroundStyle(row.attention ? sh.lanternText : sh.textSecondary).lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, AppLayout.fleetRowInset)
            .padding(.vertical, SH.Space.s)
            .frame(minHeight: AppLayout.fleetRowHeight)
            .shRowBackground(selected: selected, hovering: hovering, radius: SH.Radius.m)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(row.name)
        .accessibilityValue([row.subtitle, row.word].filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// One Mac, in full (the boards' `.gfl-det`): its room, its readings, Send work here and its repos on a card.
struct FleetMacDetailView: View, Equatable {
    let detail: FleetMacDetail
    let actions: FleetPageActions

    nonisolated static func == (a: FleetMacDetailView, b: FleetMacDetailView) -> Bool { a.detail == b.detail }

    var body: some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: SH.Space.xxl) {
            head
            VStack(alignment: .leading, spacing: SH.Space.m) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Room").foregroundStyle(sh.textSecondary)
                    Spacer(minLength: SH.Space.m)
                    Text(detail.room).font(.sh(.ui, weight: .medium)).foregroundStyle(sh.textPrimary)
                }
                .font(.sh(.ui, weight: .regular))
                SHMeter(fraction: detail.roomFraction, height: AppLayout.fleetRoomBarHeight)
            }
            .accessibilityElement(children: .combine)
            facts
            if let note = detail.note {
                Text(note).font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textSecondary)
                    .lineSpacing(AppLayout.fleetProseSpacing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            weights
        }
        .padding(.vertical, SH.Space.xxl)
        .padding(.horizontal, AppLayout.fleetDetailInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .shCard(radius: SH.Radius.xl, fill: sh.bgRaised, line: sh.lineStrong, lift: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(detail.name)
    }

    private var head: some View {
        let sh = Color.sh
        return HStack(spacing: AppLayout.fleetHeadGap) {
            Image(systemName: "desktopcomputer")
                .font(.sh(.ui, weight: .regular))
                .foregroundStyle(sh.textPrimary)
                .frame(width: AppLayout.fleetTileSize, height: AppLayout.fleetTileSize)
                .background(sh.bgSelected, in: RoundedRectangle(cornerRadius: SH.Radius.m))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(detail.name).font(.shSans(AppLayout.fleetDetailTitle, .semibold)).foregroundStyle(sh.textPrimary).lineLimit(1)
                if !detail.hardware.isEmpty {
                    Text(detail.hardware).font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textTertiary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if detail.canRetry {
                Button("Retry") { actions.retry(detail.id) }
                    .buttonStyle(.shTextAction)
                    .accessibilityLabel("Retry \(detail.name)")
            }
            if detail.behind {
                Button("Update…") { actions.openUpdate(detail.id) }
                    .buttonStyle(.shTextAction)
                    .accessibilityLabel("Update Shepherd on \(detail.name)")
            }
            // A Mac whose only need is its build has Update… alone: Check… would open the same row.
            if detail.checkable {
                Button("Check…") { actions.openCheck(detail.id) }
                    .buttonStyle(.shTextAction)
                    .accessibilityLabel("See what \(detail.name) needs")
            }
        }
    }

    private var facts: some View {
        let sh = Color.sh
        return Grid(alignment: .leading, horizontalSpacing: SH.Space.xl, verticalSpacing: SH.Space.l) {
            FleetFactRow("CPU") { FleetMeterValue(meter: detail.cpu) }
            FleetFactRow("Memory") { FleetMeterValue(meter: detail.memory) }
            FleetFactRow("Power") { Text(detail.power).foregroundStyle(sh.textPrimary) }
            FleetFactRow("Ready") { Text(detail.ready).foregroundStyle(detail.needsAttention ? sh.lanternText : sh.textPrimary) }
            FleetFactRow("Agents") { Text(detail.agents).foregroundStyle(sh.textPrimary) }
            if let link = detail.link {
                FleetFactRow("Link") { Text(link).foregroundStyle(sh.textPrimary).lineLimit(1).truncationMode(.middle) }
            }
        }
        .font(.sh(.ui, weight: .regular))
    }

    private var weights: some View {
        let sh = Color.sh
        return Grid(alignment: .leading, horizontalSpacing: SH.Space.xl, verticalSpacing: SH.Space.l) {
            GridRow(alignment: .center) {
                Text("Send work here").foregroundStyle(sh.textTertiary).fixedSize()
                FleetWeightPicker(selection: detail.weight, label: detail.weightLabel) { actions.choose($0, detail.id) }
                    .gridColumnAlignment(.leading)
            }
            if !detail.repos.isEmpty {
                FleetFactRow("Repos") { Text(detail.repos).foregroundStyle(sh.textPrimary) }
            }
        }
        .font(.sh(.ui, weight: .regular))
    }
}

/// A fact: its label in the quiet color, then the value.
private struct FleetFactRow<Value: View>: View {
    let label: String
    let value: Value

    init(_ label: String, @ViewBuilder value: () -> Value) {
        self.label = label
        self.value = value()
    }

    var body: some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(Color.sh.textTertiary).frame(width: AppLayout.fleetFactLabelWidth, alignment: .leading)
            value.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// CPU or memory: a meter and its words, or a dash while the Mac isn't answering.
private struct FleetMeterValue: View {
    let meter: FleetMacMeter?

    var body: some View {
        HStack(spacing: SH.Space.l) {
            SHMeter(fraction: meter?.fraction ?? 0, height: AppLayout.fleetMetricBarHeight)
                .frame(width: AppLayout.fleetMeterWidth)
            Text(meter?.text ?? "—").foregroundStyle(Color.sh.textPrimary)
        }
    }
}

/// Send work here: Prefer, Normal, Less often, Manual only.
struct FleetWeightPicker: View {
    let selection: FleetSendWeight
    let label: String
    let choose: (FleetSendWeight) -> Void

    var body: some View {
        SHLiftSegments(label, selection: Binding(get: { selection }, set: choose),
                       segments: FleetSendWeight.allCases.map { SHLiftSegment($0, $0.title) }, style: .choice)
    }
}

// MARK: Dispatches

/// The Recent work log (FleetA): one line per thread started on a Mac, newest first, with where it went and why.
struct FleetDispatchesCard: View {
    let rows: [FleetDispatchRow]

    var body: some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent work")
                .font(.sh(.headline))
                .foregroundStyle(sh.textPrimary)
                .padding(.vertical, SH.Space.l)
                .padding(.horizontal, SH.Space.xl)
                .accessibilityAddTraits(.isHeader)
            SHHairline()
            if rows.isEmpty {
                Text("Nothing yet. When a thread starts work on another Mac, it shows here with why it went there.")
                    .font(.sh(.ui, weight: .regular))
                    .foregroundStyle(sh.textTertiary)
                    .padding(.vertical, SH.Space.xl)
                    .padding(.horizontal, SH.Space.xl)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        FleetDispatchRowView(row: row).equatable()
                        if row.id != rows.last?.id { SHHairline() }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .shCard(radius: SH.Radius.l, fill: sh.bgRaised, line: sh.lineSubtle)
    }
}

/// One dispatch: its title and sender, an arrow and the Mac, why, its state and its age.
struct FleetDispatchRowView: View, Equatable {
    let row: FleetDispatchRow

    nonisolated static func == (a: FleetDispatchRowView, b: FleetDispatchRowView) -> Bool { a.row == b.row }

    var body: some View {
        let sh = Color.sh
        HStack(spacing: SH.Space.l) {
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(row.title).font(.sh(.ui, weight: .medium)).foregroundStyle(sh.textPrimary).lineLimit(1)
                Text(row.sentBy).font(.sh(.caption, weight: .regular)).foregroundStyle(sh.textTertiary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "arrow.right")
                .font(.sh(.caption, weight: .regular))
                .foregroundStyle(sh.textTertiary)
                .accessibilityHidden(true)
            FleetHostTag(name: row.host)
                .frame(width: AppLayout.fleetDispatchHostWidth, alignment: .leading)
            Text(row.reason)
                .font(.sh(.ui, weight: .regular))
                .foregroundStyle(sh.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: AppLayout.fleetDispatchReasonWidth, alignment: .leading)
            FleetDispatchStatePill(text: row.state, tone: row.tone)
                .frame(width: AppLayout.fleetDispatchStateWidth, alignment: .trailing)
            Text(row.age)
                .font(.sh(.micro, weight: .regular))
                .foregroundStyle(sh.textTertiary)
                .frame(width: AppLayout.fleetDispatchAgeWidth, alignment: .trailing)
        }
        .padding(.vertical, SH.Space.m)
        .padding(.horizontal, SH.Space.xl)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
    }
}

struct FleetDispatchStatePill: View {
    let text: String
    let tone: FleetTone

    var body: some View {
        let sh = Color.sh
        switch tone {
        case .active: FleetPill(text: text, dot: sh.running, text: sh.running, fill: sh.runningTint)
        case .good: FleetPill(text: text, dot: sh.done, text: sh.done, fill: sh.doneTint)
        case .bad: FleetPill(text: text, dot: sh.failed, text: sh.failed, fill: sh.failedTint)
        case .warn: FleetPill(text: text, dot: sh.lantern, text: sh.lanternText, fill: sh.lanternTint)
        case .primary, .secondary, .tertiary: FleetPill(text: text, dot: sh.textTertiary, text: sh.textTertiary, fill: sh.bgSelected)
        }
    }
}

// MARK: Destination

/// The Fleet page in the main column: the model's cards, Add a Mac over the settings' own sheet
/// and Fleet settings. The host samples and pushes while the page is on screen.
struct FleetDestination: View {
    var vm: ShepherdViewModel
    var chrome = PageHeaderChrome()
    @State private var sheet: Sheet?

    /// What Add a Mac and the lone Mac's other ways open.
    private enum Sheet: Identifiable {
        case add, mac(FoundMac), ssh, join
        var id: String {
            switch self {
            case .add: "add"
            case .mac(let mac): mac.id
            case .ssh: "ssh"
            case .join: "join"
            }
        }
    }

    var body: some View {
        let _ = SHRenderProbe.tick("page.fleet")
        let model = vm.fleetPage
        let alone = model.page.cards.count <= 1
        FleetPageContent(page: model.page, layout: model.layout, actions: FleetPageActions(
            choose: { model.choose($0, for: $1) },
            retry: { id in Task { await vm.fleet.reconnect(id) } },
            openSettings: {
                vm.settingsSection = .fleet
                vm.showSettings = true
            },
            addMac: {
                vm.fleet.openPairing()
                sheet = .add
            },
            openCheck: { model.openCheck(for: $0) },
            openUpdate: { model.openCheck(for: $0, row: "build") },
            select: { model.focusedMac = $0 },
            addFound: {
                vm.fleet.openPairing()
                sheet = .mac($0)
            },
            addOverSSH: {
                vm.fleet.openPairing()
                sheet = .ssh
            },
            joinWithCode: { sheet = .join }), chrome: chrome,
            tab: Binding(get: { model.tab }, set: { model.tab = $0 }),
            check: FleetCheckState(row: model.checkRow, mac: model.checkMac, checking: model.checking, problem: model.checkProblem),
            checkActions: FleetCheckActions(
                select: { model.selectCheck(row: $0, mac: $1) },
                checkNow: { vm.checkFleetNow() },
                copy: { text in
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                },
                fix: { vm.startFleetFix($0) },
                ignore: { model.ignoreCheck($0, on: $1, $2) },
                openThread: { vm.openFleetFix($0) },
                update: { vm.updateFleetMac($0, when: $1) },
                cancelUpdate: { vm.cancelFleetUpdate($0) },
                updateAll: { vm.updateEveryFleetMac($0) }),
            focusedMac: model.focusedMac,
            found: alone ? vm.fleet.found : [])
            .task {
                await vm.fleet.refresh()
                await vm.fleet.watch(true)
            }
            // A lone Mac looks for the others on its network while its page is open (the sheets look for themselves).
            .task(id: alone && sheet == nil) {
                guard alone, sheet == nil else { return }
                vm.fleet.startFinding()
            }
            .onDisappear {
                model.focusedMac = nil
                vm.fleet.stopFinding()
                Task { await vm.fleet.watch(false) }
            }
            .sheet(item: $sheet) { sheet in
                switch sheet {
                case .add: FleetPairSheet(model: vm.fleet) { self.sheet = nil }
                case .mac(let mac): FleetPairSheet(model: vm.fleet, candidate: mac) { self.sheet = nil }
                case .ssh: FleetPairSheet(model: vm.fleet, showsOtherWays: true) { self.sheet = nil }
                case .join: FleetJoinView(model: vm.fleet) { self.sheet = nil }
                }
            }
    }
}
