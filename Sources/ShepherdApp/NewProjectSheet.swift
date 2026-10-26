import SwiftUI
import ShepherdRemote
import ShepherdCore
import ShepherdUI

/// New project (ProjectLead-New): Name (required), Goal (optional) and Spaces (optional), then Cancel and Create project.
/// Every measure is the board's, read with the bundled Geist (`SHLeadMetrics.sheet*`). Create sends one `logicalProjects(.create)` to
/// the owner with the chosen Spaces in the same request, so the project and its links commit together or not at all. A failure stays
/// in the sheet with the host's own words and the same ID, so Retry is safe.
struct NewProjectSheet: View {
    var vm: ShepherdViewModel
    /// The draft lives on the view model, so the sheet, the tests and VoiceOver all edit the one value.
    @Binding var draft: NewLogicalProjectDraft
    let dismiss: () -> Void
    @State private var failure: String?
    @State private var choosingFolder = false
    @FocusState private var nameFocused: Bool

    private var spaces: [Space] { vm.linkableLogicalProjectSpaces }
    private var chosen: [Space] { draft.spaces.compactMap { id in spaces.first { $0.id == id } } }
    private var addable: [Space] { spaces.filter { !draft.spaces.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: SHLeadMetrics.sheetGroupGap) {
                field("Name", optional: false) {
                    TextField("e.g. Sample App", text: $draft.name)
                        .textFieldStyle(SHLeadFieldStyle())
                        .focused($nameFocused)
                        .accessibilityLabel("Project name")
                        .onSubmit(create)
                }
                field("Goal", optional: true) {
                    TextField("One line of what you’re trying to get done", text: $draft.goal)
                        .textFieldStyle(SHLeadFieldStyle())
                        .accessibilityLabel("Goal")
                        .onSubmit(create)
                }
                VStack(alignment: .leading, spacing: SHLeadMetrics.sheetLabelGap) {
                    label("Spaces", optional: true)
                    Text("Folders threads work in. Leave it empty and the project adds spaces as the work needs them; it asks you first.")
                        .font(.sh(.caption))
                        .lineSpacing(SHLeadMetrics.sheetHelpLineSpacing)
                        .foregroundStyle(Color.sh.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: SH.Space.s) {
                        ForEach(chosen) { space in chosenRow(space) }
                        addMenu
                    }
                    .padding(.top, SHLeadMetrics.sheetHelpGap - SHLeadMetrics.sheetLabelGap)
                }
            }
            .padding(.horizontal, SHLeadMetrics.sheetSide)
            Spacer(minLength: SH.Space.xl)
            if let failure {
                Text(failure).font(.sh(.caption)).foregroundStyle(Color.sh.failed)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .padding(.horizontal, SHLeadMetrics.sheetSide).padding(.bottom, SH.Space.s)
                    .accessibilityLabel("Could not create the project: \(failure)")
            }
            footer
        }
        // The board's 1pt border is inside its 560: fields are 526 wide, not 528 (the help sentence's wrap depends on it).
        .padding(.horizontal, 1)
        .frame(width: SHLeadMetrics.sheetWidth, height: SHLeadMetrics.sheetHeight, alignment: .topLeading)
        .background(Color.sh.bgRaised)
        .overlay(Rectangle().stroke(Color.sh.lineStrong, lineWidth: 1))
        // A new sheet opens in Name, ready to type. A draft that already has a name keeps no artificial selection of it: the
        // field takes focus when the person clicks it, and an editable control behaves as it does anywhere else.
        .onAppear { if draft.name.isEmpty { nameFocused = true } }
        .shAnimation(.disclosure, value: failure)
        .sheet(isPresented: $choosingFolder) {
            // One owner today: This Mac. The folder becomes a Space here, and the new project links it with its first request.
            ProjectFolderPicker(vm: vm, route: .thisMac, chosen: { space in if !draft.spaces.contains(space) { draft.spaces.append(space) } },
                                close: { choosingFolder = false })
                .dialogSheetFrame()
        }
    }

    // MARK: Parts

    private var header: some View {
        HStack {
            Text("New project").font(.sh(.title, weight: .semibold)).foregroundStyle(Color.sh.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: SH.Space.l)
            Button(action: dismiss) {
                SHLeadCloseMark()
                    .stroke(Color.sh.textSecondary, style: StrokeStyle(lineWidth: SHLeadMetrics.sheetCloseStroke, lineCap: .round))
                    .frame(width: SHLeadMetrics.sheetCloseGlyph, height: SHLeadMetrics.sheetCloseGlyph)
                    .frame(width: SHLeadMetrics.sheetClose, height: SHLeadMetrics.sheetClose)
                    .overlay(Circle().stroke(Color.sh.lineStrong, lineWidth: 1))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(draft.creating)
            .accessibilityLabel("Close")
            // The board's close control sits in a 40pt slot (28pt circle centred), which is what sets the header's height.
            .frame(width: SHLeadMetrics.sheetCloseSlot, height: SHLeadMetrics.sheetCloseSlot)
        }
        .padding(EdgeInsets(top: SH.Space.l + SHLeadMetrics.sheetBorder, leading: SH.Space.xl, bottom: SHLeadMetrics.sheetHeaderBottom, trailing: SH.Space.m))
    }

    private func label(_ title: String, optional: Bool) -> some View {
        // The board sets "optional" after a space in the label's own face (3.04pt), not a layout gap.
        HStack(spacing: 0) {
            Text(optional ? title + " " : title).font(.sh(.ui, weight: .medium)).foregroundStyle(Color.sh.textPrimary)
            if optional { Text("optional").font(.sh(.ui, weight: .regular)).foregroundStyle(Color.sh.textTertiary) }
        }
    }

    private func field<Content: View>(_ title: String, optional: Bool, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: SHLeadMetrics.sheetLabelGap) {
            label(title, optional: optional)
            content()
        }
    }

    private func chosenRow(_ space: Space) -> some View {
        HStack(spacing: SH.Space.m) {
            Image(systemName: "folder").font(.system(size: SHLeadMetrics.toolbarGlyph)).foregroundStyle(Color.sh.textSecondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(space.name).font(.sh(.ui, weight: .medium)).foregroundStyle(Color.sh.textPrimary)
                Text((space.path as NSString).abbreviatingWithTildeInPath).font(.sh(.mono)).foregroundStyle(Color.sh.textTertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: SH.Space.m)
            Button("Remove") { draft.spaces.removeAll { $0 == space.id } }
                .buttonStyle(.shLink(color: Color.sh.textSecondary, font: .sh(.ui)))
                .accessibilityLabel("Remove \(space.name)")
        }
    }

    @ViewBuilder private var addMenu: some View {
        // The same popup as Project settings' "Add a space…" (measured there: 36pt after the value), without its 40pt slot: this sheet's
        // spacing already counts the control as 32pt.
        SHProjectSettingsPopup("Add a space…") {
            ForEach(addable) { space in
                Button(space.name) { draft.spaces.append(space.id) }
            }
            // A fresh profile has no Spaces: the menu still offers a folder (ProjectLead-AddsSpace), registered and added in one step.
            if addable.isEmpty { Button("No spaces to choose from yet") {}.disabled(true) }
            Divider()
            Button(ProjectFolderRoute.thisMac.menuTitle) { choosingFolder = true }
        }
        .padding(.vertical, -SHProjectSettingsMetrics.popupSlotMargin)
        .disabled(draft.creating)
        .accessibilityLabel("Add a space…")
        .help(addable.isEmpty && !spaces.isEmpty ? "Every space is already added. Choose a folder to add another." : "Add a space…")
    }

    private var footer: some View {
        VStack(spacing: 0) {
            SHHairline()
            HStack(spacing: SH.Space.m) {
                Spacer(minLength: SH.Space.l)
                Button("Cancel", action: dismiss)
                    .buttonStyle(SHLeadSheetButton(.ghost))
                    .keyboardShortcut(.cancelAction)
                    .disabled(draft.creating)
                Button(draft.creating ? "Creating…" : "Create project", action: create)
                    .buttonStyle(SHLeadSheetButton(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.canCreate)
            }
            .padding(.horizontal, SHLeadMetrics.sheetSide)
            .padding(.top, SHLeadMetrics.sheetFooterPadding)
            .padding(.bottom, SHLeadMetrics.sheetFooterBottom)
        }
        .background(Color.sh.bgRaised)
    }

    // MARK: Create

    private func create() {
        guard draft.canCreate else { return }
        draft.creating = true
        failure = nil
        let draft = draft
        Task {
            // One owner today: This Mac. The chosen Spaces are its own.
            let created = await vm.logicalProjects.create(home: .local, id: draft.id, name: draft.name, goal: draft.goal, spaces: draft.spaces)
            self.draft.creating = false
            if let created {
                vm.newLogicalProject = nil
                vm.openLogicalProject(LogicalProjectRef(home: .local, id: created.id))
            } else {
                failure = vm.logicalProjects.failure?.message ?? "The project was not created."
            }
        }
    }
}
