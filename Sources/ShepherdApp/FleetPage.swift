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

/// The page: header, the Auto placement card, a card per Mac and the Dispatches log.
struct FleetPageContent: View {
    let page: FleetPage
    let actions: FleetPageActions
    var chrome = PageHeaderChrome()
    /// What the buttons on dispatch cards do (FleetStates).
    var cardActions: FleetThreadActions?

    var body: some View {
        VStack(spacing: 0) {
            DestinationPageHeader(title: "Fleet", subtitle: page.summary, chrome: chrome) {
                Button("Fleet settings", action: actions.openSettings)
                    .buttonStyle(.sh(.secondary))
                Button("Add a Mac", systemImage: "plus", action: actions.addMac)
                    .buttonStyle(.sh(.primary))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: SH.Space.xl) {
                    FleetPlacementCard(autoDispatch: page.autoDispatch, nextGoesTo: page.nextGoesTo)
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
                    Grid(horizontalSpacing: SH.Space.xl, verticalSpacing: SH.Space.xl) {
                        ForEach(rows, id: \.first?.id) { row in
                            GridRow {
                                ForEach(row) { card in
                                    FleetMacCardView(card: card, actions: actions)
                                        .equatable()
                                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                }
                                ForEach(0..<(AppLayout.fleetColumns - row.count), id: \.self) { _ in
                                    Color.clear.frame(maxWidth: .infinity).gridCellUnsizedAxes(.vertical)
                                }
                            }
                        }
                    }
                    FleetDispatchesCard(rows: page.dispatches)
                }
                .padding(.vertical, SH.Space.xxl)
                .padding(.horizontal, SH.Space.xxxl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color.sh.bgWindow)
    }

    private var rows: [[FleetMacCard]] {
        stride(from: 0, to: page.cards.count, by: AppLayout.fleetColumns).map {
            Array(page.cards[$0..<min($0 + AppLayout.fleetColumns, page.cards.count)])
        }
    }
}

/// "Auto dispatch is on": where work would go now. Nothing is sent from here.
private struct FleetPlacementCard: View {
    let autoDispatch: Bool
    let nextGoesTo: String?

    var body: some View {
        let sh = Color.sh
        HStack(spacing: SH.Space.xl) {
            RoundedRectangle(cornerRadius: SH.Radius.m)
                .fill(sh.runningTint)
                .frame(width: AppLayout.fleetTileSize, height: AppLayout.fleetTileSize)
                .overlay {
                    Image(systemName: "arrow.right.to.line")
                        .font(.sh(.ui, weight: .medium))
                        .foregroundStyle(sh.running)
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(autoDispatch ? "Auto dispatch is on" : "Auto dispatch is off").font(.sh(.headline)).foregroundStyle(sh.textPrimary)
                Text(autoDispatch ? "New and sent work goes to the Mac with the most room that has the thread’s models and tools."
                     : "New threads start on This Mac. Pick a Mac in the composer, or turn Auto dispatch on in Fleet settings.")
                    .font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textSecondary)
            }
            Spacer(minLength: SH.Space.xl)
            if autoDispatch, let nextGoesTo {
                Text("Next goes to").font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textSecondary)
                FleetPill(text: nextGoesTo, dot: sh.done, text: sh.done, fill: sh.doneTint)
            }
        }
        .padding(.vertical, SH.Space.l)
        .padding(.horizontal, SH.Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .shCard(radius: SH.Radius.l, fill: sh.bgRaised, line: sh.lineSubtle)
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

// MARK: Cards

/// One Mac: its head, room, readings, weight and repos.
struct FleetMacCardView: View, Equatable {
    let card: FleetMacCard
    let actions: FleetPageActions

    nonisolated static func == (a: FleetMacCardView, b: FleetMacCardView) -> Bool { a.card == b.card }

    var body: some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: 0) {
            head
            roomBlock
            readings
            if let note = card.note {
                Text(note)
                    .font(.sh(.ui, weight: .regular))
                    .lineSpacing(SHTextStyle.caption.lineSpacing)
                    .foregroundStyle(sh.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, SH.Space.m)
                    .padding(.horizontal, SH.Space.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(sh.bgSunken, in: RoundedRectangle(cornerRadius: SH.Radius.m))
                    .padding(.horizontal, SH.Space.xl)
                    .padding(.bottom, SH.Space.l)
            }
            weights
            Spacer(minLength: 0)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .shCard(radius: SH.Radius.l, fill: sh.bgRaised, line: sh.lineSubtle)
        .opacity(card.status == .asleep ? AppLayout.fleetAsleepOpacity : 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(card.name)
    }

    private var head: some View {
        let sh = Color.sh
        return HStack(alignment: .top, spacing: SH.Space.l) {
            Image(systemName: "desktopcomputer")
                .font(.sh(.ui, weight: .regular))
                .foregroundStyle(sh.textSecondary)
                .frame(width: AppLayout.fleetTileSize, height: AppLayout.fleetTileSize)
                .shBorder(sh.lineSubtle, radius: SH.Radius.m)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(card.name).font(.sh(.title)).foregroundStyle(sh.textPrimary).lineLimit(1)
                if !card.hardware.isEmpty {
                    Text(card.hardware).font(.sh(.micro, weight: .regular)).foregroundStyle(sh.textTertiary)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: SH.Space.s)
            status
        }
        .padding(.top, SH.Space.xl)
        .padding(.horizontal, SH.Space.xl)
        .padding(.bottom, SH.Space.l)
    }

    @ViewBuilder private var status: some View {
        let sh = Color.sh
        switch card.status {
        case .thisMac: FleetPill(text: card.statusText, dot: sh.lantern, text: sh.lanternText, fill: sh.lanternTint)
        case .connected: FleetPill(text: card.statusText, dot: sh.done, text: sh.done, fill: sh.doneTint)
        case .connecting: FleetPill(text: card.statusText, dot: sh.running, text: sh.running, fill: sh.runningTint)
        case .asleep: FleetPill(text: card.statusText, dot: sh.textTertiary, text: sh.textTertiary, fill: sh.bgSelected)
        }
    }

    private var roomBlock: some View {
        let sh = Color.sh
        return VStack(alignment: .leading, spacing: SH.Space.s) {
            HStack(alignment: .firstTextBaseline) {
                Text("Room").font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textSecondary)
                Spacer(minLength: SH.Space.m)
                Text(card.room.text).font(.sh(.ui, weight: .semibold)).foregroundStyle(card.room.tone.fillColor)
            }
            FleetGauge(fraction: card.room.fraction, color: card.room.tone.fillColor, height: AppLayout.fleetRoomBarHeight)
        }
        .padding(.horizontal, SH.Space.xl)
        .padding(.bottom, SH.Space.l)
        .accessibilityElement(children: .combine)
    }

    private var readings: some View {
        let sh = Color.sh
        return VStack(alignment: .leading, spacing: SH.Space.s) {
            FleetFact("CPU") { FleetGaugeValue(metric: card.cpu) }
            FleetFact("Memory") { FleetGaugeValue(metric: card.memory) }
            FleetFact("Power") { Text(card.power.text).font(.sh(.ui, weight: .regular)).foregroundStyle(card.power.tone.textColor).lineLimit(1) }
            FleetFact("Ready") {
                HStack(spacing: SH.Space.s) {
                    Circle().fill(card.ready.tone.fillColor).frame(width: AppLayout.fleetDotSize, height: AppLayout.fleetDotSize)
                    Text(card.ready.text).font(.sh(.ui, weight: .regular)).foregroundStyle(card.ready.tone.textColor).lineLimit(1).truncationMode(.tail)
                }
            }
            FleetFact("Agents") { Text(card.agents).font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textPrimary) }
        }
        .padding(.vertical, SH.Space.l)
        .padding(.horizontal, SH.Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { SHHairline() }
        .padding(.bottom, card.note == nil ? 0 : SH.Space.xs)
    }

    private var weights: some View {
        VStack(alignment: .leading, spacing: SH.Space.s) {
            Text("Send work here").font(.sh(.ui, weight: .regular)).foregroundStyle(Color.sh.textSecondary)
            FleetWeightPicker(selection: card.weight, label: card.weightLabel) { actions.choose($0, card.id) }
        }
        .padding(.vertical, SH.Space.l)
        .padding(.horizontal, SH.Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { SHHairline() }
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: SH.Space.s) {
            SHWrapStack(spacing: SH.Space.s, lineSpacing: SH.Space.s) {
                ForEach(card.repos, id: \.self) { repo in
                    Text(repo)
                        .font(.sh(.micro, weight: .regular))
                        .foregroundStyle(Color.sh.textSecondary)
                        .lineLimit(1)
                        .padding(.horizontal, SH.Space.xs)
                        .frame(height: AppLayout.fleetTagHeight)
                        .shBorder(Color.sh.lineStrong, radius: SH.Radius.xs)
                        .fixedSize()
                }
            }
            Spacer(minLength: 0)
            if card.canRetry {
                Button("Retry") { actions.retry(card.id) }
                    .buttonStyle(.sh(.secondary))
                    .accessibilityLabel("Retry \(card.name)")
            }
        }
        .padding(.top, SH.Space.m)
        .padding(.horizontal, SH.Space.xl)
        .padding(.bottom, SH.Space.l)
    }
}

/// A fact: its label column, then the value.
private struct FleetFact<Value: View>: View {
    let label: String
    let value: Value

    init(_ label: String, @ViewBuilder value: () -> Value) {
        self.label = label
        self.value = value()
    }

    var body: some View {
        HStack(spacing: SH.Space.l) {
            Text(label).font(.sh(.ui, weight: .regular)).foregroundStyle(Color.sh.textSecondary)
                .frame(width: AppLayout.fleetFactLabelWidth, alignment: .leading)
            value.frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: SHPageMetrics.factMinHeight - SH.Space.xs)
        .accessibilityElement(children: .combine)
    }
}

/// CPU or memory: a gauge and its words, or a dash while the Mac isn't answering.
private struct FleetGaugeValue: View {
    let metric: FleetMetric?

    var body: some View {
        HStack(spacing: SH.Space.m) {
            FleetGauge(fraction: metric?.fraction ?? 0, color: metric?.tone.fillColor ?? Color.sh.textTertiary, height: AppLayout.fleetMetricBarHeight)
            Text(metric?.text ?? "—")
                .font(.sh(.mono))
                .foregroundStyle(Color.sh.textPrimary)
                .frame(width: AppLayout.fleetFactValueWidth, alignment: .trailing)
        }
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

/// Send work here: Prefer, Normal, Less often, Manual only, the four filling the card's width.
struct FleetWeightPicker: View {
    let selection: FleetSendWeight
    let label: String
    let choose: (FleetSendWeight) -> Void

    var body: some View {
        let sh = Color.sh
        HStack(spacing: SH.Space.xxs) {
            ForEach(FleetSendWeight.allCases, id: \.self) { weight in
                let on = weight == selection
                Button { choose(weight) } label: {
                    Text(weight.title)
                        .font(.sh(.caption, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? sh.textPrimary : sh.textSecondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: AppLayout.fleetWeightHeight)
                        .background(on ? sh.bgSelected : .clear, in: RoundedRectangle(cornerRadius: SH.Radius.xs))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(SH.Space.xxs)
        .background(sh.bgSunken, in: RoundedRectangle(cornerRadius: SH.Radius.s))
        .shBorder(sh.lineSubtle, radius: SH.Radius.s)
        .shComponentAnimation(.content, value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

// MARK: Dispatches

/// The Dispatches log (FleetA): one line per dispatch, newest first, with where it went and why.
struct FleetDispatchesCard: View {
    let rows: [FleetDispatchRow]

    var body: some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: 0) {
            Text("Dispatches")
                .font(.sh(.headline))
                .foregroundStyle(sh.textPrimary)
                .padding(.vertical, SH.Space.l)
                .padding(.horizontal, SH.Space.xl)
                .accessibilityAddTraits(.isHeader)
            SHHairline()
            if rows.isEmpty {
                Text("Nothing sent yet. When a thread sends work to another Mac, it shows here with why it went there.")
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
            Text(row.host)
                .font(.sh(.micro, weight: .regular))
                .foregroundStyle(sh.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, SH.Space.xs)
                .frame(height: AppLayout.fleetTagHeight)
                .shBorder(sh.lineStrong, radius: SH.Radius.xs)
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

// MARK: The sidebar's Fleet row

/// The footer while Fleet is on (FleetSidebar): the Fleet row, a dot per Mac and how many sleep,
/// and Settings.
struct SidebarFleetFooter: View, Equatable {
    let footer: FleetFooter
    let selected: Bool
    let open: () -> Void
    let settings: () -> Void

    nonisolated static func == (a: SidebarFleetFooter, b: SidebarFleetFooter) -> Bool { a.footer == b.footer && a.selected == b.selected }

    var body: some View {
        let sh = Color.sh
        HStack(spacing: SH.Space.m) {
            Button(action: open) {
                HStack(spacing: SH.Space.m) {
                    Image(systemName: "macbook.and.iphone")
                        .font(.sh(.ui, weight: .regular))
                        .foregroundStyle(sh.textSecondary)
                        .frame(width: AppLayout.fleetFooterGlyph)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: SH.Space.xxs) {
                        Text("Fleet").font(.sh(.ui, weight: .semibold)).foregroundStyle(sh.textPrimary)
                        HStack(spacing: AppLayout.fleetFooterDotGap) {
                            ForEach(Array(footer.dots.enumerated()), id: \.offset) { _, dot in
                                switch dot {
                                case .thisMac: SHStatusDot(.done, size: AppLayout.fleetDotSize, color: sh.lantern)
                                case .connected: SHStatusDot(.done, size: AppLayout.fleetDotSize)
                                case .connecting: SHStatusDot(.running, size: AppLayout.fleetDotSize)
                                case .asleep: SHStatusDot(.queued, size: AppLayout.fleetDotSize)
                                }
                            }
                            Text(footer.detail).font(.sh(.micro, weight: .regular)).foregroundStyle(sh.textTertiary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, SH.Space.m)
                .frame(maxWidth: .infinity, minHeight: AppLayout.fleetFooterRowHeight, maxHeight: AppLayout.fleetFooterRowHeight, alignment: .leading)
                .background(selected ? sh.bgSelected : .clear, in: RoundedRectangle(cornerRadius: SH.Radius.m))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(footer.label)
            Button(action: settings) { Image(systemName: "gearshape") }
                .buttonStyle(.shIcon(size: SHSidebarMetrics.footerAvatar))
                .shHelp("Settings", shortcut: "⌘,")
                .accessibilityLabel("Settings")
        }
        .padding(.vertical, SH.Space.m)
        .padding(.horizontal, SH.Space.l)
        .overlay(alignment: .top) { SHHairline() }
    }
}

// MARK: Destination

/// The Fleet page in the main column: the model's cards, Add a Mac over the settings' own sheet
/// and Fleet settings. The host samples and pushes while the page is on screen.
struct FleetDestination: View {
    var vm: ShepherdViewModel
    var chrome = PageHeaderChrome()
    @State private var adding = false

    var body: some View {
        let _ = SHRenderProbe.tick("page.fleet")
        FleetPageContent(page: vm.fleetPage.page, actions: FleetPageActions(
            choose: { vm.fleetPage.choose($0, for: $1) },
            retry: { id in Task { await vm.fleet.reconnect(id) } },
            openSettings: {
                vm.settingsSection = .fleet
                vm.showSettings = true
            },
            addMac: {
                vm.fleet.openPairing()
                adding = true
            }), chrome: chrome)
            .task {
                await vm.fleet.refresh()
                await vm.fleet.watch(true)
            }
            .onDisappear { Task { await vm.fleet.watch(false) } }
            .sheet(isPresented: $adding) {
                FleetPairSheet(model: vm.fleet) { adding = false }
            }
    }
}
