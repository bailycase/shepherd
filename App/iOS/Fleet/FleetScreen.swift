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
///
/// This is also where the Macs this device is paired with live (what Hosts was): "+" is Add a Mac, a Mac this device can't
/// reach sits in the list asleep, and a Mac it paired with can be forgotten (swipe on a row, or its context menu) or tried
/// again. A row opens nothing else.
struct FleetScreen: View {
    @Environment(MobileHosts.self) private var hosts
    @Environment(\.mobileApp) private var app
    @Environment(MobileNavigator.self) private var navigator
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.settingsColumn) private var inColumn
    /// The detail is wide enough for cards. Measured; until it is, the size class guesses.
    @State private var measuredWide: Bool?
    /// The row whose Forget is being confirmed.
    @State private var forgetting: FleetListRow?
    @State private var forgetFailure: String?

    /// The screen's two views: the Macs, or Check (what each has of what the fleet needs, read only).
    enum Tab: Hashable { case macs, check }
    @State private var tab = Tab.macs

    /// What a preview shows that a touch would: Forget's confirmation, as a swipe on the row leads to it, or the Check list. Set by the fixtures, never the app.
    enum Preview { case forgetting(String), check }
    nonisolated(unsafe) static var preview: Preview?

    private var wide: Bool { measuredWide ?? (sizeClass == .regular && !inColumn) }
    /// The iPad draws the board's bar over the page; the phone and iPhone Duo the 28pt title in it.
    private var padBar: Bool { sizeClass == .regular && navigator.hingeClosed == nil }

    var body: some View {
        let store = SettingsStore.of(hosts)
        let fleet = store.fleet
        let page = fleet.page
        let rows = store.fleetRows
        // Whether any Mac serves the fleet's view (Fleet switched off on the Mac while this is open).
        let serves = store.showsFleet
        let actions = FleetRowActions(forget: { forgetting = $0 }, retry: { hosts.retry($0) })
        VStack(spacing: 0) {
        if padBar {
            PadColumnBar(title: "Fleet", subtitle: page.cards.isEmpty ? page.summary : page.nextGoesTo.map { "Next goes to \($0)" } ?? page.summary,
                         inset: MobileLayout.settingsPadPageInset) {
                PadBarButton(title: "Add a Mac", action: addMac)
            }
        }
        ScrollView {
            VStack(alignment: .leading, spacing: MobileLayout.settingsSectionSpacing) {
                if !padBar {
                    SettingsHeading("Fleet")
                    if !page.cards.isEmpty { FleetSubtitle(page: page).padding(.top, -MobileLayout.settingsLeadPull) }
                }
                if let problem = fleet.problem {
                    SHBanner(.failed, title: problem) { Button("OK") { fleet.dismissProblem() }.buttonStyle(.settingsPill) }
                }
                if case .failed(let message) = fleet.phase {
                    SHBanner(.failed, title: message) { Button("Try again") { Task { await fleet.refresh(store.hosts, watching: true) } }.buttonStyle(.settingsPill) }
                }
                if let failure = forgetFailure {
                    SHBanner(.failed, title: failure) { Button("OK") { forgetFailure = nil }.buttonStyle(.settingsPill) }
                }
                if rows.isEmpty {
                    empty()
                } else {
                    if serves, !page.check.columns.isEmpty {
                        SettingsSegments("Fleet view", selection: $tab, options: [(.macs, "Macs"), (.check, page.check.tabTitle)])
                    }
                    if tab == .check, serves {
                        FleetCheckList(check: page.check, capitals: false,
                                       updates: fleet.canUpdate(store.hosts) ? FleetCheckList.Updates(
                                           start: { mac, when in Task { await fleet.update(mac, .start(when: when), store.hosts) } },
                                           cancel: { mac in Task { await fleet.update(mac, .cancel, store.hosts) } }) : nil)
                    } else {
                        Macs(rows: rows, wide: wide, duo: navigator.hingeClosed != nil, closed: navigator.hingeClosed == true, open: navigator.hingeClosed == false, actions: actions) { weight, id in
                            fleet.choose(weight, for: id, store.hosts)
                        }
                    }
                    if tab == .check, serves {
                        EmptyView()
                    } else if serves {
                        SettingsCaption(wide ? "Recent work today" : "Recent work", tone: wide ? .loud : .quiet)
                        FleetDispatchesCard()
                    } else {
                        SettingsFootnote("Room and readings show for a Mac on the latest Shepherd. Update it to see them.")
                    }
                }
            }
            .padding(.horizontal, wide ? MobileLayout.settingsPadPageInset : MobileLayout.gutter)
            .padding(.bottom, MobileLayout.sectionSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        }
        .background(Color.sh.bgWindow)
        .onGeometryChange(for: Bool.self) { $0.size.width >= MobileLayout.fleetCardsMinWidth && !inColumn } action: { measuredWide = $0 }
        .swipeActionsContainer()
        .refreshable {
            hosts.retryAll()
            await fleet.refresh(store.hosts, watching: true)
        }
        .confirmationDialog(forgetting.map { "Forget \($0.card.name)?" } ?? "", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
                            titleVisibility: .visible, presenting: forgetting) { row in
            Button("Forget this Mac", role: .destructive) { forget(row) }
        } message: { row in
            Text("This device stops reading \(row.card.name) and deletes its token. Other Macs in the fleet are unchanged, and the Mac can be added again with a new code.")
        }
        .task { await watch(store) }
        .task {
            guard case .check? = Self.preview else { return }
            Self.preview = nil
            tab = .check
        }
        .task(id: rows.count) {
            guard case .forgetting(let name)? = Self.preview, let row = rows.first(where: { $0.card.name == name && $0.held != nil }) else { return }
            Self.preview = nil
            forgetting = row
        }
        .navigationTitle("Fleet")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
        .toolbar {
            if !padBar {
                ToolbarItem(placement: .topBarTrailing) {
                    // The board's plus is the ink circle.
                    Button("Add a Mac", systemImage: "plus", action: addMac)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.glassProminent)
                        .tint(Color.sh.primary)
                }
            }
        }
    }

    private func addMac() { navigator.open(.settings(.host(nil))) }

    private func forget(_ row: FleetListRow) {
        guard let id = row.held else { return }
        Task {
            do { try await app?.forget(host: id) } catch { forgetFailure = error.localizedDescription }
        }
    }

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

    /// No Mac at all: the one thing to do is add one.
    private func empty() -> some View {
        SHEmptyState(Text("No Macs yet"), message: "Pair with a Mac running Shepherd, with the code it shows, to see its threads and room here.") {
            Button("Add a Mac", action: addMac).buttonStyle(.settingsPill(.dark))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, MobileLayout.sectionSpacing)
    }
}

/// What a Mac's row can do: forget the pairing, or try the connection again.
struct FleetRowActions {
    let forget: (FleetListRow) -> Void
    let retry: (UUID) -> Void
}

/// The Macs: a card of rows, or on a wide detail a card each.
private struct Macs: View {
    let rows: [FleetListRow]
    let wide: Bool
    /// iPhone Duo, open or closed: one card of rows (DuoClosedFleet); the phone and the iPad draw a card per Mac.
    let duo: Bool
    let closed: Bool
    let open: Bool
    let actions: FleetRowActions
    let choose: (FleetSendWeight, UUID) -> Void

    var body: some View {
        if wide || !duo {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: MobileLayout.fleetCardMinWidth), spacing: MobileLayout.blockSpacing, alignment: .top)],
                      alignment: .leading, spacing: MobileLayout.blockSpacing) {
                ForEach(rows) { row in
                    FleetMacCardView(card: row.card, choose: choose).equatable().fleetRowActions(row, actions)
                }
            }
        } else {
            SettingsCard {
                ForEach(rows) { row in
                    FleetMacRow(card: row.card, style: closed ? .compact : open ? .duo : .phone).equatable().fleetRowActions(row, actions)
                }
            }
        }
    }
}

extension View {
    /// A Mac this device paired with: Forget by swiping the row (and from its context menu on the iPad and Duo), and Retry
    /// while it can't be reached. A Mac the fleet only told it about has neither.
    fileprivate func fleetRowActions(_ row: FleetListRow, _ actions: FleetRowActions) -> some View {
        modifier(FleetRowMenu(row: row, actions: actions))
    }
}

private struct FleetRowMenu: ViewModifier {
    let row: FleetListRow
    let actions: FleetRowActions

    func body(content: Content) -> some View {
        if let held = row.held {
            content
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("Forget this Mac", systemImage: "trash", role: .destructive) { actions.forget(row) }
                }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    if row.canRetry {
                        Button("Retry", systemImage: "arrow.clockwise") { actions.retry(held) }.tint(Color.sh.textTertiary)
                    }
                }
                .contextMenu {
                    if row.canRetry { Button("Retry", systemImage: "arrow.clockwise") { actions.retry(held) } }
                    Button("Forget this Mac", systemImage: "trash", role: .destructive) { actions.forget(row) }
                }
                .accessibilityAction(named: "Forget this Mac") { actions.forget(row) }
        } else {
            content
        }
    }
}

// MARK: Rows (the phone and iPhone Duo)

/// One Mac as a row (iPhone Duo): its name and room word, the room's gauge, and a line of readings.
struct FleetMacRow: View, Equatable {
    let card: FleetMacCard
    let style: FleetFactsStyle

    nonisolated static func == (a: FleetMacRow, b: FleetMacRow) -> Bool { a.card == b.card && a.style == b.style }

    var body: some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: SH.Space.s) {
            HStack(spacing: SH.Space.m) {
                Text(card.name).font(.sh(.ui)).foregroundStyle(sh.textPrimary).lineLimit(1)
                Spacer(minLength: SH.Space.m)
                Text(card.rowRoom).font(.shSans(MobileLayout.settingsCaptionSize)).foregroundStyle(card.roomColor)
            }
            FleetGauge(fraction: card.status == .asleep ? 0 : card.room.fraction, color: card.roomColor, height: MobileLayout.fleetRoomBarHeight)
            Text(card.facts(style)).font(.shSans(MobileLayout.settingsCaptionSize)).foregroundStyle(sh.textTertiary)
        }
        .padding(.vertical, SH.Space.l)
        .padding(.horizontal, MobileLayout.settingsRowInset)
        .frame(maxWidth: .infinity, minHeight: SH.Height.touch, alignment: .leading)
        .opacity(card.status == .asleep ? MobileLayout.fleetAsleepOpacity : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(card.rowLabel)
        .accessibilityValue(card.facts(style))
    }
}

// MARK: Cards (the iPad)

/// One Mac as a card (FleetA-phone, iPadFleet): its name and room word, the room's gauge, its readings, and the Send work menu.
struct FleetMacCardView: View, Equatable {
    let card: FleetMacCard
    let choose: (FleetSendWeight, UUID) -> Void

    nonisolated static func == (a: FleetMacCardView, b: FleetMacCardView) -> Bool { a.card == b.card }

    var body: some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: SH.Space.l) {
            HStack(spacing: SH.Space.l - SH.Space.xxs) {
                SHGlyph.Settings.computer.image
                    .font(.shSans(MobileLayout.settingsGlyphSize, .regular))
                    .foregroundStyle(sh.textSecondary)
                    .accessibilityHidden(true)
                Text(card.name).font(.sh(.ui, weight: .semibold)).foregroundStyle(sh.textPrimary).lineLimit(1)
                Spacer(minLength: SH.Space.m)
                Text(card.rowRoom).font(.shSans(MobileLayout.settingsCaptionSize)).foregroundStyle(card.roomColor)
            }
            if card.status != .asleep {
                FleetGauge(fraction: card.room.fraction, color: card.roomColor, height: MobileLayout.fleetRoomBarHeight)
            }
            VStack(alignment: .leading, spacing: SH.Space.s) {
                FleetFact("CPU") { Text(card.cpu?.text ?? "—").foregroundStyle(sh.textPrimary) }
                FleetFact("Memory") { Text(card.memory?.text ?? "—").foregroundStyle(sh.textPrimary) }
                FleetFact("Power") { Text(card.power.text).foregroundStyle(card.status == .asleep ? sh.textTertiary : sh.textPrimary).lineLimit(2) }
                FleetFact("Agents") { Text(card.agents).foregroundStyle(card.status == .asleep ? sh.textTertiary : sh.textPrimary) }
            }
            .font(.shSans(MobileLayout.fleetFactSize))
            if card.takesWeight { FleetWeightMenu(card: card, choose: choose) }
        }
        .padding(.horizontal, MobileLayout.settingsRowInset)
        .padding(.vertical, SH.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .shCard(radius: MobileLayout.settingsCardRadius, lift: true)
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
            Text(label).foregroundStyle(Color.sh.textSecondary)
                .frame(width: MobileLayout.fleetFactLabelWidth, alignment: .leading)
            value.frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

/// "Send work   Normal ⌃⌄" with its four choices, under a rule (the cards' footer).
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
            HStack(spacing: SH.Space.xs) {
                Text("Send work").font(.shSans(MobileLayout.fleetFactSize)).foregroundStyle(sh.textSecondary)
                Spacer(minLength: SH.Space.m)
                Text(card.weight.title).font(.sh(.ui)).foregroundStyle(sh.textPrimary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.shSans(MobileLayout.settingsChevronSize, .medium)).foregroundStyle(sh.textTertiary)
            }
            .frame(maxWidth: .infinity, minHeight: SH.Height.touch, alignment: .leading)
            .contentShape(Rectangle())
        }
        .overlay(alignment: .top) { SHHairline() }
        .accessibilityLabel(card.weightLabel)
        .accessibilityValue(card.weight.title)
    }
}
