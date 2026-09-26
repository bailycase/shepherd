import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

/// The Tweak tab on iPad: DZTweak's anatomy in the 360pt pane (no iPad board draws its content):
/// the header naming the selection, a group per kind of control, the scope when the element has
/// a name, and Reset and "Ask the agent instead…" pinned under them. A slider previews on the
/// board's live view as it drags and writes once, on release, through `designs.v1` (the host's own
/// board mutations and checks); a stale revision reads the design again and goes once more.
struct PadDesignTweakPane: View {
    @Bindable var model: DesignTweakModel
    let target: DesignTweakTarget?
    /// "Ask the agent instead…": the chat.
    let ask: () -> Void
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        let shown = model.presentation
        VStack(spacing: 0) {
            if shown.isEmpty {
                NWTweakHeader(board: "Nothing selected", element: nil, note: "Select an element on the canvas to tweak it.")
                Spacer(minLength: 0)
            } else {
                NWTweakHeader(board: shown.board, element: shown.element,
                              note: shown.problem ?? "Changes show on the canvas as you drag.")
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(shown.groups.enumerated()), id: \.element.id) { index, group in
                            NWTweakGroup(group.title, divided: index < shown.groups.count - 1 || shown.scopeName != nil) {
                                ForEach(group.rows) { row in PadDesignTweakRow(row: row, model: model) }
                            }
                        }
                        if let name = shown.scopeName {
                            NWTweakGroup("Apply to", divided: false) {
                                NWTweakRow("Scope") {
                                    NWTweakScope(selection: Binding(get: { model.scope == .every ? .every : .board },
                                                                    set: { model.scope = $0 == .every ? .every : .board }),
                                                 every: "Every \(name)")
                                }
                                if let note = shown.scopeNote { NWTweakNote(note) }
                            }
                        }
                    }
                }
                NWTweakFooter(canReset: shown.canReset, reset: { model.reset() }, ask: ask)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { model.undoManager = undoManager }
        .onChange(of: undoManager) { _, manager in model.undoManager = manager }
        .task(id: target) { await model.select(target) }
    }
}

/// One row's control, bound to the model.
private struct PadDesignTweakRow: View {
    let row: DesignTweakRow
    let model: DesignTweakModel
    @State private var latest: Double?
    @State private var latestStep: Int?

    var body: some View {
        switch row.control {
        case .steps(let values, let index):
            NWTweakRow(row.label, layout: .slider) {
                NWValueSlider(row.label, value: Binding(get: { Double(index) }, set: { step(Int($0), .changed) }),
                              in: 0...Double(max(1, values.count - 1)), step: 1,
                              format: { DesignTweakControls.format(values[min(max(0, Int($0)), values.count - 1)]) },
                              onEditingChanged: { editing in if !editing { step(nil, .ended) } })
            }
        case .slider(let value, let min, let max, let step):
            NWTweakRow(row.label, layout: .slider) {
                NWValueSlider(row.label, value: Binding(get: { value }, set: { set(.number($0), .changed) }),
                              in: min...max, step: step, format: { DesignTweakControls.format($0) },
                              onEditingChanged: { editing in if !editing { set(.number(latest ?? value), .ended) } })
            }
        case .choice(let options, let selected):
            NWTweakRow(row.label) {
                NWSegmentedPicker(row.label, selection: Binding(get: { selected ?? "" }, set: choose),
                                  options: options.map { ($0.value, $0.title) }, size: .s)
            }
        case .menu(let options, let selected):
            NWTweakRow(row.label) {
                Picker(row.label, selection: Binding(get: { selected ?? "" }, set: choose)) {
                    ForEach(options, id: \.value) { Text($0.title).tag($0.value) }
                }
                .labelsHidden()
                .fixedSize()
            }
        case .colors(let colors, let selected):
            NWTweakRow(row.label) {
                NWTokenChipFlow {
                    ForEach(colors) { color in
                        NWTokenChip(color.title, swatch: Color(light: color.hex, dark: color.hex), isSelected: color.id == selected) {
                            pick(color)
                        }
                    }
                }
                // The pane is narrower than the Mac's: the chips wrap within what the row leaves.
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        case .toggle(let on):
            NWTweakRow(row.label) {
                Toggle(row.label, isOn: Binding(get: { on }, set: { set(.bool($0), .ended) }))
                    .toggleStyle(.nwSwitch)
                    .labelsHidden()
            }
        case .stepper(let value):
            NWTweakRow(row.label) {
                NWStepper(row.label, value: Binding(get: { value }, set: { set(.number(Double($0)), .ended) }), in: -9999...9999)
            }
        case .text(let text):
            NWTweakRow(row.label) {
                PadDesignTweakTextField(label: row.label, text: text) { typed in
                    if case .prop(let name) = row.id { model.setPropText(name, typed) }
                }
            }
        }
    }

    private func step(_ index: Int?, _ phase: DesignTweakModel.Phase) {
        guard case .style(let property) = row.id else { return }
        if let index { latestStep = index }
        guard let target = index ?? latestStep ?? currentIndex else { return }
        model.setStep(property, index: target, phase: phase)
        if phase == .ended { latestStep = nil }
    }

    private var currentIndex: Int? {
        if case .steps(_, let index) = row.control { return index }
        return nil
    }

    private func set(_ value: JSONValue, _ phase: DesignTweakModel.Phase) {
        guard case .prop(let name) = row.id else { return }
        if case .number(let number) = value, phase == .changed { latest = number }
        model.setProp(name, value, phase: phase)
        if phase == .ended { latest = nil }
    }

    private func choose(_ value: String) {
        switch row.id {
        case .style(let property): model.choose(property, value)
        case .prop(let name): model.setPropChoice(name, value)
        }
    }

    private func pick(_ color: DesignTweakColor) {
        switch row.id {
        case .style(let property): model.choose(property, color: color)
        case .prop: set(.string(color.hex), .ended)
        }
    }
}

/// A prop's text, written when the field is submitted or loses the keyboard.
private struct PadDesignTweakTextField: View {
    let label: String
    let text: String
    let commit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(label, text: $draft)
            .nwField(focused: focused)
            .focused($focused)
            .frame(maxWidth: MobileLayout.padDesignTweakFieldWidth)
            .onAppear { draft = text }
            .onChange(of: text) { _, now in if !focused { draft = now } }
            .onSubmit { if draft != text { commit(draft) } }
            .onChange(of: focused) { _, now in if !now, draft != text { commit(draft) } }
    }
}
