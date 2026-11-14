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

    @MainActor var dotColor: Color {
        let sh = Color.sh
        return switch tone {
        case .ok: sh.done
        case .warn: sh.lantern
        case .fixing: sh.running
        case .none: sh.lineStrong
        case .old: sh.textTertiary
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
        HStack(alignment: .top, spacing: SH.Space.xl) {
            FleetCheckGrid(check: check, selected: row, mac: state.mac, actions: actions)
            FleetCheckPanel(detail: row.map { check.detail(row: $0, mac: state.mac) } ?? .none, problem: state.problem,
                            fix: { mac, rows in check.fix(on: mac, rows: rows) }, actions: actions)
                .frame(width: AppLayout.fleetCheckPanelWidth)
        }
        .padding(.vertical, SH.Space.xxl)
        .padding(.horizontal, SH.Space.xxxl)
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
            x += width + SH.Space.l
        }
    }

    private func columnWidths(_ total: CGFloat, count: Int) -> [CGFloat] {
        guard count > 0 else { return [] }
        let free = max(0, total - SH.Space.l * CGFloat(count - 1))
        let units = AppLayout.fleetCheckNameWeight + CGFloat(count - 1)
        let unit = free / units
        return [unit * AppLayout.fleetCheckNameWeight] + Array(repeating: unit, count: count - 1)
    }
}

private struct FleetCheckGrid: View {
    let check: FleetCheckPage
    let selected: String?
    let mac: UUID?
    let actions: FleetCheckActions

    var body: some View {
        let sh = Color.sh
        VStack(spacing: 0) {
            head
            SHHairline()
            if check.groups.isEmpty {
                Text("Nothing to compare yet. Each Mac looks at itself soon after it joins, and again every day.")
                    .font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textTertiary)
                    .padding(SH.Space.xl)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(check.groups) { group in
                            Text(group.name)
                                .font(.sh(.micro))
                                .tracking(AppLayout.fleetCheckGroupTracking)
                                .textCase(.uppercase)
                                .foregroundStyle(sh.textTertiary)
                                .padding(.top, SH.Space.m)
                                .padding(.bottom, SH.Space.xs)
                                .padding(.horizontal, SH.Space.xl)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(group.rows) { row in
                                FleetCheckRowView(row: row, columns: check.columns.map(\.id), selected: row.id == selected, mac: mac, actions: actions).equatable()
                            }
                        }
                    }
                }
            }
            SHHairline()
            Text(check.footer)
                .font(.sh(.caption, weight: .regular))
                .foregroundStyle(sh.textTertiary)
                .padding(.vertical, SH.Space.m)
                .padding(.horizontal, SH.Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .shCard(radius: SH.Radius.l, fill: sh.bgRaised, line: sh.lineSubtle)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("What each Mac has")
    }

    private var head: some View {
        let sh = Color.sh
        return FleetCheckColumns {
            Text("What the fleet needs").font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textSecondary).lineLimit(1)
            ForEach(check.columns) { column in
                HStack(spacing: SH.Space.s) {
                    Circle().fill(color(of: column)).frame(width: AppLayout.fleetDotSize, height: AppLayout.fleetDotSize)
                    Text(column.name).font(.sh(.ui, weight: .semibold))
                        .foregroundStyle(column.isAsleep ? sh.textTertiary : sh.textPrimary).lineLimit(1)
                }
            }
        }
        .padding(.horizontal, SH.Space.xl)
        .frame(height: AppLayout.fleetCheckHeadHeight)
    }

    private func color(of column: FleetCheckColumn) -> Color {
        let sh = Color.sh
        return switch column.status {
        case .thisMac: sh.lantern
        case .connected: sh.done
        case .connecting: sh.running
        case .asleep: sh.textTertiary
        }
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
                VStack(alignment: .leading, spacing: SH.Space.xxs) {
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
                    HStack(spacing: SH.Space.s) {
                        Circle().fill(cell.dotColor).frame(width: AppLayout.fleetDotSize, height: AppLayout.fleetDotSize)
                        Text(cell.text).font(.sh(.ui, weight: .regular)).foregroundStyle(cell.textColor).lineLimit(1).truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, minHeight: AppLayout.fleetCheckRowHeight, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(row.name), \(cell.text)")
            }
        }
        .padding(.horizontal, SH.Space.xl)
        .frame(minHeight: AppLayout.fleetCheckRowHeight)
        .background(selected ? sh.bgSelected : hovering ? sh.bgHover : .clear)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The Mac a cell is of: its column's (the cells are in the columns' order).
    private func cellMac(_ index: Int) -> UUID? { columns.indices.contains(index) ? columns[index] : nil }
}

// MARK: The panel

private struct FleetCheckPanel: View {
    let detail: FleetCheckDetail
    let problem: String?
    let fix: (UUID, [String]?) -> FleetCheckFix?
    let actions: FleetCheckActions
    @State private var copied = false

    var body: some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: 0) {
            summary
            SHHairline()
            if detail.command != nil || detail.fixable || detail.fixing != nil {
                actionsSection
            }
            if let problem {
                Text(problem)
                    .font(.sh(.caption, weight: .regular))
                    .foregroundStyle(sh.failed)
                    .padding(.horizontal, SH.Space.xl)
                    .padding(.bottom, SH.Space.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Couldn’t start the fix: \(problem)")
            }
            Spacer(minLength: 0)
            if detail.ignorable || detail.fixAllCount > 0, let mac = detail.mac {
                SHHairline()
                HStack(spacing: SH.Space.m) {
                    if detail.ignorable {
                        Button(detail.ignored ? "Stop ignoring on \(detail.macName)" : "Ignore on \(detail.macName)") {
                            actions.ignore(detail.rowID, mac, !detail.ignored)
                        }
                        .buttonStyle(.sh(.ghost))
                    }
                    Spacer(minLength: 0)
                    if detail.fixAllCount > 0, let all = fix(mac, nil) {
                        Button("Fix everything on \(detail.macName) (\(detail.fixAllCount))") { actions.fix(all) }
                            .buttonStyle(.sh(.secondary))
                    }
                }
                .padding(.vertical, SH.Space.l)
                .padding(.horizontal, SH.Space.xl)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .shCard(radius: SH.Radius.l, fill: sh.bgRaised, line: sh.lineSubtle)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(detail.title.isEmpty ? "Details" : detail.title)
    }

    private var summary: some View {
        let sh = Color.sh
        return VStack(alignment: .leading, spacing: SH.Space.m) {
            if !detail.pill.isEmpty { pill }
            Text(detail.title).font(.sh(.title)).foregroundStyle(sh.textPrimary).fixedSize(horizontal: false, vertical: true)
            if !detail.body.isEmpty {
                Text(detail.body).font(.sh(.ui, weight: .regular)).lineSpacing(AppLayout.fleetCheckProseSpacing)
                    .foregroundStyle(sh.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            if !detail.effect.isEmpty {
                Text(detail.effect).font(.sh(.ui, weight: .regular)).lineSpacing(AppLayout.fleetCheckProseSpacing)
                    .foregroundStyle(sh.textPrimary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(SH.Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var pill: some View {
        let sh = Color.sh
        switch detail.pillTone {
        case .warn: FleetPill(text: detail.pill, dot: sh.lantern, text: sh.lanternText, fill: sh.lanternTint)
        case .good: FleetPill(text: detail.pill, dot: sh.done, text: sh.done, fill: sh.doneTint)
        case .quiet: FleetPill(text: detail.pill, dot: sh.textTertiary, text: sh.textTertiary, fill: sh.bgSelected)
        }
    }

    private var actionsSection: some View {
        let sh = Color.sh
        return VStack(alignment: .leading, spacing: SH.Space.l) {
            if let fixing = detail.fixing {
                VStack(alignment: .leading, spacing: SH.Space.m) {
                    HStack(spacing: SH.Space.s) {
                        Circle().fill(sh.running).frame(width: AppLayout.fleetDotSize, height: AppLayout.fleetDotSize)
                        Text("An agent on \(detail.macName) is fixing this").font(.sh(.ui, weight: .semibold)).foregroundStyle(sh.running)
                    }
                    Text("“\(fixing.threadTitle)”. This row checks again when it finishes.")
                        .font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textSecondary).fixedSize(horizontal: false, vertical: true)
                    Button("Open thread") { actions.openThread(fixing) }.buttonStyle(.sh(.secondary))
                }
                .padding(SH.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(sh.runningTint, in: RoundedRectangle(cornerRadius: SH.Radius.m))
                .accessibilityElement(children: .contain)
            } else {
                if let command = detail.command {
                    VStack(alignment: .leading, spacing: SH.Space.s) {
                        Text("Run on \(detail.macName)").font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textSecondary)
                        HStack(spacing: SH.Space.m) {
                            Text(command).font(.sh(.mono)).foregroundStyle(sh.textPrimary).lineLimit(1).truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .shHelp(command)
                            Button(copied ? "Copied" : "Copy") {
                                actions.copy(command)
                                copied = true
                            }
                            .buttonStyle(.sh(.ghost))
                            .accessibilityLabel("Copy command")
                        }
                        .padding(.vertical, SH.Space.m)
                        .padding(.leading, SH.Space.l)
                        .padding(.trailing, SH.Space.m)
                        .background(sh.bgSunken, in: RoundedRectangle(cornerRadius: SH.Radius.m))
                        .shBorder(sh.lineSubtle, radius: SH.Radius.m)
                        if let note = detail.commandNote {
                            Text(note).font(.sh(.caption, weight: .regular)).foregroundStyle(sh.textTertiary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .onChange(of: command) { copied = false }
                }
                if detail.fixable, let mac = detail.mac, let made = fix(mac, [detail.rowID]) {
                    VStack(alignment: .leading, spacing: SH.Space.s) {
                        Button("Fix with an agent on \(detail.macName)") { actions.fix(made) }
                            .buttonStyle(.sh(.primary, size: .l))
                        Text("Starts a thread on \(detail.macName) with this checklist. You watch it work like any thread, and it asks before anything needs your password.")
                            .font(.sh(.caption, weight: .regular)).foregroundStyle(sh.textTertiary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(SH.Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
