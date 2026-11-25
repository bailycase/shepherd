import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdUI
import UniformTypeIdentifiers

// The views of deleting and importing designs (DesignLifecycleStates): a design's and a system's
// menu, the dialogs, the toast, and the drop on Designs. Their words are `DesignLifecycle`'s.

/// A design's or a system's menu (DesignMenu, SystemMenu): its items with their glyphs, a
/// hairline between sections, the destructive one red, and an item that's off with why under it.
struct DesignMenuItems: View {
    let menu: DesignMenu
    let perform: (DesignMenuAction) -> Void

    var body: some View {
        ForEach(Array(menu.sections.enumerated()), id: \.offset) { index, section in
            if index > 0 { Divider() }
            ForEach(section) { item in
                if let reason = item.disabledReason {
                    Button {} label: {
                        Label {
                            Text(item.title)
                            Text(reason)
                        } icon: {
                            Image(systemName: item.symbol)
                        }
                    }
                    .disabled(true)
                } else {
                    Button(role: item.destructive ? .destructive : nil) { perform(item.action) } label: {
                        Label(item.title, systemImage: item.symbol)
                    }
                }
            }
        }
    }
}

// MARK: Dialogs

/// Delete design (DeleteDesignDialog): names the design, lists what goes and what stays, says
/// Undo is there; while its agent draws, the warning and "Stop and delete". Delete is the only
/// red thing.
struct DeleteDesignDialog: View {
    let words: DeleteDesignWords
    let delete: () -> Void
    let cancel: () -> Void
    @State private var remember = false

    var body: some View {
        SHDesignSheet(title: words.title) {
            if let warning = words.warning {
                SHDesignAlertWarning(warning)
            }
            SHDesignSheetFacts {
                ForEach(Array(words.lines.enumerated()), id: \.offset) { index, line in
                    SHDesignSheetFact(Self.label(for: line, at: index, in: words.lines), Self.text(line))
                }
            }
            SHDesignSheetNote(words.note)
        } leading: {
            Toggle("Don’t ask again", isOn: $remember)
                .toggleStyle(.shSheetCheck)
        } actions: {
            Button("Cancel", action: cancel)
                .buttonStyle(.shSheet(.quiet))
                .keyboardShortcut(.cancelAction)
            Button(words.confirm) {
                if remember { AppSettings.shared.skip(.deleteDesign, with: words.confirm) }
                delete()
            }
            .buttonStyle(.shSheet(.danger))
        }
    }

    /// "Goes" over the first line that goes, "Stays" over the first that stays.
    static func label(for line: DeleteDesignWords.Line, at index: Int, in lines: [DeleteDesignWords.Line]) -> String? {
        guard index == lines.firstIndex(where: { $0.role == line.role }) else { return nil }
        return line.role == .goes ? "Goes" : "Stays"
    }

    static func text(_ line: DeleteDesignWords.Line) -> Text {
        var text = Text("")
        if let lead = line.lead { text = Text("\(text)\(lead)") }
        text = Text("\(text)\(line.text)")
        if let mono = line.mono { text = Text("\(text)\(SHDesignAlertMessage.mono(mono))") }
        if let tail = line.tail { text = Text("\(text)\(tail)") }
        return text
    }
}

/// Delete design system (DeleteSystemDialog): what goes, the designs that use it (they keep
/// their copy), the repo it came from (never touched); while it is built, "Stop and delete".
struct DeleteSystemDialog: View {
    let words: DeleteSystemWords
    let delete: () -> Void
    let cancel: () -> Void
    @State private var remember = false

    var body: some View {
        SHDesignSheet(title: words.title) {
            SHDesignAlertMessage(message)
            SHDesignSheetFacts {
                ForEach(Array(words.lines.filter { $0.role == .stays }.enumerated()), id: \.offset) { index, line in
                    SHDesignSheetFact(index == 0 ? "Stays" : nil, Self.text(line))
                }
            }
            if let note = words.lines.first(where: { $0.role == .note }) {
                SHDesignSheetNote(note.text)
            }
        } leading: {
            Toggle("Don’t ask again", isOn: $remember)
                .toggleStyle(.shSheetCheck)
        } actions: {
            Button("Cancel", action: cancel)
                .buttonStyle(.shSheet(.quiet))
                .keyboardShortcut(.cancelAction)
            Button(words.confirm) {
                if remember { AppSettings.shared.skip(.deleteDesignSystem, with: words.confirm) }
                delete()
            }
            .buttonStyle(.shSheet(.danger))
        }
    }

    private var message: Text {
        guard let mono = words.messageMono else { return Text(words.message) }
        return Text("\(words.message)\(SHDesignAlertMessage.mono(mono))\(words.messageTail ?? "")")
    }

    static func text(_ line: DeleteSystemWords.Line) -> Text {
        var text = Text("")
        if let lead = line.lead { text = Text("\(text)\(lead)") }
        text = Text("\(text)\(line.text)")
        if let mono = line.mono { text = Text("\(text)\(SHDesignAlertMessage.mono(mono))") }
        if let tail = line.tail { text = Text("\(text)\(tail)") }
        return text
    }
}

/// What an import asks (ImportFailed, ImportAgain): why it failed and that nothing was imported;
/// boards that can't be read, with Cancel import and Import the other N; or the same project
/// already in Designs, with a separate copy or the one there is.
struct DesignImportDialog: View {
    let prompt: DesignImportPrompt
    let dismiss: () -> Void
    let resolve: () -> Void
    let openExisting: () -> Void

    var body: some View {
        switch prompt {
        case .failed(let file, let failure):
            failed(file: file, failure: failure)
        case .unreadable(let preview):
            if let failure = preview.unreadableFailure { failed(file: preview.file, failure: failure) }
        case .again(let preview, let existing, let copyName):
            again(ImportAgainWords(preview: preview, existing: existing, copyName: copyName))
        }
    }

    private func failed(file: String, failure: DesignImportFailure) -> some View {
        SHDesignSheet(title: DesignImportFailure.title(file: file)) {
            SHDesignAlertMessage(Self.message(failure))
            if !failure.listedLinks.isEmpty {
                SHDesignAlertLinks(failure.listedLinks.map { SHDesignAlertLinks.Link(from: $0.board, to: $0.target) })
            }
            SHDesignSheetNote(failure.footer)
        } actions: {
            if case .unreadableBoards(_, let readable) = failure {
                Button("Cancel import", action: dismiss)
                    .buttonStyle(.shSheet(.quiet))
                    .keyboardShortcut(.cancelAction)
                Button(readable == 1 ? "Import the other board" : "Import the other \(readable)", action: resolve)
                    .buttonStyle(.shSheet(.pill))
                    .keyboardShortcut(.defaultAction)
            } else {
                if failure.offersAnother {
                    Button("Choose another…", action: resolve)
                        .buttonStyle(.shSheet(.link))
                }
                Button("OK", action: dismiss)
                    .buttonStyle(.shSheet(.pill))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// The failure's message, with canvas.json in mono and an unreadable board's name bold.
    static func message(_ failure: DesignImportFailure) -> Text {
        switch failure {
        case .notAProject:
            return Text("There’s no \(SHDesignAlertMessage.mono("canvas.json", size: SHDesignSheetMetrics.monoSize)) inside, so it isn’t a Claude Design project. Export the project from Claude Design as a ZIP or folder, then try again.")
        case .unreadableBoards(let boards, let readable) where boards.count == 1:
            let board = boards[0]
            let rest = readable == 1 ? "The other board is fine." : "The other \(readable) boards are fine."
            return Text("The board \(SHDesignAlertMessage.strong(board.title)) couldn’t be read: \(SHDesignAlertMessage.mono(board.path, size: SHDesignSheetMetrics.monoSize)) \(board.reason). \(rest)")
        default:
            return Text(failure.message)
        }
    }

    private func again(_ words: ImportAgainWords) -> some View {
        SHDesignSheet(title: words.title, width: SHDesignSheetMetrics.wideWidth) {
            SHDesignAlertMessage(Text("You imported \(SHDesignAlertMessage.strong(words.name))\(words.messageAfter)"))
            SHDesignSheetFacts {
                SHDesignSheetFact("New copy", Text("\(SHDesignAlertMessage.strong(words.copyName))\(words.copyRest)"))
                if let before = words.systemBefore, let system = words.system {
                    SHDesignSheetFact("System", Text("\(before)\(SHDesignAlertMessage.mono(system))\(words.systemAfter ?? "")"))
                }
            }
        } actions: {
            Button("Cancel", action: dismiss)
                .buttonStyle(.shSheet(.quiet))
                .keyboardShortcut(.cancelAction)
            Button("Open the one I have", action: openExisting)
                .buttonStyle(.shSheet(.link))
            Button("Import as a copy", action: resolve)
                .buttonStyle(.shSheet(.pill))
                .keyboardShortcut(.defaultAction)
        }
    }
}

// MARK: The toast

/// The toast over the main column's bottom (UndoToast, DeleteFailedToast): Undo while the host
/// holds the design, or Try again. Nothing in it counts down.
struct DesignToastLayer: View {
    var vm: ShepherdViewModel

    var body: some View {
        ZStack {
            if let toast = vm.designToast {
                let words = toast.words
                SHUndoToast(tone: toast.isFailure ? .failed : .done,
                            message: Text("\(words.before)\(Text(toast.name).fontWeight(.semibold))\(words.after)"),
                            actionTitle: toast.actionTitle,
                            action: { vm.performDesignToast(toast) }, dismiss: { vm.designToast = nil })
                    .padding(.horizontal, SH.Space.xl)
                    .padding(.bottom, SHDesignMetrics.toastBottom)
                    .id(toast.id)
                    .shTransition(.sheet, edge: .bottom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .shAnimation(.sheet, value: vm.designToast?.id)
    }
}

// MARK: The drop

/// Drops on the Designs page (ImportDrop): a ZIP or a folder shows the target and imports as a
/// new design; anything else shows none.
struct DesignsDropDelegate: DropDelegate {
    @Binding var targeted: Bool
    let importProject: (URL) -> Void

    static let types: [UTType] = [.fileURL]

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: Self.types)
    }

    /// The drag says what it carries, or its file URL does once read.
    func dropEntered(info: DropInfo) {
        if info.hasItemsConforming(to: [.zip, .folder]) {
            targeted = true
            return
        }
        guard let provider = info.itemProviders(for: Self.types).first else { return }
        let target = $targeted
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            let accepted = url.map(DesignImportSource.accepts) ?? false
            Task { @MainActor in target.wrappedValue = accepted }
        }
    }

    func dropExited(info: DropInfo) { targeted = false }

    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        guard let provider = info.itemProviders(for: Self.types).first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, DesignImportSource.accepts(url) else { return }
            Task { @MainActor in importProject(url) }
        }
        return true
    }
}
