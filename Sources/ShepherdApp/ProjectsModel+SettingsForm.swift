import Foundation
import ShepherdProtocol

/// The Settings tab's form controls. Each writes the draft's JSON, so Save, Discard and the
/// file's conflict check stay the editor's.
extension ProjectsModel {
    var formEditable: Bool {
        fileLoaded && selectedFile?.category == .pi && selected?.unavailable == nil && !saving && formSettings != nil
    }

    /// The selected space holds other spaces' folders, so they inherit its startup defaults.
    var hasInheritingChildren: Bool {
        guard let selected else { return false }
        return rows.contains { $0.host.id == selected.host.id && ProjectNesting.parent(of: $0.project.directory, among: [selected.project.directory]) != nil }
    }

    func setForm(_ row: SpaceSettingsForm.Row, _ input: String) {
        guard formEditable, let object = formSettings else { return }
        write(SpaceSettingsForm.applying(row.key, input, control: row.control, to: object, inherited: formInherited))
    }

    func resetForm(_ row: SpaceSettingsForm.Row) { setForm(row, "") }

    func toggleFormTool(_ tool: String, on: Bool) {
        guard formEditable, let object = formSettings, object["defaultTools"] != nil else { return }
        write(SpaceSettingsForm.toggling(tool, on: on, in: object, inherited: formInherited))
    }

    /// Discard: back to the saved file, or after a conflict, Reload latest (confirmed first).
    func discardForm() {
        guard !saving else { return }
        if conflict { pending = .reload } else { draft = saved ?? "" }
    }

    /// A form that ends where the file started keeps the file's own text, so it isn't dirty.
    private func write(_ object: [String: Any]) {
        if let saved, let original = SpaceSettingsForm.parse(saved), NSDictionary(dictionary: original).isEqual(to: object) {
            draft = saved
        } else if saved == nil, object.isEmpty {
            draft = ""
        } else if let text = SpaceSettingsForm.serialize(object) {
            draft = text
        }
    }
}
