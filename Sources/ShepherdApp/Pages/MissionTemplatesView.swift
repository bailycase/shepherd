import SwiftUI
import ShepherdCore
import ShepherdUI

// MARK: Templates (MXTemplates, MXTemplateSave, MXTemplateStart)

extension MissionTemplate {
    /// Runs and averages: the run it was saved from, plus every mission started from it.
    func stats(_ records: [Mission]) -> (runs: Int, seconds: Double, tokens: Int) {
        let started = records.filter { $0.draft.template == id && $0.phase == .done }
        let runs = self.runs + started.count
        let seconds = seconds + started.reduce(0) { $0 + ($1.run?.elapsedSeconds ?? 0) }
        let tokens = tokens + started.reduce(0) { $0 + ($1.run?.tokens ?? 0) }
        return (runs, runs == 0 ? 0 : seconds / Double(runs), runs == 0 ? 0 : tokens / runs)
    }

    /// A drawable mission of the template's map, for the graph.
    var preview: Mission { Mission(draft: MissionDraft(title: name, goal: summary.isEmpty ? name : summary, requirements: requirements, plan: plan)) }
}

/// The Templates tab: every template beside the selected one's map, runs and what it learned.
struct MissionTemplatesList: View {
    let templates: [MissionTemplate]
    let records: [Mission]
    let start: (MissionTemplate) -> Void
    @State private var selected: String?

    private var shown: MissionTemplate? { templates.first { $0.id == selected } ?? templates.first }

    var body: some View {
        GeometryReader { page in
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    SHTableHead(["Template", "Lanes", "Runs", "Avg", "Shared"], columns: AppLayout.missionTemplateColumns)
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(templates) { template in
                                MissionTemplateRow(template: template, stats: template.stats(records), selected: template.id == shown?.id) { selected = template.id }
                            }
                            Text(templates.isEmpty ? "No templates yet. Save a finished mission as a template from its Done screen."
                                 : "Save any finished mission as a template from its Done screen. Team templates live in a repo, so they're reviewed like code.")
                                .shText(.caption).foregroundStyle(Color.sh.textTertiary)
                                .padding(.horizontal, SHPageMetrics.sideInset).padding(.vertical, SH.Space.xl)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                if let shown {
                    Rectangle().fill(Color.sh.lineSubtle).frame(width: 1)
                    MissionTemplateInspector(template: shown, stats: shown.stats(records), start: { start(shown) })
                        .frame(width: AppLayout.missionSide(AppLayout.missionInspectorWidth - SH.Space.l, in: page.size.width))
                }
            }
        }
    }
}

private struct MissionTemplateRow: View {
    let template: MissionTemplate
    let stats: (runs: Int, seconds: Double, tokens: Int)
    let selected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            SHTableColumns(AppLayout.missionTemplateColumns) {
                VStack(alignment: .leading, spacing: SH.Space.xs) {
                    HStack(spacing: SH.Space.m) {
                        SHGlyph.mission.image.font(.shSans(AppLayout.missionGlyph)).foregroundStyle(Color.sh.textSecondary)
                        Text(template.name).shText(.headline).lineLimit(1)
                    }
                    Text(template.inputs.map(\.name).joined(separator: ", ")).shText(.micro).foregroundStyle(Color.sh.textTertiary).lineLimit(1)
                }
                Text(template.plan.lanes.map(\.name).joined(separator: " · ")).shText(.mono).foregroundStyle(Color.sh.textSecondary).lineLimit(2)
                Text("\(stats.runs)").shText(.mono)
                Text(MissionFormat.duration(stats.seconds)).shText(.mono)
                Text(template.team == nil ? "just me" : "team").shText(.ui).fontWeight(.regular).foregroundStyle(Color.sh.textSecondary)
            }
            .padding(.horizontal, SHPageMetrics.sideInset).padding(.vertical, SH.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.shRow(selected: selected, radius: 0))
        .overlay(alignment: .top) { SHHairline() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct MissionTemplateInspector: View {
    let template: MissionTemplate
    let stats: (runs: Int, seconds: Double, tokens: Int)
    let start: () -> Void

    var body: some View {
        let layout = MissionMapLayout(plan: template.plan)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: SH.Space.xs) {
                Text(template.name).shText(.title).accessibilityAddTraits(.isHeader)
                Text(template.team.map { "\(MissionController.teamFolder)/\(template.id).yml · \($0)" } ?? "this Mac only").shText(.micro).foregroundStyle(Color.sh.textTertiary)
            }
            .padding(SH.Space.xl)
            ScrollView {
                VStack(spacing: 0) {
                    ScrollView(.horizontal) {
                        MissionGraph(mission: template.preview, layout: layout, metrics: .compact, filter: .flow, selection: nil) { _ in }
                            .padding(SH.Space.l)
                    }
                    .frame(height: min(AppLayout.missionTemplateMapHeight, layout.size(.compact).height + SH.Space.xxl))
                    .overlay(alignment: .top) { SHHairline() }
                    .overlay(alignment: .bottom) { SHHairline() }
                    MissionInspectorSection(title: "Runs", meta: "\(stats.runs)") {
                        MissionFactRow(label: "Average") {
                            Text("\(MissionFormat.duration(stats.seconds)) · \(MissionFormat.tokens(stats.tokens)) tokens").shText(.mono)
                        }
                    }
                    if !template.learned.isEmpty {
                        MissionInspectorSection(title: "Learned from runs") {
                            ForEach(Array(template.learned.enumerated()), id: \.offset) { _, item in
                                HStack(alignment: .firstTextBaseline, spacing: SH.Space.l) {
                                    Text(Date(timeIntervalSince1970: item.at).formatted(.dateTime.month(.abbreviated).day())).shText(.micro).foregroundStyle(Color.sh.textTertiary)
                                    Text(item.text).shText(.ui).fontWeight(.regular)
                                }
                            }
                        }
                    }
                }
            }
            SHHairline()
            HStack {
                Spacer()
                Button(action: start) { Label("Start a mission", systemImage: SHGlyph.mission.symbolName) }.buttonStyle(.sh(.primary))
            }
            .padding(.horizontal, SH.Space.xl).frame(height: SHPageMetrics.headerHeight)
        }
        .background(Color.sh.bgWindow)
    }
}

/// The brief's Template section (MXTemplateStart): which template, how it went, and how this mission differs.
struct MissionBriefTemplate: View {
    let mission: Mission
    let template: MissionTemplate

    var body: some View {
        let lanes = mission.draft.plan?.lanes.map(\.name) ?? []
        let before = template.plan.lanes.map(\.name)
        VStack(alignment: .leading, spacing: SH.Space.l) {
            HStack(alignment: .firstTextBaseline) {
                SHPageSectionLabel("Template")
                Spacer()
                Text("\(template.runs) runs · avg \(MissionFormat.duration(template.runs == 0 ? 0 : template.seconds / Double(template.runs)))").shText(.micro).foregroundStyle(Color.sh.textTertiary)
            }
            HStack(spacing: SH.Space.s) {
                SHGlyph.mission.image.font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                Text(template.name).shText(.caption)
            }
            .padding(.horizontal, SH.Space.m).frame(height: SH.Height.controlS)
            .shBorder(Color.sh.lineStrong, radius: SH.Radius.s)
            ForEach(before.filter(lanes.contains), id: \.self) { line("=", Color.sh.textTertiary, $0, "same repository as last run") }
            let gone = before.filter { !lanes.contains($0) }, added = lanes.filter { !before.contains($0) }
            if !gone.isEmpty || !added.isEmpty {
                line("±", Color.sh.running, added.isEmpty ? gone.joined(separator: ", ") : added.joined(separator: ", "),
                     gone.isEmpty ? "new this time" : added.isEmpty ? "not in this mission" : "instead of \(gone.joined(separator: " + "))")
            }
            ForEach(template.inputs.filter { $0.filledBy == .you }, id: \.name) { line("+", Color.sh.done, $0.name, "asked before drafting") }
        }
        .padding(SH.Space.xl)
        .overlay(alignment: .bottom) { SHHairline() }
    }

    private func line(_ sign: String, _ color: Color, _ name: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
            Text(sign).shText(.mono).foregroundStyle(color)
            Text(name).font(.sh(.mono, weight: .semibold)).lineLimit(1)
            Text(text).shText(.ui).fontWeight(.regular).foregroundStyle(Color.sh.textSecondary).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Done's Save as template (MXTemplateSave): the name, what a new mission fills in, what the run changed, the
/// contract, and where it lives. The map beside it previews the template.
struct MissionTemplateSaveInspector: View {
    let mission: Mission
    let busy: Bool
    let close: () -> Void
    let action: (MissionUIAction) -> Void
    @State private var name: String
    @State private var summary: String
    @State private var team = false

    init(mission: Mission, busy: Bool, close: @escaping () -> Void, action: @escaping (MissionUIAction) -> Void) {
        self.mission = mission; self.busy = busy; self.close = close; self.action = action
        _name = State(initialValue: mission.draft.title)
        _summary = State(initialValue: mission.draft.goal)
    }

    private var template: MissionTemplate { MissionTemplate.from(mission, name: name.isEmpty ? mission.draft.title : name, summary: summary, at: Date().timeIntervalSince1970) }
    private var home: MissionLane? { mission.draft.plan?.lanes.first }

    var body: some View {
        let template = template
        VStack(spacing: 0) {
            MissionInspectorHead(symbol: SHGlyph.mission.symbolName, title: "Save as template", tag: nil, pill: nil, lane: nil,
                                 subtitle: "from \(mission.draft.title) · \(MissionFormat.duration(mission.run?.elapsedSeconds ?? 0)) · \(MissionFormat.tokens(mission.run?.tokens ?? 0))",
                                 mono: false, close: close) { EmptyView() }
            ScrollView {
                VStack(spacing: 0) {
                    MissionInspectorSection(title: "Name") {
                        TextField("Name", text: $name).textFieldStyle(.plain).shText(.body)
                            .padding(.horizontal, SH.Space.m).frame(height: SH.Height.controlL)
                            .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Radius.s))
                            .shBorder(Color.sh.lineStrong, radius: SH.Radius.s)
                            .accessibilityLabel("Template name")
                        TextEditor(text: $summary).shText(.body).scrollContentBackground(.hidden)
                            .frame(height: AppLayout.missionTemplateSummary)
                            .padding(SH.Space.s)
                            .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Radius.s))
                            .shBorder(Color.sh.lineStrong, radius: SH.Radius.s)
                            .accessibilityLabel("What the template does")
                    }
                    MissionInspectorSection(title: "Inputs", meta: "filled in when a mission starts from it") {
                        SHTableColumns(AppLayout.missionTemplateInputColumns) {
                            Text("INPUT"); Text("KIND"); Text("THIS RUN"); Text("FILLED BY")
                        }
                        .shText(.micro).foregroundStyle(Color.sh.textTertiary)
                        ForEach(template.inputs, id: \.name) { input in
                            SHTableColumns(AppLayout.missionTemplateInputColumns) {
                                Text(input.name).shText(.mono).foregroundStyle(Color.sh.synKeyword).lineLimit(1)
                                Text(input.kind).shText(.caption).foregroundStyle(Color.sh.textTertiary).lineLimit(1)
                                Text(input.example).shText(.mono).foregroundStyle(Color.sh.textSecondary).lineLimit(1)
                                Text(input.filledBy == .goal ? "your goal" : input.filledBy == .you ? "asks you" : "planner")
                                    .shText(.caption).foregroundStyle(input.filledBy == .you ? Color.sh.lanternText : Color.sh.textTertiary)
                            }
                        }
                    }
                    MissionInspectorSection(title: "Changed from this run") {
                        ForEach(Array(template.changes(from: mission).enumerated()), id: \.offset) { _, change in
                            HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
                                Text(change.sign).shText(.mono).foregroundStyle(change.sign == "+" ? Color.sh.done : change.sign == "−" ? Color.sh.failed : change.sign == "↻" ? Color.sh.running : Color.sh.textTertiary)
                                Text(change.name).font(.sh(.mono, weight: .semibold)).lineLimit(1)
                                Text(change.text).shText(.ui).fontWeight(.regular).foregroundStyle(Color.sh.textSecondary).lineLimit(1)
                                Spacer(minLength: SH.Space.m)
                                if change.learned { Text("learned").shText(.micro).foregroundStyle(Color.sh.textTertiary) }
                            }
                        }
                    }
                    MissionInspectorSection(title: "Contract") {
                        ForEach(Array(template.requirements.enumerated()), id: \.offset) { _, requirement in
                            HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
                                Image(systemName: "lock").font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                                Text(requirement).shText(.ui).fontWeight(.regular)
                            }
                        }
                    }
                    MissionInspectorSection(title: "Share") {
                        HStack(alignment: .top, spacing: SH.Space.l) {
                            SHSegmentedPicker("Share", selection: $team, options: [(false, "Just me"), (true, "Team")]).fixedSize()
                            Text(team ? "Saved as \(MissionController.teamFolder)/\(template.id).yml in \(home?.name ?? "the first repository"). Changes go through a PR."
                                 : "Kept on this Mac. Only your missions can start from it.")
                                .shText(.caption).foregroundStyle(Color.sh.textTertiary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            SHHairline()
            HStack {
                Button("Cancel", action: close).buttonStyle(.sh(.ghost))
                Spacer()
                Button(team ? "Save and open PR" : "Save template") {
                    action(.saveTemplate(name, summary, team ? home?.spaceID : nil)); close()
                }
                .buttonStyle(.sh(.primary)).disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, SH.Space.xl).frame(height: SHPageMetrics.headerHeight)
        }
        .background(Color.sh.bgWindow)
    }
}
