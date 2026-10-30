import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// The editor's trigger sections on a host that serves `automationTriggersCapability`: Trigger
/// (Manual, Schedule, GitHub), then for a triggered one where its runs go, where they work, who
/// can fire them, its limits, and the model and thinking pins. `check` comes from the form,
/// worked out when it changes (never in `body`).
struct AutomationTriggerSections: View {
    @Binding var form: AutomationTriggerForm
    let check: AutomationTriggerForm.Check
    let hostName: String
    let threads: [AutomationThreads.Choice]
    let models: [String]

    var body: some View {
        Section {
            Picker("Trigger", selection: $form.kind) {
                ForEach(AutomationTriggerForm.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Trigger")
            switch form.kind {
            case .manual: EmptyView()
            case .schedule: schedule
            case .github: EmptyView()
            }
        } header: {
            Text("Trigger")
        } footer: {
            switch form.kind {
            case .manual:
                Text("Runs when you run it, and when Shepherd starts on \(hostName) while it's on.")
            case .schedule:
                if let error = check.error {
                    Text(error).foregroundStyle(Color.sh.failed)
                } else if let next = check.next {
                    Text("Next run \(next). Times are \(hostName)'s time zone.")
                }
            case .github:
                if let error = check.error {
                    Text(error).foregroundStyle(Color.sh.failed)
                } else {
                    Text("\(hostName) checks GitHub through its gh sign-in. Each match starts a run.")
                }
            }
        }
        if form.kind == .github { github }
        if form.kind != .manual {
            destination
            if form.kind == .github { gate }
            limits
        }
        pins
    }

    // MARK: Schedule

    @ViewBuilder private var schedule: some View {
        Picker("Repeats", selection: $form.scheduleKind) {
            ForEach(AutomationTriggerForm.ScheduleKind.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        switch form.scheduleKind {
        case .every:
            Stepper(value: $form.everyMinutes, in: AutomationTriggerForm.minimumMinutes...(24 * 60),
                    step: AutomationTriggerForm.minimumMinutes) {
                Text(AutomationSchedulePreset.every(minutes: form.everyMinutes).summary).font(.sh(.ui))
            }
        case .daily:
            time
        case .weekly:
            days
            time
        case .custom:
            TextField("FREQ=WEEKLY;BYDAY=MO;BYHOUR=9;BYMINUTE=0", text: $form.custom, axis: .vertical)
                .font(.sh(.mono))
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .accessibilityLabel("RRULE")
        }
    }

    private var time: some View {
        DatePicker("Time", selection: Binding(
            get: { Calendar.current.date(from: DateComponents(hour: form.hour, minute: form.minute)) ?? Date() },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                form.hour = parts.hour ?? 0
                form.minute = parts.minute ?? 0
            }), displayedComponents: .hourAndMinute)
            .font(.sh(.ui))
    }

    private var days: some View {
        SHFlowLayout(spacing: SH.Space.xs) {
            ForEach(AutomationWeekday.allCases, id: \.self) { day in
                let on = form.days.contains(day)
                Button(day.short) {
                    if on { form.days.remove(day) } else { form.days.insert(day) }
                }
                .buttonStyle(.sh(on ? .primary : .secondary, size: .s))
                .shTouchTarget(height: SH.Height.touch)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Days")
    }

    // MARK: GitHub

    @ViewBuilder private var github: some View {
        ForEach($form.github) { $trigger in
            let index = form.github.firstIndex { $0.id == trigger.id } ?? 0
            Section {
                TextField("Repository (owner/name)", text: $trigger.repo)
                    .font(.sh(.mono))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Repository")
                DisclosureGroup {
                    ForEach(GitHubEventKind.allCases, id: \.self) { kind in
                        Toggle(kind.label.capitalizedFirst, isOn: Binding(
                            get: { trigger.events.contains(kind) },
                            set: { if $0 { trigger.events.insert(kind) } else { trigger.events.remove(kind) } }))
                            .font(.sh(.ui))
                    }
                } label: {
                    LabeledContent("Events") {
                        Text(trigger.events.isEmpty ? "None" : GitHubEventKind.allCases.filter(trigger.events.contains).map(\.label).joined(separator: ", "))
                            .lineLimit(2)
                    }
                    .font(.sh(.ui))
                }
                labeled("Labels", text: $trigger.labels, prompt: "bug, shepherd")
                labeled("Authors", text: $trigger.authors, prompt: "octocat")
                labeled("Title contains", text: $trigger.title, prompt: "crash")
                labeled("Number", text: $trigger.number, prompt: "Any", keyboard: .numberPad)
                if form.github.count > 1 {
                    Button("Remove trigger", role: .destructive) { form.github.removeAll { $0.id == trigger.id } }
                }
            } header: {
                Text(form.github.count > 1 ? "GitHub trigger \(index + 1)" : "GitHub")
            } footer: {
                Text("An empty repository is the folder's origin. Every filter must match; lists are comma-separated.")
            }
        }
        if form.canAddGitHub {
            Section {
                Button("Add GitHub trigger", systemImage: "plus") { form.github.append(.init()) }
            }
        }
    }

    private func labeled(_ title: String, text: Binding<String>, prompt: String, keyboard: UIKeyboardType = .default) -> some View {
        LabeledContent(title) {
            TextField(title, text: text, prompt: Text(prompt))
                .multilineTextAlignment(.trailing)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .font(.sh(.ui))
    }

    // MARK: Where, who, how many

    private var destination: some View {
        Section {
            Picker("Runs go to", selection: $form.thread) {
                Text("A new thread each run").tag(AgentID?.none)
                ForEach(threads) { thread in Text(thread.name).tag(AgentID?.some(thread.id)) }
            }
            if form.thread == nil {
                Picker("Works in", selection: $form.workspace) {
                    Text("New worktree").tag(AutomationWorkspace.worktree)
                    Text("The folder itself").tag(AutomationWorkspace.local)
                }
            }
        } header: {
            Text("Destination")
        } footer: {
            Text(form.thread != nil ? "Each run is sent to that thread as a message."
                 : form.workspace == .worktree ? "Each run gets its own worktree off a fresh fetch of the default branch."
                 : "Runs share the folder's checkout, so two at once can collide.")
        }
    }

    private var gate: some View {
        Section {
            Picker("Who can trigger", selection: $form.gate) {
                ForEach(AutomationAuthorGate.allCases, id: \.self) { Text(AutomationTriggerText.gate($0)).tag($0) }
            }
        } footer: {
            if let warning = AutomationTriggerText.gateWarning(form.gate) {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Color.sh.lanternText)
            } else {
                Text("Only the repository's owners, members and collaborators.")
            }
        }
    }

    private var limits: some View {
        Section {
            Stepper(value: $form.maxConcurrent, in: AutomationLimits.concurrentRange) {
                LabeledContent("Runs at once", value: "\(form.maxConcurrent)").font(.sh(.ui))
            }
            Stepper(value: $form.maxPerDay, in: AutomationLimits.perDayRange) {
                LabeledContent("Runs per day", value: "\(form.maxPerDay)").font(.sh(.ui))
            }
        } header: {
            Text("Limits")
        } footer: {
            Text("More events wait in the automation's inbox until a run ends or the day turns.")
        }
    }

    private var pins: some View {
        Section {
            Picker("Model", selection: $form.model) {
                Text("Default").tag("")
                ForEach(models.contains(form.model) || form.model.isEmpty ? models : [form.model] + models, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            Picker("Thinking", selection: $form.thinking) {
                Text("Default").tag("")
                ForEach(ThinkingLevel.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
            }
        } header: {
            Text("Model")
        } footer: {
            Text("Default uses \(hostName)'s defaults when each run starts.")
        }
    }
}

/// The threads a triggered automation can message: the host's threads in its visible spaces,
/// plus the saved one when it is none of them.
enum AutomationThreads {
    struct Choice: Identifiable, Equatable {
        let id: AgentID
        let name: String
    }

    static func of(_ state: ShepherdState, current: AgentID?) -> [Choice] {
        let visible = Set(state.spaces.filter { !$0.hidden }.map(\.id))
        var choices = state.agents.filter { visible.contains($0.spaceID) && $0.automationOrigin == nil }
            .map { Choice(id: $0.id, name: $0.name) }
        if let current, !choices.contains(where: { $0.id == current }) {
            choices.append(Choice(id: current, name: state.agents.first { $0.id == current }?.name ?? "A thread that's gone"))
        }
        return choices
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
