import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// What the automation editor opens on.
enum AutomationEditorTarget: Identifiable, Equatable {
    case new
    case edit(AutomationKey)

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let key): "\(key.host.uuidString)/\(key.automation.rawValue)"
        }
    }
}

/// New automation and Edit (the Automations page): the fields every host's automation has, as
/// the iOS form has them. Name, prompt, the folder its runs work in, and whether it is on; a new
/// one also picks its host. On This Mac it also sets what starts a run (by hand, a schedule, or
/// GitHub activity), where runs go, who can trigger one, its limits and model pins
/// (`AutomationTriggerForm`). Saving never starts a run.
struct AutomationEditorSheet: View {
    var vm: ShepherdViewModel
    let target: AutomationEditorTarget
    let dismiss: () -> Void

    @State private var host = PageHost.localID
    @State private var name = ""
    @State private var prompt = ""
    @State private var folder = ""
    @State private var enabled = false
    @State private var loaded = false
    @State private var picking = false
    @State private var saving = false
    @State private var errorText: String?
    @State private var form = AutomationTriggerForm()
    /// What the form says, worked out when it changes, never in `body`.
    @State private var formError: String?
    @State private var nextRun: String?
    @State private var threads: [(id: AgentID, name: String)] = []
    @State private var models: [String] = []
    @FocusState private var promptFocused: Bool

    private var editing: AutomationKey? {
        if case .edit(let key) = target { return key }
        return nil
    }

    private var hosts: [(id: UUID, name: String)] { vm.automationEditorHosts }

    private var hostName: String {
        hosts.first { $0.id == host }?.name ?? vm.automationHosts.first { $0.id == host }?.name ?? PageHost.localName
    }

    /// Triggers are This Mac's: a host's automation keeps what it has.
    private var local: Bool { host == PageHost.localID }

    private var draft: RemoteAutomationDraft {
        RemoteAutomationDraft(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                              prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                              cwd: folder.trimmingCharacters(in: .whitespacesAndNewlines), enabled: enabled,
                              settings: local ? form.settings : nil)
    }

    private var valid: Bool {
        !draft.name.isEmpty && !draft.prompt.isEmpty && !draft.cwd.isEmpty && (!local || formError == nil)
    }

    private var onCaption: String {
        guard local, form.kind != .manual else {
            return enabled ? "Runs whenever Shepherd starts on \(hostName)" : "Runs only when you run it"
        }
        return enabled ? "Its trigger starts runs" : "Off: its trigger starts nothing; Run now still works"
    }

    var body: some View {
        DialogSheet(title: editing == nil ? "New automation" : "Edit automation",
                    subtitle: "Starts a thread on its host with this prompt: by hand, on a schedule, or when something happens on GitHub.",
                    width: AppLayout.automationSheetWidth, status: saving ? "Saving…" : errorText ?? (local ? formError : nil),
                    actions: [
                        DialogAction("Cancel", kind: .cancel, action: dismiss),
                        DialogAction(editing == nil ? "Save" : "Save changes", kind: .prominent, isEnabled: valid && !saving) { save() },
                    ]) {
            ScrollView {
            VStack(spacing: 0) {
                if editing == nil, hosts.count > 1 {
                    SheetRow("Host") {
                        SHPopupMenu(hostName, minWidth: AppLayout.settingsPopupWidth) {
                            ForEach(hosts, id: \.id) { option in
                                Button(option.name) {
                                    if host != option.id { folder = "" }
                                    host = option.id
                                }
                            }
                        }
                        .accessibilityLabel("Host")
                    }
                }
                SheetRow("Name") {
                    TextField("Name", text: $name, prompt: Text("Nightly migrations dry run").foregroundStyle(Color.sh.textTertiary))
                        .textFieldStyle(.sh)
                        .accessibilityLabel("Name")
                }
                SheetRow("Folder") {
                    HStack(spacing: SH.Space.m) {
                        TextField("Folder", text: $folder, prompt: Text("~/code/project").foregroundStyle(Color.sh.textTertiary))
                            .textFieldStyle(.sh(mono: true))
                            .accessibilityLabel("Folder")
                        Button("Choose…") { picking = true }
                            .buttonStyle(.sh(.ghost, size: .s))
                            .accessibilityLabel("Choose folder")
                    }
                }
                SheetRow("Prompt", alignment: .firstTextBaseline) {
                    TextEditor(text: $prompt)
                        .writingToolsBehavior(.disabled)
                        .focused($promptFocused)
                        .shText(.body)
                        .foregroundStyle(Color.sh.textPrimary)
                        .scrollContentBackground(.hidden)
                        .frame(height: AppLayout.promptEditorHeight)
                        .padding(SH.Space.m)
                        .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Radius.s))
                        .shBorder(Color.sh.lineStrong, radius: SH.Radius.s)
                        .overlay {
                            Color.clear
                                .shFocusRing(promptFocused, radius: SH.Radius.s)
                                .allowsHitTesting(false)
                        }
                        .accessibilityLabel("Prompt")
                }
                if local {
                    triggerSection
                    if form.kind == .manual {
                        // A run starts on the same default every thread does (Settings ▸ Agents, else Shepherd's pi's own).
                        SheetRow("Model") {
                            Text(AutomationEditorSheet.modelLine(vm.settings.defaultModel(piHome: vm.server.pi.home)))
                                .font(.sh(.caption))
                                .foregroundStyle(Color.sh.textSecondary)
                                .accessibilityLabel("Model")
                        }
                    } else {
                        runSection
                    }
                }
                SheetRow("On") {
                    HStack(spacing: SH.Space.m) {
                        Toggle("On", isOn: $enabled)
                            .toggleStyle(.shSwitch)
                            .labelsHidden()
                        Text(onCaption)
                            .font(.sh(.caption))
                            .foregroundStyle(Color.sh.textSecondary)
                    }
                }
            }
            }
            .frame(maxHeight: AppLayout.automationSheetBodyMaxHeight)
            .fixedSize(horizontal: false, vertical: true)
            .shAnimation(.disclosure, value: form)
        }
        .onAppear(perform: load)
        .onChange(of: form, initial: true) { _, form in check(form) }
        .task {
            let server = vm.server
            models = await Task.detached { server.modelListing().models }.value
        }
        .sheet(isPresented: $picking) { picker.dialogSheetFrame() }
    }

    private var picker: some View {
        let hostID = host
        let local = hostID == PageHost.localID
        return RemoteDirectoryPicker(
            hostName: local ? "this Mac" : hostName,
            startPath: folder,
            list: { path in
                if local { return try await LocalDirectoryLister.load(path: path) }
                return try await vm.remoteHosts.listDir(hostID: hostID, path: path)
            },
            choose: { path in
                picking = false
                folder = local ? (path as NSString).abbreviatingWithTildeInPath : path
            },
            cancel: { picking = false }
        )
    }

    // MARK: Trigger

    @ViewBuilder private var triggerSection: some View {
        SheetRow("Trigger") {
            SHSegmentedPicker("Trigger", selection: $form.kind,
                              options: [(.manual, "Manual"), (.schedule, "Schedule"), (.github, "GitHub")])
                .fixedSize()
        }
        switch form.kind {
        case .manual: EmptyView()
        case .schedule: scheduleRows
        case .github: githubRows
        }
    }

    @ViewBuilder private var scheduleRows: some View {
        SheetRow("Repeats") {
            SHSegmentedPicker("Repeats", selection: $form.preset,
                              options: [(.minutes, "Minutes"), (.daily, "Daily"), (.weekly, "Weekly"), (.custom, "Custom")])
                .fixedSize()
        }
        switch form.preset {
        case .minutes:
            SheetRow("Every") {
                SHStepper("Every", value: $form.intervalMinutes, in: 5...1440) { "\($0) min" }
                    .fixedSize()
            }
        case .daily:
            SheetRow("At") { timePicker }
        case .weekly:
            SheetRow("On") {
                HStack(spacing: SH.Space.m) {
                    ForEach(1...7, id: \.self) { day in
                        Toggle(AutomationSchedulePreset.dayName(day), isOn: Binding(
                            get: { form.weekdays.contains(day) },
                            set: { on in if on { form.weekdays.insert(day) } else { form.weekdays.remove(day) } }))
                            .toggleStyle(.shCheckbox)
                            .font(.sh(.ui))
                    }
                }
            }
            SheetRow("At") { timePicker }
        case .custom:
            SheetRow("RRULE") {
                TextField("RRULE", text: $form.customRRule,
                          prompt: Text("FREQ=WEEKLY;BYDAY=MO,TH;BYHOUR=9").foregroundStyle(Color.sh.textTertiary))
                    .textFieldStyle(.sh(mono: true, error: formError != nil && !form.customRRule.isEmpty))
                    .accessibilityLabel("RRULE")
            }
        }
        SheetRow("Next run") {
            Text(nextRun ?? formError ?? "—")
                .font(.sh(.caption))
                .foregroundStyle(nextRun == nil && formError != nil ? Color.sh.failed : Color.sh.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Next run")
                .accessibilityValue(nextRun ?? formError ?? "none")
        }
    }

    private var timePicker: some View {
        DatePicker("Time", selection: Binding(
            get: { Calendar.current.date(from: DateComponents(hour: form.hour, minute: form.minute)) ?? Date() },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                form.hour = parts.hour ?? 0
                form.minute = parts.minute ?? 0
            }), displayedComponents: .hourAndMinute)
            .labelsHidden()
            .datePickerStyle(.field)
            .fixedSize()
    }

    @ViewBuilder private var githubRows: some View {
        ForEach($form.github) { $trigger in
            let index = form.github.firstIndex { $0.id == trigger.id } ?? 0
            VStack(spacing: 0) {
                HStack {
                    SHPageSectionLabel(form.github.count == 1 ? "GitHub trigger" : "GitHub trigger \(index + 1)")
                    Spacer()
                    if form.github.count > 1 {
                        let id = trigger.id
                        Button("Remove") { form.github.removeAll { $0.id == id } }
                            .buttonStyle(.sh(.ghost, size: .s))
                            .accessibilityLabel("Remove GitHub trigger \(index + 1)")
                    }
                }
                .padding(.horizontal, SHDialogMetrics.inset)
                .padding(.top, SH.Space.l)
                SheetRow("Repository") {
                    TextField("Repository", text: $trigger.repo,
                              prompt: Text("The folder's origin").foregroundStyle(Color.sh.textTertiary))
                        .textFieldStyle(.sh(mono: true))
                        .accessibilityLabel("Repository")
                }
                SheetRow("Events", alignment: .firstTextBaseline) {
                    SHFlowLayout(spacing: SH.Space.l, lineSpacing: SH.Space.s) {
                        ForEach(GitHubEventKind.allCases, id: \.self) { kind in
                            Toggle(kind.label.prefix(1).uppercased() + kind.label.dropFirst(), isOn: Binding(
                                get: { trigger.events.contains(kind) },
                                set: { on in if on { trigger.events.insert(kind) } else { trigger.events.remove(kind) } }))
                                .toggleStyle(.shCheckbox)
                                .font(.sh(.ui))
                        }
                    }
                }
                SheetRow("Labels") {
                    TextField("Labels", text: $trigger.labels, prompt: Text("Any label · comma-separated").foregroundStyle(Color.sh.textTertiary))
                        .textFieldStyle(.sh)
                        .accessibilityLabel("Labels")
                }
                SheetRow("Authors") {
                    TextField("Authors", text: $trigger.authors, prompt: Text("Anyone allowed below · logins").foregroundStyle(Color.sh.textTertiary))
                        .textFieldStyle(.sh(mono: true))
                        .accessibilityLabel("Authors")
                }
                SheetRow("Title has") {
                    TextField("Title contains", text: $trigger.titleContains, prompt: Text("Any title").foregroundStyle(Color.sh.textTertiary))
                        .textFieldStyle(.sh)
                        .accessibilityLabel("Title contains")
                }
                SheetRow("Number") {
                    TextField("Issue or PR number", text: $trigger.number, prompt: Text("Any issue or PR").foregroundStyle(Color.sh.textTertiary))
                        .textFieldStyle(.sh(mono: true))
                        .accessibilityLabel("Issue or PR number")
                }
            }
        }
        if form.github.count < GitHubTrigger.maxPerAutomation {
            Button("Add GitHub trigger", systemImage: "plus") { form.github.append(GitHubTriggerForm()) }
                .buttonStyle(.sh(.ghost, size: .s))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, SHDialogMetrics.inset)
                .padding(.vertical, SH.Space.m)
        }
        SheetRow("Who can trigger") {
            SHSegmentedPicker("Who can trigger", selection: $form.authorGate,
                              options: [(.collaborators, "Collaborators"), (.contributors, "Contributors"), (.anyone, "Anyone")])
                .fixedSize()
        }
        if let warning = form.gateWarning {
            DialogBanner(state: .attention, title: "Wider than your collaborators", message: warning)
                .padding(.bottom, SH.Space.m)
        }
    }

    // MARK: Runs

    @ViewBuilder private var runSection: some View {
        SheetRow("Runs go to") {
            HStack(spacing: SH.Space.m) {
                SHSegmentedPicker("Runs go to", selection: Binding(
                    get: { form.thread != nil },
                    set: { existing in form.thread = existing ? (form.thread ?? threads.first?.id) : nil }),
                                  options: [(false, "New thread"), (true, "A thread")])
                    .fixedSize()
                    .disabled(threads.isEmpty && form.thread == nil)
                if let thread = form.thread {
                    SHPopupMenu(threads.first { $0.id == thread }?.name ?? "A thread that's gone", minWidth: AppLayout.settingsPopupWidth) {
                        ForEach(threads, id: \.id) { option in
                            Button(option.name) { form.thread = option.id }
                        }
                    }
                    .accessibilityLabel("Thread")
                }
            }
        }
        if form.thread == nil {
            SheetRow("Workspace") {
                SHSegmentedPicker("Workspace", selection: $form.workspace,
                                  options: [(.worktree, "New worktree"), (.local, "The folder")])
                    .fixedSize()
            }
        }
        SheetRow("Limits") {
            HStack(spacing: SH.Space.l) {
                SHStepper("Runs at once", value: $form.maxConcurrent, in: AutomationLimits.concurrentRange) { "\($0) at once" }
                    .fixedSize()
                SHStepper("Runs a day", value: $form.maxPerDay, in: AutomationLimits.perDayRange) { "\($0) a day" }
                    .fixedSize()
            }
        }
        SheetRow("Model") {
            SHPopupMenu(form.model.isEmpty ? "Default" : form.model, mono: !form.model.isEmpty, minWidth: AppLayout.settingsPopupWidth) {
                Button("Default") { form.model = "" }
                if !models.isEmpty { Divider() }
                ForEach(models, id: \.self) { model in
                    Button(model) { form.model = model }
                }
            }
            .accessibilityLabel("Model")
        }
        SheetRow("Thinking") {
            SHPopupMenu(ThinkingLevel(rawValue: form.thinking)?.title ?? "Default", minWidth: AppLayout.settingsPopupWidth) {
                Button("Default") { form.thinking = "" }
                Divider()
                ForEach(ThinkingLevel.allCases, id: \.self) { level in
                    Button(level.title) { form.thinking = level.rawValue }
                }
            }
            .accessibilityLabel("Thinking")
        }
    }

    private func check(_ form: AutomationTriggerForm) {
        let now = Date()
        formError = form.validationError(now: now)
        nextRun = form.nextRun(after: now).map {
            AutomationsPageModel.when($0, now: now, timeZone: .current, locale: .current)
        }
    }

    /// "Runs on gpt-5 (the default in Settings ▸ Agents)"; with no default anywhere, pi's own pick, named as such.
    static func modelLine(_ model: String?) -> String {
        guard let model else { return "Runs on whatever model Shepherd’s pi picks. Set a default in Settings ▸ Agents." }
        return "Runs on \(model) (the default in Settings ▸ Agents)"
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        // A destination thread is one of This Mac's own threads, not another run.
        let hidden = Set(vm.state.spaces.filter(\.hidden).map(\.id))
        threads = vm.state.agents.filter { $0.automationOrigin == nil && $0.designID == nil && !hidden.contains($0.spaceID) }
            .map { ($0.id, $0.name) }
        guard let key = editing, let saved = vm.automationDraft(key) else { return }
        host = key.host
        name = saved.name
        prompt = saved.prompt
        folder = saved.cwd
        enabled = saved.enabled
        if key.host == PageHost.localID, let automation = vm.state.automations.first(where: { $0.id == key.automation }) {
            form = AutomationTriggerForm(automation)
        }
    }

    private func save() {
        guard valid, !saving else { return }
        saving = true
        errorText = nil
        let key = editing, host = host, draft = draft
        Task { @MainActor in
            do {
                try await vm.saveAutomation(key, host: host, draft: draft)
                saving = false
                dismiss()
            } catch {
                saving = false
                errorText = String(describing: error)
            }
        }
    }
}
