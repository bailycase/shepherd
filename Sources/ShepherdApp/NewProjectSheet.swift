import SwiftUI
import ShepherdCore
import ShepherdUI

/// New project (ProjectLead-New): Name (required), Goal (optional) and Spaces (optional), then Cancel and Create project.
/// Every measure is the board's, read with the bundled Geist (`NWLeadMetrics.sheet*`). Create sends one `logicalProjects(.create)` to
/// the owner with the chosen Spaces in the same request, so the project and its links commit together or not at all. A failure stays
/// in the sheet with the host's own words and the same ID, so Retry is safe.
struct NewProjectSheet: View {
    var vm: ShepherdViewModel
    /// The draft lives on the view model, so the sheet, the tests and VoiceOver all edit the one value.
    @Binding var draft: NewLogicalProjectDraft
    let dismiss: () -> Void
    @State private var failure: String?
    @FocusState private var nameFocused: Bool

    private var spaces: [Space] { vm.linkableLogicalProjectSpaces }
    private var chosen: [Space] { draft.spaces.compactMap { id in spaces.first { $0.id == id } } }
    private var addable: [Space] { spaces.filter { !draft.spaces.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: NWLeadMetrics.sheetGroupGap) {
                field("Name", optional: false) {
                    TextField("e.g. Gamecards", text: $draft.name)
                        .textFieldStyle(NWLeadFieldStyle())
                        .focused($nameFocused)
                        .accessibilityLabel("Project name")
                        .onSubmit(create)
                }
                field("Goal", optional: true) {
                    TextField("One line of what you’re trying to get done", text: $draft.goal)
                        .textFieldStyle(NWLeadFieldStyle())
                        .accessibilityLabel("Goal")
                        .onSubmit(create)
                }
                VStack(alignment: .leading, spacing: NWLeadMetrics.sheetLabelGap) {
                    label("Spaces", optional: true)
                    Text("Folders threads work in. Leave it empty and the project adds spaces as the work needs them; it asks you first.")
                        .font(.nw(.caption))
                        .lineSpacing(NWLeadMetrics.sheetHelpLineSpacing)
                        .foregroundStyle(Color.nw.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: NW.Space.s) {
                        ForEach(chosen) { space in chosenRow(space) }
                        addMenu
                    }
                    .padding(.top, NWLeadMetrics.sheetHelpGap - NWLeadMetrics.sheetLabelGap)
                }
            }
            .padding(.horizontal, NWLeadMetrics.sheetSide)
            Spacer(minLength: NW.Space.xl)
            if let failure {
                Text(failure).font(.nw(.caption)).foregroundStyle(Color.nw.failed)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .padding(.horizontal, NWLeadMetrics.sheetSide).padding(.bottom, NW.Space.s)
                    .accessibilityLabel("Could not create the project: \(failure)")
            }
            footer
        }
        // The board's 1pt border is inside its 560: fields are 526 wide, not 528 (the help sentence's wrap depends on it).
        .padding(.horizontal, 1)
        .frame(width: NWLeadMetrics.sheetWidth, height: NWLeadMetrics.sheetHeight, alignment: .topLeading)
        .background(Color.nw.bgRaised)
        .overlay(Rectangle().stroke(Color.nw.lineStrong, lineWidth: 1))
        // A new sheet opens in Name, ready to type. A draft that already has a name keeps no artificial selection of it: the
        // field takes focus when the person clicks it, and an editable control behaves as it does anywhere else.
        .onAppear { if draft.name.isEmpty { nameFocused = true } }
        .nwAnimation(.disclosure, value: failure)
    }

    // MARK: Parts

    private var header: some View {
        HStack {
            Text("New project").font(.nw(.title, weight: .semibold)).foregroundStyle(Color.nw.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: NW.Space.l)
            Button(action: dismiss) {
                NWLeadCloseMark()
                    .stroke(Color.nw.textSecondary, style: StrokeStyle(lineWidth: NWLeadMetrics.sheetCloseStroke, lineCap: .round))
                    .frame(width: NWLeadMetrics.sheetCloseGlyph, height: NWLeadMetrics.sheetCloseGlyph)
                    .frame(width: NWLeadMetrics.sheetClose, height: NWLeadMetrics.sheetClose)
                    .overlay(Circle().stroke(Color.nw.lineStrong, lineWidth: 1))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(draft.creating)
            .accessibilityLabel("Close")
            // The board's close control sits in a 40pt slot (28pt circle centred), which is what sets the header's height.
            .frame(width: NWLeadMetrics.sheetCloseSlot, height: NWLeadMetrics.sheetCloseSlot)
        }
        .padding(EdgeInsets(top: NW.Space.l + NWLeadMetrics.sheetBorder, leading: NW.Space.xl, bottom: NWLeadMetrics.sheetHeaderBottom, trailing: NW.Space.m))
    }

    private func label(_ title: String, optional: Bool) -> some View {
        // The board sets "optional" after a space in the label's own face (3.04pt), not a layout gap.
        HStack(spacing: 0) {
            Text(optional ? title + " " : title).font(.nw(.ui, weight: .medium)).foregroundStyle(Color.nw.textPrimary)
            if optional { Text("optional").font(.nw(.ui, weight: .regular)).foregroundStyle(Color.nw.textTertiary) }
        }
    }

    private func field<Content: View>(_ title: String, optional: Bool, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: NWLeadMetrics.sheetLabelGap) {
            label(title, optional: optional)
            content()
        }
    }

    private func chosenRow(_ space: Space) -> some View {
        HStack(spacing: NW.Space.m) {
            Image(systemName: "folder").font(.system(size: NWLeadMetrics.toolbarGlyph)).foregroundStyle(Color.nw.textSecondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(space.name).font(.nw(.ui, weight: .medium)).foregroundStyle(Color.nw.textPrimary)
                Text((space.path as NSString).abbreviatingWithTildeInPath).font(.nw(.mono)).foregroundStyle(Color.nw.textTertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: NW.Space.m)
            Button("Remove") { draft.spaces.removeAll { $0 == space.id } }
                .buttonStyle(.nwLink(color: Color.nw.textSecondary, font: .nw(.ui)))
                .accessibilityLabel("Remove \(space.name)")
        }
    }

    @ViewBuilder private var addMenu: some View {
        // The same popup as Project settings' "Add a space…" (measured there: 36pt after the value), without its 40pt slot: this sheet's
        // spacing already counts the control as 32pt.
        NWProjectSettingsPopup("Add a space…") {
            ForEach(addable) { space in
                Button(space.name) { draft.spaces.append(space.id) }
            }
        }
        .padding(.vertical, -NWProjectSettingsMetrics.popupSlotMargin)
        .disabled(addable.isEmpty)
        .accessibilityLabel("Add a space…")
        .help(addable.isEmpty ? (spaces.isEmpty ? "Add a space in Settings ▸ Spaces first." : "Every space is already added.") : "Add a space…")
    }

    private var footer: some View {
        VStack(spacing: 0) {
            NWHairline()
            HStack(spacing: NW.Space.m) {
                Spacer(minLength: NW.Space.l)
                Button("Cancel", action: dismiss)
                    .buttonStyle(NWLeadSheetButton(.ghost))
                    .keyboardShortcut(.cancelAction)
                    .disabled(draft.creating)
                Button(draft.creating ? "Creating…" : "Create project", action: create)
                    .buttonStyle(NWLeadSheetButton(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.canCreate)
            }
            .padding(.horizontal, NWLeadMetrics.sheetSide)
            .padding(.top, NWLeadMetrics.sheetFooterPadding)
            .padding(.bottom, NWLeadMetrics.sheetFooterBottom)
        }
        .background(Color.nw.bgRaised)
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
