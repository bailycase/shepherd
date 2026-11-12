import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

/// Fleet on the phone and the iPad (FleetA-phone, iPadFleet, DuoOpenFleet, DuoClosedFleet, DuoBookFleet): the Macs
/// paired with the Mac this device reads from, with their room, and the Dispatches log. A phone, a Duo and a
/// narrow window draw one card of rows; a wide detail draws a card per Mac with its readings and the Send work
/// here menu, the one thing a device may change (it writes the weight to a Mac as a host setting, and the fleet
/// syncs it). The page is `ClientFleet`'s, derived from the same presentation the Mac draws.
struct FleetScreen: View {
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.settingsColumn) private var inColumn
    /// The detail is wide enough for cards. Measured; until it is, the size class guesses.
    @State private var measuredWide: Bool?

    private var wide: Bool { measuredWide ?? (sizeClass == .regular && !inColumn) }

    var body: some View {
        let store = SettingsStore.of(hosts)
        let fleet = store.fleet
        let page = fleet.page
        // Fleet's own phase, and whether any Mac still serves it (Fleet switched off on the Mac while this is open).
        let serves = store.showsFleet
        ScrollView {
            VStack(alignment: .leading, spacing: MobileLayout.blockSpacing) {
                if wide { FleetPadHeader(page: page, add: addMac) } else if !page.cards.isEmpty { FleetSubtitle(page: page) }
                if let problem = fleet.problem {
                    SHBanner(.failed, title: problem) { Button("OK") { fleet.dismissProblem() }.buttonStyle(.sh(.secondary)) }
                }
                if case .failed(let message) = fleet.phase {
                    SHBanner(.failed, title: message) { Button("Try again") { Task { await fleet.refresh(store.hosts, watching: true) } }.buttonStyle(.sh(.secondary)) }
                }
                if page.cards.isEmpty {
                    empty(fleet.phase, serves: serves)
                } else {
                    Macs(page: page, wide: wide, closed: navigator.hingeClosed == true, open: navigator.hingeClosed == false) { weight, id in
                        fleet.choose(weight, for: id, store.hosts)
                    }
                    FleetSectionLabel(title: wide ? "Dispatches today" : "Dispatches", capitals: navigator.hingeClosed == nil)
                        .padding(.top, wide ? SH.Space.s : 0)
                    FleetDispatchesCard()
                }
            }
            .padding(.horizontal, wide ? MobileLayout.fleetPadInset : MobileLayout.gutter)
            .padding(.bottom, MobileLayout.sectionSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.sh.bgWindow)
        .onGeometryChange(for: Bool.self) { $0.size.width >= MobileLayout.fleetCardsMinWidth && !inColumn } action: { measuredWide = $0 }
        .refreshable { await fleet.refresh(store.hosts, watching: true) }
        .task { await watch(store) }
        .navigationTitle("Fleet")
        .navigationBarTitleDisplayMode(wide || inColumn ? .inline : .large)
        .toolbar(removing: wide ? .title : nil)
        .toolbar {
            if !wide {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add a Mac", systemImage: "plus", action: addMac)
                }
            }
        }
    }

    private func addMac() { navigator.open(.settings(.host(nil))) }

    /// Reads the page now and every few seconds while it is on screen, asking the Mac to sample each time (it stops when
    /// this ends, or the connection does).
    private func watch(_ store: SettingsStore) async {
        let fleet = store.fleet
        while !Task.isCancelled {
            await fleet.refresh(store.hosts, watching: true)
            try? await Task.sleep(for: .seconds(MobileLayout.fleetPoll))
        }
        let held = store.hosts
        Task { await fleet.stopWatching(held) }
    }

    @ViewBuilder private func empty(_ phase: ClientFleet.Phase, serves: Bool) -> some View {
        if phase == .off || (!serves && phase != .idle) {
            SHEmptyState(Text("Fleet is off"), message: "Switch it on in Settings ▸ Experiments on a Mac.") { EmptyView() }
        } else if case .failed = phase {
            EmptyView()
        } else {
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, MobileLayout.sectionSpacing)
        }
    }
}

/// The Macs: a card of rows, or on a wide detail a card each.
private struct Macs: View {
    let page: FleetPage
    let wide: Bool
    let closed: Bool
    let open: Bool
    let choose: (FleetSendWeight, UUID) -> Void

    var body: some View {
        if wide {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: MobileLayout.fleetCardMinWidth), spacing: MobileLayout.blockSpacing, alignment: .top)],
                      alignment: .leading, spacing: MobileLayout.blockSpacing) {
                ForEach(page.cards) { card in FleetMacCardView(card: card, choose: choose).equatable() }
            }
        } else {
            SHListCard {
                ForEach(page.cards) { card in FleetMacRow(card: card, style: closed ? .compact : open ? .duo : .phone).equatable() }
            }
        }
    }
}

// MARK: Rows (the phone and iPhone Duo)

/// One Mac as a row: its dot, name and room word, the room's gauge, and a mono line of readings.
struct FleetMacRow: View, Equatable {
    let card: FleetMacCard
    let style: FleetFactsStyle

    nonisolated static func == (a: FleetMacRow, b: FleetMacRow) -> Bool { a.card == b.card && a.style == b.style }

    var body: some View {
        let sh = Color.sh
        let closed = style == .compact
        VStack(alignment: .leading, spacing: closed ? SH.Space.s : SH.Space.m) {
            HStack(spacing: SH.Space.m) {
                FleetDot(color: card.roomColor)
                Text(card.name).font(closed ? .sh(.headline) : .sh(.title)).foregroundStyle(sh.textPrimary).lineLimit(1)
                Spacer(minLength: SH.Space.m)
                Text(card.rowRoom).font(closed ? .sh(.caption, weight: .semibold) : .sh(.ui, weight: .semibold)).foregroundStyle(card.roomColor)
            }
            FleetGauge(fraction: card.status == .asleep ? 0 : card.room.fraction, color: card.roomColor, height: MobileLayout.fleetRoomBarHeight)
            Text(card.facts(style)).font(.sh(.micro, weight: .regular)).foregroundStyle(sh.textTertiary)
        }
        .padding(.vertical, SH.Space.l)
        .padding(.horizontal, closed ? SH.Space.l : SH.Space.xl)
        .frame(maxWidth: .infinity, minHeight: SH.Height.touch, alignment: .leading)
        .opacity(card.status == .asleep ? MobileLayout.fleetAsleepOpacity : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(card.rowLabel)
        .accessibilityValue(card.facts(style))
    }
}

// MARK: Cards (the iPad)

/// One Mac as a card: its room, readings, and the Send work here menu.
struct FleetMacCardView: View, Equatable {
    let card: FleetMacCard
    let choose: (FleetSendWeight, UUID) -> Void

    nonisolated static func == (a: FleetMacCardView, b: FleetMacCardView) -> Bool { a.card == b.card }

    var body: some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: SH.Space.l) {
            HStack(spacing: SH.Space.m) {
                FleetDot(color: card.roomColor)
                Text(card.name).font(.sh(.title)).foregroundStyle(sh.textPrimary).lineLimit(1)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: SH.Space.s) {
                HStack {
                    Text("Room").font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textSecondary)
                    Spacer(minLength: SH.Space.m)
                    Text(card.rowRoom).font(.sh(.ui, weight: .semibold)).foregroundStyle(card.roomColor)
                }
                FleetGauge(fraction: card.status == .asleep ? 0 : card.room.fraction, color: card.roomColor, height: MobileLayout.fleetRoomBarHeight)
            }
            .accessibilityElement(children: .combine)
            VStack(alignment: .leading, spacing: SH.Space.s) {
                FleetFact("CPU") {
                    HStack(spacing: SH.Space.m) {
                        FleetGauge(fraction: card.cpu?.fraction ?? 0, color: card.cpu?.tone.fillColor ?? sh.textTertiary, height: MobileLayout.fleetMetricBarHeight)
                        Text(card.cpu?.text ?? "—").font(.sh(.mono)).foregroundStyle(sh.textPrimary)
                    }
                }
                FleetFact("Memory") { Text(card.memory?.text ?? "—").font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textPrimary) }
                FleetFact("Power") {
                    Text(card.power.text).font(.sh(.ui, weight: .regular)).foregroundStyle(card.power.tone.textColor).lineLimit(2)
                }
                FleetFact("Agents") { Text(card.agents).font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textPrimary) }
            }
            Spacer(minLength: 0)
            FleetWeightMenu(card: card, choose: choose)
        }
        .padding(SH.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .shCard(radius: SH.Radius.l, fill: sh.bgRaised, line: sh.lineSubtle)
        .opacity(card.status == .asleep ? MobileLayout.fleetAsleepOpacity : 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(card.rowLabel)
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
        HStack(spacing: SH.Space.m) {
            Text(label).font(.sh(.ui, weight: .regular)).foregroundStyle(Color.sh.textSecondary)
                .frame(width: MobileLayout.fleetFactLabelWidth, alignment: .leading)
            value.frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: SH.Space.xxl)
        .accessibilityElement(children: .combine)
    }
}

/// "Send work · Normal" with its four choices (iPadFleet's dropdown).
private struct FleetWeightMenu: View {
    let card: FleetMacCard
    let choose: (FleetSendWeight, UUID) -> Void

    var body: some View {
        let sh = Color.sh
        Menu {
            ForEach(FleetSendWeight.allCases, id: \.self) { weight in
                Button { choose(weight, card.id) } label: {
                    if weight == card.weight { Label(weight.title, systemImage: "checkmark") } else { Text(weight.title) }
                }
            }
        } label: {
            HStack(spacing: SH.Space.m) {
                Text("Send work · \(Text(card.weight.title).foregroundStyle(sh.textPrimary))")
                    .font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textSecondary)
                Spacer(minLength: SH.Space.m)
                Image(systemName: "chevron.down").font(.sh(.micro, weight: .semibold)).foregroundStyle(sh.textTertiary)
            }
            .padding(.horizontal, SH.Space.l)
            .frame(maxWidth: .infinity, minHeight: SH.Height.touch, alignment: .leading)
            .background(sh.bgSunken, in: RoundedRectangle(cornerRadius: SH.Radius.m))
            .shBorder(sh.lineSubtle, radius: SH.Radius.m)
            .contentShape(RoundedRectangle(cornerRadius: SH.Radius.m))
        }
        .accessibilityLabel(card.weightLabel)
        .accessibilityValue(card.weight.title)
    }
}

/// The wide detail's header: "Fleet", where the next work goes, and Add a Mac (iPadFleet).
private struct FleetPadHeader: View {
    let page: FleetPage
    let add: () -> Void

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: SH.Space.xs) {
                Text("Fleet").font(.sh(.display, weight: .bold)).foregroundStyle(Color.sh.textPrimary).accessibilityAddTraits(.isHeader)
                if !page.cards.isEmpty { FleetSubtitle(page: page) }
            }
            Spacer(minLength: SH.Space.xl)
            Button(action: add) {
                Label("Add a Mac", systemImage: "plus").font(.sh(.body, weight: .medium)).foregroundStyle(Color.sh.running)
                    .frame(minHeight: SH.Height.touch)
            }
            .buttonStyle(.plain)
        }
    }
}
