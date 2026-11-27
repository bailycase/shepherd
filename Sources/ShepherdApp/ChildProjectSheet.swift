import Foundation
import Observation
import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdSessions

@MainActor @Observable
final class ChildProjectModel: Identifiable {
    let id = UUID()
    let parentPath: String
    let parentName: String
    var create = true
    var folder = ""
    var displayName = ""
    var browsing = false
    private(set) var busy = false
    private(set) var error: String?
    @ObservationIgnored private let register: (ProjectRequest) async throws -> Void

    init(parentPath: String, parentName: String, register: @escaping (ProjectRequest) async throws -> Void) {
        self.parentPath = parentPath
        self.parentName = parentName
        self.register = register
    }

    var actionTitle: String { create ? "Create and add" : "Add space" }
    var canSubmit: Bool { !busy && !folder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var status: String { error ?? (busy ? "Adding space…" : create ? "Creates a folder if missing; reuses an existing matching folder." : "The folder must be inside the parent space.") }

    func submit() async -> Bool {
        guard canSubmit else { return false }
        error = nil
        if create && (folder == "." || folder == ".." || folder.contains("/") || folder.contains("\0")) {
            error = "Enter a single folder name, without slashes."
            return false
        }
        let path = create ? (parentPath as NSString).appendingPathComponent(folder) : folder
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? URL(fileURLWithPath: path).lastPathComponent : trimmed
        busy = true
        defer { busy = false }
        do {
            try await register(.child(parentPath: parentPath, path: path, name: name, create: create))
            return true
        } catch {
            self.error = String(describing: error)
            return false
        }
    }
}

struct ChildProjectSheet: View {
    @Bindable var model: ChildProjectModel
    let dismiss: () -> Void
    @FocusState private var focused: Field?
    private enum Field: Hashable { case folder, name }

    var body: some View {
        SpaceSheet(title: "Add child space", caption: AnyView(VStack(alignment: .leading, spacing: SH.Space.xs) {
            SpaceSheetCaption(text: model.parentName)
            SpaceSheetCaption(text: model.parentPath, mono: true)
        }), width: AppLayout.spaceChildWidth) {
            row("Folder source") {
                SpaceKindTabs(label: "Folder source", selection: $model.create, options: [(true, "New folder"), (false, "Existing folder")], compact: true)
            }
            row(model.create ? "Folder name" : "Folder path") {
                SpaceSheetField(focused: focused == .folder) {
                    TextField(model.create ? "Folder name" : "Folder path", text: $model.folder)
                        .textFieldStyle(.plain).font(.shMono(SHCardSheetMetrics.codeSize)).focused($focused, equals: .folder)
                    if !model.create {
                        Button("Browse…") { model.browsing = true }.buttonStyle(SpaceLinkStyle(tone: .strong))
                    }
                }
            }
            row("Display name") {
                SpaceSheetField(focused: focused == .name) {
                    TextField("Display name", text: $model.displayName, prompt: Text("Defaults to folder name").foregroundStyle(Color.sh.textTertiary))
                        .textFieldStyle(.plain).font(.sh(.ui)).focused($focused, equals: .name)
                }
            }
            SpaceSheetNote(text: model.status, failed: model.error != nil).textSelection(.enabled)
        } actions: {
            Button("Cancel", action: dismiss).buttonStyle(SpaceBarStyle()).keyboardShortcut(.cancelAction)
            Button(model.actionTitle) {
                Task { if await model.submit() { dismiss() } }
            }
            .buttonStyle(SpaceBarStyle(kind: .primary)).keyboardShortcut(.defaultAction).disabled(!model.canSubmit)
        }
        .disabled(model.busy)
        .interactiveDismissDisabled(model.busy)
        .onAppear { focused = .folder }
        .sheet(isPresented: $model.browsing) {
            RemoteDirectoryPicker(title: "Choose child folder", actionTitle: "Choose", hostName: "This Mac",
                                  startPath: model.parentPath,
                                  list: { try await LocalDirectoryLister.load(path: $0) },
                                  choose: { model.folder = $0; model.browsing = false },
                                  cancel: { model.browsing = false })
        }
    }

    /// A label column and its control (`gspcs-frow`).
    private func row<Control: View>(_ label: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: SH.Space.l) {
            Text(label).font(.sh(.ui)).foregroundStyle(Color.sh.textSecondary).frame(width: AppLayout.spaceSheetLabelWidth, alignment: .leading)
            control().frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.top, SH.Space.l)
    }
}
