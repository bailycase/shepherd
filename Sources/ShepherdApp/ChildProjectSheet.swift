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
        SHSettingsSheet("Add child space", subtitle: model.parentName, detail: model.parentPath, width: AppLayout.spaceChildWidth) {
            HStack(spacing: AppLayout.spaceChildSegGap) {
                Text("Folder source").foregroundStyle(Color.sh.textSecondary)
                SHSegmentedPicker("Folder source", selection: $model.create, options: [(true, "New folder"), (false, "Existing folder")])
                    .fixedSize()
            }
            .font(.shSans(SHSettingsSheetMetrics.textSize))
            VStack(alignment: .leading, spacing: 0) {
                SHSheetFieldLabel(model.create ? "Folder name" : "Folder path")
                SHSheetField(focused: focused == .folder) {
                    TextField(model.create ? "Folder name" : "Folder path", text: $model.folder)
                        .textFieldStyle(.plain).font(.shMono(SHSettingsSheetMetrics.monoSize)).focused($focused, equals: .folder)
                    if !model.create {
                        Button("Browse…") { model.browsing = true }.buttonStyle(.sh(.secondary))
                    }
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                SHSheetFieldLabel("Display name")
                SHSheetField(focused: focused == .name) {
                    TextField("Display name", text: $model.displayName, prompt: Text("Defaults to folder name").foregroundStyle(Color.sh.textTertiary))
                        .textFieldStyle(.plain).font(.shSans(SHSettingsSheetMetrics.textSize)).focused($focused, equals: .name)
                }
            }
            SHSheetParagraph(model.status, style: .small).foregroundStyle(model.error != nil ? Color.sh.failed : Color.sh.textTertiary)
                .textSelection(.enabled)
        } actions: {
            Button("Cancel", action: dismiss).buttonStyle(.sh(.ghost)).keyboardShortcut(.cancelAction)
            Button(model.actionTitle) {
                Task { if await model.submit() { dismiss() } }
            }
            .buttonStyle(.sh(.primary)).keyboardShortcut(.defaultAction).disabled(!model.canSubmit)
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
}
