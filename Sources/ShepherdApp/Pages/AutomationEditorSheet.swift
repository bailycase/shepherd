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
/// the iOS form has them. Name, prompt, the folder its runs work in, and whether it starts a run
/// when Shepherd starts there; a new one also picks its host. Saving never starts a run.
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
    @FocusState private var promptFocused: Bool

    private var editing: AutomationKey? {
        if case .edit(let key) = target { return key }
        return nil
    }

    private var hosts: [(id: UUID, name: String)] { vm.automationEditorHosts }

    private var hostName: String {
        hosts.first { $0.id == host }?.name ?? vm.automationHosts.first { $0.id == host }?.name ?? PageHost.localName
    }

    private var draft: RemoteAutomationDraft {
        RemoteAutomationDraft(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                              prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                              cwd: folder.trimmingCharacters(in: .whitespacesAndNewlines), enabled: enabled)
    }

    private var valid: Bool { !draft.name.isEmpty && !draft.prompt.isEmpty && !draft.cwd.isEmpty }

    var body: some View {
        DialogSheet(title: editing == nil ? "New automation" : "Edit automation",
                    subtitle: "Starts a thread on its host with this prompt, when you run it or whenever Shepherd starts there.",
                    width: AppLayout.automationSheetWidth, status: saving ? "Saving…" : errorText,
                    actions: [
                        DialogAction("Cancel", kind: .cancel, action: dismiss),
                        DialogAction(editing == nil ? "Save" : "Save changes", kind: .prominent, isEnabled: valid && !saving) { save() },
                    ]) {
            VStack(spacing: 0) {
                if editing == nil, hosts.count > 1 {
                    SheetRow("Host") {
                        NWPopupMenu(hostName, minWidth: AppLayout.settingsPopupWidth) {
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
                    TextField("Name", text: $name, prompt: Text("Nightly migrations dry run").foregroundStyle(Color.nw.textTertiary))
                        .textFieldStyle(.nw)
                }
                SheetRow("Folder") {
                    HStack(spacing: NW.Space.m) {
                        TextField("Folder", text: $folder, prompt: Text("~/code/project").foregroundStyle(Color.nw.textTertiary))
                            .textFieldStyle(.nw(mono: true))
                        Button("Choose…") { picking = true }
                            .buttonStyle(.nw(.ghost, size: .s))
                            .accessibilityLabel("Choose folder")
                    }
                }
                SheetRow("Prompt", alignment: .firstTextBaseline) {
                    TextEditor(text: $prompt)
                        .focused($promptFocused)
                        .nwText(.body)
                        .foregroundStyle(Color.nw.textPrimary)
                        .scrollContentBackground(.hidden)
                        .frame(height: AppLayout.promptEditorHeight)
                        .padding(NW.Space.m)
                        .background(Color.nw.bgRaised, in: RoundedRectangle(cornerRadius: NW.Radius.s))
                        .nwBorder(Color.nw.lineStrong, radius: NW.Radius.s)
                        .overlay {
                            Color.clear
                                .nwFocusRing(promptFocused, radius: NW.Radius.s)
                                .allowsHitTesting(false)
                        }
                        .accessibilityLabel("Prompt")
                }
                SheetRow("On") {
                    HStack(spacing: NW.Space.m) {
                        Toggle("Starts with Shepherd", isOn: $enabled)
                            .toggleStyle(.nwSwitch)
                            .labelsHidden()
                        Text(enabled ? "Runs whenever Shepherd starts on \(hostName)" : "Runs only when you run it")
                            .font(.nw(.caption))
                            .foregroundStyle(Color.nw.textSecondary)
                    }
                }
            }
        }
        .onAppear(perform: load)
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

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let key = editing, let saved = vm.automationDraft(key) else { return }
        host = key.host
        name = saved.name
        prompt = saved.prompt
        folder = saved.cwd
        enabled = saved.enabled
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
