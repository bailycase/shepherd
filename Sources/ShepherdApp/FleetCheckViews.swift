import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

// The Check tab of the Fleet page (FleetCheck): what the fleet needs against each Mac as a grid, and beside it a panel about the row picked:
// what differs, what it changes for Auto, the command to run on that Mac, and the agent that can fix it. Plain values in
// (`FleetCheckPage`, from `FleetCheckPresentation`); what a button does is the caller's (`FleetCheckActions`).

/// What the tab holds apart from the page: which row and Mac are picked, and whether a look or a fix is under way.
struct FleetCheckState: Equatable {
    var row: String?
    var mac: UUID?
    var checking = false
    var problem: String?
}

/// What the tab's controls do.
struct FleetCheckActions {
    var select: (String, UUID?) -> Void
    var checkNow: () -> Void
    var copy: (String) -> Void
    var fix: (FleetCheckFix) -> Void
    var ignore: (String, UUID, Bool) -> Void
    var openThread: (FleetCheckFixing) -> Void
    /// Update Shepherd on a Mac (Update Shepherd on <Mac>, or Update now), stop that (Cancel), or update every Mac that is behind.
    var update: (UUID, FleetUpdateWhen) -> Void = { _, _ in }
    var cancelUpdate: (UUID) -> Void = { _ in }
    var updateAll: ([UUID]) -> Void = { _ in }

    static let none = FleetCheckActions(select: { _, _ in }, checkNow: {}, copy: { _ in }, fix: { _ in }, ignore: { _, _, _ in }, openThread: { _ in })
}

extension FleetCheckCell {
    /// The cell's words: lantern for what needs something, the quiet tertiary for what is not needed or from an asleep Mac.
    @MainActor var textColor: Color {
        let sh = Color.sh
        return switch tone {
        case .ok: sh.textPrimary
        case .warn: sh.lanternText
        case .fixing: sh.running
        case .none, .old: sh.textTertiary
        }
    }
}

// MARK: The tab

struct FleetCheckContent: View {
    let check: FleetCheckPage
    let state: FleetCheckState
    let actions: FleetCheckActions

    /// The row the panel is about: the one picked, else the first that needs something, else the first.
    private var row: String? {
        let rows = check.groups.flatMap(\.rows)
        if let picked = state.row, rows.contains(where: { $0.id == picked }) { return picked }
        return rows.first { !$0.attention.isEmpty }?.id ?? rows.first?.id
    }

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: SH.Space.xl) {
                FleetCheckGrid(check: check, selected: row, mac: state.mac, actions: actions)
                FleetCheckPanel(detail: row.map { check.detail(row: $0, mac: state.mac) } ?? .none, problem: state.problem,
                                fix: { mac, rows in check.fix(on: mac, rows: rows) }, actions: actions)
                    .frame(width: AppLayout.fleetCheckPanelWidth)
            }
            .padding(.top, SH.Space.s)
            .padding(.bottom, SH.Space.xxl)
            .padding(.trailing, SH.Space.xxl)
            .padding(.leading, AppLayout.fleetPageLeading)
        }
    }
}

// MARK: The grid

/// Lays a row's cells out in columns: the name takes `AppLayout.fleetCheckNameWeight` of a Mac's, as the board's 1.5fr and three 1fr.
private struct FleetCheckColumns: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        let widths = columnWidths(width, count: subviews.count)
        let height = zip(subviews, widths).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, columnWidths(bounds.width, count: subviews.count)) {
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + SH.Space.xl
        }
    }

    private func columnWidths(_ total: CGFloat, count: Int) -> [CGFloat] {
        guard count > 0 else { return [] }
        let free = max(0, total - SH.Space.xl * CGFloat(count - 1))
        let units = AppLayout.fleetCheckNameWeight + CGFloat(count - 1)
        let unit = free / units
        return [unit * AppLayout.fleetCheckNameWeight] + Array(repeating: unit, count: count - 1)
    }
}

/// The grid on its card (the boards' `.gfl-mx`), and under it what a look does and doesn't do.
private struct FleetCheckGrid: View {
    let check: FleetCheckPage
    let selected: String?
    let mac: UUID?
    let actions: FleetCheckActions

    var body: some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: SH.Space.xl) {
            VStack(spacing: 0) {
                head
                if check.groups.isEmpty {
                    Text("Nothing to compare yet. Each Mac looks at itself soon after it joins, and again every day.")
                        .font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textTertiary)
                        .padding(SH.Space.xl)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(check.groups) { group in
                            Text(group.name)
                                .font(.sh(.caption, weight: .regular))
                                .foregroundStyle(sh.textTertiary)
                                .padding(.top, SH.Space.l)
                                .padding(.bottom, SH.Space.xs)
                                .padding(.horizontal, SH.Space.m)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(group.rows) { row in
                                FleetCheckRowView(row: row, columns: check.columns.map(\.id), selected: row.id == selected, mac: mac, actions: actions).equatable()
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, SH.Space.m)
            .padding(.bottom, SH.Space.l)
            .frame(maxWidth: .infinity, alignment: .top)
            .shCard(radius: SH.Radius.xl, fill: sh.bgRaised, line: sh.lineStrong, lift: true)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("What each Mac has")
            Text(check.footer)
                .font(.sh(.caption, weight: .regular))
                .foregroundStyle(sh.textTertiary)
                .padding(.horizontal, SH.Space.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var head: some View {
        let sh = Color.sh
        return FleetCheckColumns {
            Text("What the fleet needs").font(.sh(.caption, weight: .medium)).foregroundStyle(sh.textPrimary).lineLimit(1)
            ForEach(check.columns) { column in
                Text(column.isAsleep ? "\(column.name), asleep" : column.name)
                    .font(.sh(.caption, weight: .medium))
                    .foregroundStyle(column.isAsleep ? sh.textTertiary : sh.textPrimary).lineLimit(1)
            }
        }
        .padding(.horizontal, SH.Space.m)
        .frame(height: AppLayout.fleetCheckHeadHeight)
    }
}

/// One row: the name and why, then what each Mac has. The name picks the row (the first Mac that needs something); a cell picks its Mac.
private struct FleetCheckRowView: View, Equatable {
    let row: FleetCheckRow
    /// The Macs of the columns, in order.
    let columns: [UUID]
    let selected: Bool
    let mac: UUID?
    let actions: FleetCheckActions
    @State private var hovering = false

    nonisolated static func == (a: FleetCheckRowView, b: FleetCheckRowView) -> Bool {
        a.row == b.row && a.columns == b.columns && a.selected == b.selected && a.mac == b.mac
    }

    var body: some View {
        let sh = Color.sh
        FleetCheckColumns {
            Button { actions.select(row.id, nil) } label: {
                VStack(alignment: .leading, spacing: SH.Space.xxs / 2) {
                    Text(row.name).font(.sh(.ui, weight: .medium)).foregroundStyle(sh.textPrimary).lineLimit(1)
                    Text(row.why).font(.sh(.caption, weight: .regular)).foregroundStyle(sh.textTertiary).lineLimit(1)
                }
                .padding(.vertical, SH.Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(row.label)
            ForEach(Array(row.cells.enumerated()), id: \.offset) { index, cell in
                Button { actions.select(row.id, cellMac(index)) } label: {
                    Text(cell.text).font(.sh(.ui, weight: .regular)).foregroundStyle(cell.textColor).lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, minHeight: AppLayout.fleetCheckRowHeight, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(row.name), \(cell.text)")
            }
        }
        .padding(.horizontal, SH.Space.m)
        .frame(minHeight: AppLayout.fleetCheckRowHeight)
        .shRowBackground(selected: selected, hovering: hovering, radius: SH.Radius.m)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The Mac a cell is of: its column's (the cells are in the columns' order).
    private func cellMac(_ index: Int) -> UUID? { columns.indices.contains(index) ? columns[index] : nil }
}

// MARK: The panel

/// What differs on the Mac picked (the boards' `.gfl-cd`): a card of prose, the command, the fix and what to set aside.
private struct FleetCheckPanel: View {
    let detail: FleetCheckDetail
    let problem: String?
    let fix: (UUID, [String]?) -> FleetCheckFix?
    let actions: FleetCheckActions
    @State private var copied = false

    var body: some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: SH.Space.l) {
            summary
            if let update = detail.update {
                updateSection(update)
            } else if detail.command != nil || detail.fixable || detail.fixing != nil {
                actionsSection
            }
            if let problem {
                Text(problem)
                    .font(.sh(.ui, weight: .regular))
                    .foregroundStyle(sh.failed)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Couldn’t do that: \(problem)")
            }
            if detail.ignorable || detail.fixAllCount > 0, let mac = detail.mac {
                HStack(spacing: SH.Space.m) {
                    if detail.ignorable {
                        Button(detail.ignored ? "Stop ignoring on \(detail.macName)" : "Ignore on \(detail.macName)") {
                            actions.ignore(detail.rowID, mac, !detail.ignored)
                        }
                        .buttonStyle(.shTextAction(quiet: true))
                    }
                    Spacer(minLength: 0)
                    if detail.fixAllCount > 0, let all = fix(mac, nil) {
                        Button("Fix everything (\(detail.fixAllCount))") { actions.fix(all) }
                            .buttonStyle(.shTextAction)
                            .shHelp("Fix everything on \(detail.macName)")
                    }
                }
                .padding(.horizontal, -SH.Space.s)
                .padding(.top, SH.Space.xs)
            }
        }
        .padding(.top, SH.Space.xl)
        .padding(.horizontal, AppLayout.fleetCheckPanelInset)
        .padding(.bottom, AppLayout.fleetCheckPanelInset)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .shCard(radius: SH.Radius.xl, fill: sh.bgRaised, line: sh.lineStrong, lift: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(detail.title.isEmpty ? "Details" : detail.title)
    }

    private var summary: some View {
        let sh = Color.sh
        return VStack(alignment: .leading, spacing: SH.Space.l) {
            if !detail.pill.isEmpty {
                Text(detail.pill).font(.sh(.caption, weight: .regular)).foregroundStyle(detail.pillTone == .warn ? sh.lanternText : sh.textTertiary)
            }
            Text(detail.title).font(.sh(.title)).foregroundStyle(sh.textPrimary).fixedSize(horizontal: false, vertical: true)
            if !detail.body.isEmpty {
                Text(detail.body).font(.sh(.ui, weight: .regular)).lineSpacing(AppLayout.fleetProseSpacing)
                    .foregroundStyle(sh.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            if !detail.effect.isEmpty {
                Text(detail.effect).font(.sh(.ui, weight: .regular)).lineSpacing(AppLayout.fleetProseSpacing)
                    .foregroundStyle(sh.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Update Shepherd on the Mac (FleetCheck, the Shepherd row): what is ready, the button, and while the host carries it out the state it is in.
    private func updateSection(_ update: FleetUpdateOffer) -> some View {
        let sh = Color.sh
        return VStack(alignment: .leading, spacing: SH.Space.l) {
            if let running = update.running {
                VStack(alignment: .leading, spacing: SH.Space.m) {
                    Text(running.state).font(.sh(.ui, weight: .semibold)).foregroundStyle(sh.textPrimary).shShimmer(active: true)
                    Text(running.note).font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textSecondary).fixedSize(horizontal: false, vertical: true)
                    if running.cancellable {
                        Button("Cancel") { actions.cancelUpdate(update.mac) }
                            .buttonStyle(.shTextAction(quiet: true))
                            .padding(.horizontal, -SH.Space.s)
                            .accessibilityLabel("Cancel updating \(update.macName)")
                    }
                }
                .accessibilityElement(children: .contain)
            } else {
                VStack(alignment: .leading, spacing: SH.Space.s) {
                    if update.canStart {
                        Text(update.headline).font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textSecondary)
                        Button(update.buttonTitle) { actions.update(update.mac, .idle) }
                            .buttonStyle(.shTextAction)
                            .padding(.horizontal, -SH.Space.s)
                    }
                    Text(update.note).font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textTertiary).fixedSize(horizontal: false, vertical: true)
                    if update.canStart, let now = update.nowTitle {
                        Button(now) { actions.update(update.mac, .now) }
                            .buttonStyle(.shTextAction(quiet: true))
                            .padding(.horizontal, -SH.Space.s)
                    }
                    if let problem = update.problem {
                        Text(problem).font(.sh(.ui, weight: .regular)).foregroundStyle(update.failed ? sh.failed : sh.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionsSection: some View {
        let sh = Color.sh
        return VStack(alignment: .leading, spacing: SH.Space.l) {
            if let fixing = detail.fixing {
                VStack(alignment: .leading, spacing: SH.Space.m) {
                    Text("An agent on \(detail.macName) is fixing this").font(.sh(.ui, weight: .semibold)).foregroundStyle(sh.textPrimary).shShimmer(active: true)
                    Text("“\(fixing.threadTitle)”. This row checks again when it finishes.")
                        .font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textSecondary).fixedSize(horizontal: false, vertical: true)
                    Button("Open thread") { actions.openThread(fixing) }
                        .buttonStyle(.shTextAction)
                        .padding(.horizontal, -SH.Space.s)
                }
                .accessibilityElement(children: .contain)
            } else {
                if let command = detail.command {
                    VStack(alignment: .leading, spacing: SH.Space.l) {
                        HStack(spacing: SH.Space.m) {
                            Text(command).font(.sh(.mono)).foregroundStyle(sh.textPrimary).lineLimit(1).truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .shHelp(command)
                            Button(copied ? "Copied" : "Copy") {
                                actions.copy(command)
                                copied = true
                            }
                            .buttonStyle(.plain)
                            .font(.sh(.ui, weight: .semibold))
                            .foregroundStyle(sh.textPrimary)
                            .accessibilityLabel("Copy command")
                        }
                        .padding(.vertical, SH.Space.m)
                        .padding(.horizontal, SH.Space.l)
                        .background(sh.bgSelected, in: RoundedRectangle(cornerRadius: SH.Radius.m))
                        Text("Run on \(detail.macName)." + (detail.commandNote.map { " " + $0 } ?? ""))
                            .font(.sh(.ui, weight: .regular)).lineSpacing(AppLayout.fleetProseSpacing)
                            .foregroundStyle(sh.textTertiary).fixedSize(horizontal: false, vertical: true)
                    }
                    .onChange(of: command) { copied = false }
                }
                if detail.fixable, let mac = detail.mac, let made = fix(mac, [detail.rowID]) {
                    Button("Fix with an agent on \(detail.macName)") { actions.fix(made) }
                        .buttonStyle(.shTextAction)
                        .padding(.horizontal, -SH.Space.s)
                        .shHelp("Starts a thread on \(detail.macName) with this checklist. You watch it work like any thread, and it asks before anything needs your password.")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
