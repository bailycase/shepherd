import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// A new automation, or an existing one's fields (presented): its name, the prompt each run
/// starts with, the host and folder it runs in (one of the host's spaces), and whether it is on.
/// On a host with `automationTriggersCapability` it also sets the trigger, where runs go, who can
/// fire them, the limits and the pins (`draft.settings`); an older host gets the old form and
/// never a setting. Save closes once the host took it.
struct AutomationEditorScreen: View {
    let host: UUID?
    let automation: AutomationID?
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator
    @State private var draft = RemoteAutomationDraft(name: "", prompt: "", cwd: "", enabled: true)
    @State private var chosenHost: UUID?
    /// A new automation's id, minted once: saving again after an answer that never came back
    /// names the same automation, so it can never be saved twice.
    @State private var newID = AutomationID()
    @State private var loaded = false
    @State private var saving = false
    @State private var error: String?
    @State private var form = AutomationTriggerForm()
    @State private var check = AutomationTriggerForm.Check()
    @State private var models: [String] = []
    @FocusState private var focused: Field?

    private enum Field { case name, prompt }

    var body: some View {
        let store = AutomationsStore.of(hosts)
        let target = hosts.host(chosenHost ?? host ?? store.editableHosts.first?.id ?? UUID())
        let folders = AutomationFolders.of(target?.state.spaces ?? [], current: draft.cwd)
        let triggers = target?.supports(RemoteProtocol.automationTriggersCapability) == true
        let canSave = target?.connectedClient != nil && target?.supports(RemoteProtocol.automationsCapability) == true
            && AutomationFolders.ready(draft) && !saving && (!triggers || check.error == nil)
        Form {
            Section {
                TextField("Name", text: $draft.name)
                    .font(.sh(.ui))
                    .focused($focused, equals: .name)
                    .submitLabel(.next)
                    .onSubmit { focused = .prompt }
                    .accessibilityLabel("Automation name")
            } header: {
                Text("Name")
            }
            Section {
                TextEditor(text: $draft.prompt)
                    .font(.sh(.body))
                    .frame(minHeight: MobileLayout.automationPromptMinHeight)
                    .focused($focused, equals: .prompt)
                    .accessibilityLabel("Prompt")
            } header: {
                Text("Prompt")
            } footer: {
                Text("Each run starts a new thread with this prompt.")
            }
            Section {
                if automation == nil, store.editableHosts.count > 1 {
                    Picker("Host", selection: Binding(get: { target?.id ?? UUID() }, set: { chosenHost = $0; draft.cwd = "" })) {
                        ForEach(store.editableHosts) { host in Text(host.name).tag(host.id) }
                    }
                }
                if folders.isEmpty {
                    Text("\(target?.name ?? "The host") has no spaces yet. Add one from New thread.")
                        .font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                } else {
                    Picker("Folder", selection: $draft.cwd) {
                        if draft.cwd.isEmpty { Text("Choose…").tag("") }
                        ForEach(folders, id: \.path) { folder in
                            Text(folder.name).tag(folder.path)
                        }
                    }
                }
            } header: {
                Text("Where it runs")
            } footer: {
                if !draft.cwd.isEmpty { Text(draft.cwd).font(.sh(.mono)) }
            }
            if triggers {
                AutomationTriggerSections(form: $form, check: check, hostName: target?.name ?? "The host",
                                          threads: AutomationThreads.of(target?.state ?? ShepherdState(), current: form.thread),
                                          models: models)
            }
            let manual = !triggers || form.kind == .manual
            Section {
                HStack {
                    Text(manual ? "Starts with Shepherd" : "On").font(.sh(.ui))
                        .accessibilityHidden(true)
                    Spacer(minLength: SH.Space.m)
                    SHAutomationSwitch(manual ? "Starts with Shepherd" : "On", isOn: draft.enabled) { draft.enabled = $0 }
                }
            } footer: {
                Text(manual ? "On: \(target?.name ?? "the host") starts a run each time Shepherd launches there. Run now starts one any time."
                     : "On: its trigger starts runs. Off: nothing fires until you turn it on. Run now starts one any time.")
            }
            if let error {
                Section {
                    Text(error).font(.sh(.caption)).foregroundStyle(Color.sh.failed)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.sh.bgWindow)
        .navigationTitle(automation == nil ? "New automation" : "Edit automation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { navigator.dismissPresented() }
            }
            ToolbarItem(placement: .confirmationAction) {
                if saving {
                    ProgressView().progressViewStyle(SHSpinnerStyle())
                } else {
                    Button("Save") { save(host: target?.id, store: store) }.disabled(!canSave)
                }
            }
        }
        .onAppear { load(store) }
        .onChange(of: form, initial: true) { check = form.check() }
        .task(id: target?.id) {
            guard triggers, let target else { return }
            models = await ComposerStates.shared.listing(for: target)?.models ?? []
        }
    }

    private func load(_ store: AutomationsStore) {
        guard !loaded else { return }
        loaded = true
        if let host, let automation, let row = store.model.row(AutomationKey(host: host, automation: automation)) {
            draft = RemoteAutomationDraft(name: row.name, prompt: row.prompt, cwd: row.cwd, enabled: row.enabled)
            form = AutomationTriggerForm(row.settings)
        } else {
            focused = .name
        }
    }

    private func save(host: UUID?, store: AutomationsStore) {
        guard let host, !saving else { return }
        saving = true
        error = nil
        let key = AutomationKey(host: host, automation: automation ?? newID)
        let route = MobileRoute.automations(.edit(host: self.host, automation: automation))
        var draft = draft
        // Only a host that takes triggers gets settings: an older one would drop them silently.
        draft.settings = store.supportsTriggers(host) ? form.settings : nil
        Task {
            do {
                try await store.save(key, draft: draft, creating: automation == nil)
                // Cancel may have closed the form while the host answered; close only this one.
                if navigator.presented?.route == route { navigator.dismissPresented() }
            } catch {
                self.error = AutomationsModel.failureText(automation == nil ? .create(draft: draft) : .update(draft: draft), error)
            }
            saving = false
        }
    }
}

/// The folders an automation can run in: the host's spaces, plus its current folder when that
/// is none of them.
enum AutomationFolders {
    struct Folder: Equatable {
        let name: String
        let path: String
    }

    static func of(_ spaces: [Space], current: String) -> [Folder] {
        var folders = spaces.filter { !$0.hidden }.map { Folder(name: $0.name, path: $0.path) }
        if !current.isEmpty, !folders.contains(where: { $0.path == current }) {
            folders.append(Folder(name: (current as NSString).lastPathComponent, path: current))
        }
        return folders
    }

    /// A name, a prompt and a folder: what the host needs.
    static func ready(_ draft: RemoteAutomationDraft) -> Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !draft.cwd.isEmpty
    }
}
