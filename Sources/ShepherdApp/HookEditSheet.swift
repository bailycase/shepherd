import AppKit
import SwiftUI
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdUI

// Settings › Hooks › Add hook and Edit hook (HooksEdit board): Form or JSON, the event, where it is
// saved, the matcher with the tools it matches, its handlers, a test against a sample event,
// Delete, Cancel and Save. Codex's config.toml opens read-only with Open file.

@MainActor
@Observable
final class HookEditorModel: Identifiable {
    typealias Target = HookSaveTarget
    typealias Handler = HookFormHandler

    enum Mode: Equatable { case add, edit(HookEntry) }
    enum Pane: Hashable { case form, json }

    let id = UUID()
    let mode: Mode
    let targets: [Target]
    let home: String
    /// Codex's config.toml, or an event Shepherd doesn't know: shown, never written.
    let readOnly: Bool
    /// The file it is in, as the page labels it (read-only and JSON's caption).
    let sourceLabel: String

    var event: HookEvent { didSet { testResult = nil } }
    var target: String
    var matcher: String { didSet { matched = HookMatcher.agentTools(matching: matcher) } }
    private(set) var matched: [String] = HookMatcher.agentTools
    var handlers: [Handler]
    var pane: Pane = .form { didSet { if pane != oldValue { switched(from: oldValue) } } }
    var jsonText = ""
    var jsonError: String?
    var testing = false
    var testResult: HookTestResult?
    var problem: String?
    var saving = false
    var confirmingDelete = false
    /// Runs after a save that wrote (a proposal's Edit…: answers the proposal). Cancel never runs it.
    @ObservationIgnored var saved: (@MainActor () -> Void)?

    init(adding draft: HookDraft?, target: Target, targets: [Target], home: String) {
        mode = .add
        self.targets = targets
        self.home = home
        readOnly = false
        sourceLabel = target.label
        event = draft.flatMap { HookEvent(rawValue: $0.event) } ?? .preToolUse
        self.target = target.path
        matcher = draft?.matcher ?? ""
        handlers = [Handler(draft?.handler)]
        matched = HookMatcher.agentTools(matching: matcher)
    }

    init(editing entry: HookEntry, targets: [Target], label: String, home: String) {
        mode = .edit(entry)
        self.targets = targets
        self.home = home
        readOnly = !entry.editable || entry.hookEvent == nil
        sourceLabel = label
        event = entry.hookEvent ?? .preToolUse
        target = entry.file
        matcher = entry.matcher
        handlers = [Handler(original: true, entry.handler)]
        matched = HookMatcher.agentTools(matching: matcher)
    }

    var title: String { if case .edit = mode { readOnly ? "Hook" : "Edit hook" } else { "Add hook" } }
    var entry: HookEntry? { if case .edit(let entry) = mode { entry } else { nil } }
    var targetRoot: String? { targets.first { $0.path == target }?.root }
    var targetLabel: String { targets.first { $0.path == target }?.label ?? target }
    var matcherValid: Bool { HookMatcher.isValid(matcher) }
    /// The first command handler: what Test runs.
    var testable: Handler? { handlers.first(where: \.testable) }

    /// The file's entry for this hook: the event, its group and the handlers.
    func json() -> String { HookForm.json(event: event, matcher: matcher, handlers: handlers) }

    /// Reads the JSON pane back into the form; false (with why) when it isn't one hook entry.
    @discardableResult
    func readJSON() -> Bool {
        do {
            let parsed = try HookForm.parse(jsonText, originals: handlers.map(\.original))
            event = parsed.event
            matcher = parsed.matcher
            handlers = parsed.handlers
            jsonError = nil
            return true
        } catch {
            jsonError = String(describing: error)
        }
        return false
    }

    /// Set while a JSON pane that doesn't read stays open: its text and error are kept.
    @ObservationIgnored private var stayingOnJSON = false

    private func switched(from old: Pane) {
        if pane == .json { if !stayingOnJSON { jsonText = json(); jsonError = nil } }
        else if !readJSON() { stayingOnJSON = true; pane = .json; stayingOnJSON = false }
    }

    func addHandler() { handlers.append(Handler()) }
    func remove(_ id: UUID) { if handlers.count > 1 { handlers.removeAll { $0.id == id } } }

    /// The drafts to write, or why not.
    func drafts() throws -> [HookDraft] {
        if pane == .json, !readJSON() { throw HookEditError(jsonError ?? "Fix the JSON first.") }
        return try HookForm.drafts(event: event, matcher: matcher, handlers: handlers)
    }

    /// Writes the hook off the main thread; true when it did.
    func save(with model: HooksModel) async -> Bool {
        let drafts: [HookDraft]
        do { drafts = try self.drafts() } catch { problem = String(describing: error); return false }
        let entry = self.entry, target = self.target, originals = handlers.map(\.original)
        saving = true
        defer { saving = false }
        let ok = await model.change { _, writer in
            try writer.save(drafts, to: target, replacing: entry, kept: originals.firstIndex(of: true))
        }
        problem = ok ? nil : model.problem
        if ok, let saved { self.saved = nil; saved() }
        return ok
    }

    func delete(with model: HooksModel) async -> Bool {
        guard let entry else { return false }
        let ok = await model.change { _, writer in try writer.delete(entry) }
        problem = ok ? nil : model.problem
        return ok
    }

    /// Runs the first command against a sample event, off the main thread.
    func test() {
        guard let handler = testable, !testing else { return }
        testing = true
        let command = handler.command, event = event, matcher = matcher
        let timeout = Double(handler.timeout.trimmingCharacters(in: .whitespaces))
        let root = targetRoot ?? home
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                HookTester.run(command: command, event: event, matcher: matcher, timeout: timeout, root: root)
            }.value
            testResult = result
            testing = false
        }
    }

    /// The test's line under its outcome ("bash · exit 2 · 41 ms").
    static func testMeta(_ result: HookTestResult, event: HookEvent, matcher: String) -> String {
        HooksPresentation.testMeta(result, event: event, matcher: matcher)
    }
}

/// The sheet itself.
struct HookEditSheet: View {
    @Bindable var editor: HookEditorModel
    let model: HooksModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            SHHairline()
            ScrollView {
                Group {
                    if editor.pane == .form { form } else { jsonPane }
                }
                .padding(.horizontal, SH.Space.xxl)
                .padding(.vertical, SH.Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            SHHairline()
            footer
        }
        .frame(width: AppLayout.hooksSheetWidth, height: AppLayout.hooksSheetHeight)
        .background(Color.sh.bgRaised)
        .disabled(editor.saving)
    }

    private var header: some View {
        HStack(spacing: SH.Space.l) {
            Text(editor.title).shText(.title).foregroundStyle(Color.sh.textPrimary).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            SHSegmentedPicker("Edit as", selection: $editor.pane, options: [(.form, "Form"), (.json, "JSON")], size: .s)
                .fixedSize()
            HookSheetClose(action: close)
        }
        .padding(.leading, SH.Space.xxl)
        .padding(.trailing, SH.Space.l)
        .padding(.vertical, SH.Space.l)
    }

    // MARK: Form

    private var form: some View {
        VStack(alignment: .leading, spacing: SH.Space.xl) {
            if editor.readOnly {
                HookReadOnlyNote(label: editor.sourceLabel) { model.open(editor.target) }
            }
            HStack(alignment: .top, spacing: SH.Space.l) {
                HookField("When", help: editor.event.effect) {
                    Picker("When", selection: $editor.event) {
                        ForEach(HookEvent.allCases, id: \.self) { event in
                            Text("\(event.label) · \(event.rawValue)").tag(event)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                HookField("Saved in", help: editor.targetRoot == nil ? "Hooks on this Mac run in every space."
                                                    : "Space hooks travel with the repo and run in its threads.") {
                    Picker("Saved in", selection: $editor.target) {
                        ForEach(editor.targets, id: \.path) { Text($0.label).tag($0.path) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .disabled(editor.readOnly)
            matcherField
            runs
            if editor.testable != nil || editor.handlers.contains(where: { $0.type == "command" }) { test }
        }
    }

    @ViewBuilder private var matcherField: some View {
        if let hint = editor.event.matcherHint {
            VStack(alignment: .leading, spacing: SH.Space.s) {
                Text("Matcher").font(.sh(.ui, weight: .semibold)).foregroundStyle(Color.sh.textPrimary)
                TextField("Matcher", text: $editor.matcher, prompt: Text(hint).foregroundStyle(Color.sh.textTertiary))
                    .textFieldStyle(.sh(mono: true, error: !editor.matcherValid))
                    .disabled(editor.readOnly)
                    .accessibilityHint(hint)
                if [.preToolUse, .postToolUse, .permissionRequest].contains(editor.event) {
                    HStack(spacing: SH.Space.xs) {
                        Text("Matches").font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary).padding(.trailing, SH.Space.xs)
                        ForEach(HookMatcher.agentTools, id: \.self) { tool in
                            HookToolChip(name: tool, hit: editor.matched.contains(tool))
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(editor.matched.isEmpty ? "Matches no built-in tool" : "Matches " + editor.matched.joined(separator: ", "))
                }
                HookHelp(!editor.matcherValid ? "This isn’t a regular expression Shepherd can read."
                         : [.preToolUse, .postToolUse, .permissionRequest].contains(editor.event)
                         ? "A regular expression on the tool name. Claude Code’s names work too: Edit|Write matches the agent’s edit and write. Leave it empty to match every tool."
                         : "A regular expression on the \(hint.lowercased()). Leave it empty to match every time.", failed: !editor.matcherValid)
            }
        } else {
            VStack(alignment: .leading, spacing: SH.Space.s) {
                Text("Matcher").font(.sh(.ui, weight: .semibold)).foregroundStyle(Color.sh.textPrimary)
                HookHelp("\(editor.event.rawValue) takes no matcher: its hooks run every time.")
            }
        }
    }

    private var runs: some View {
        VStack(alignment: .leading, spacing: SH.Space.s) {
            Text("Runs").font(.sh(.ui, weight: .semibold)).foregroundStyle(Color.sh.textPrimary)
            ForEach($editor.handlers) { $handler in
                HookHandlerCard(handler: $handler, removable: editor.handlers.count > 1 && !editor.readOnly) {
                    editor.remove(handler.id)
                }
                .disabled(editor.readOnly)
            }
            if !editor.readOnly {
                Button("+ Add another handler") { editor.addHandler() }.buttonStyle(.shLink)
            }
            HookHelp("Gets the event as JSON on stdin. Exit 2, or print {\"decision\": \"block\", \"reason\": \"…\"}, to stop the call; the reason goes to the agent. Any other failure or a timeout lets the call go ahead.")
        }
    }

    private var test: some View {
        VStack(alignment: .leading, spacing: SH.Space.s) {
            HStack {
                Text("Test").font(.sh(.ui, weight: .semibold)).foregroundStyle(Color.sh.textPrimary)
                Spacer(minLength: 0)
                Button { editor.test() } label: {
                    Label(editor.testing ? "Running…" : "Run with a sample event", systemImage: "play.fill")
                }
                .buttonStyle(.sh(.secondary, size: .s))
                .disabled(editor.testable == nil || editor.testing)
                .help(editor.testable == nil ? "Enter a command to test it" : "Runs the command once against a sample \(editor.event.rawValue) event")
            }
            if let result = editor.testResult {
                HookTestResultCard(outcome: result.outcome, meta: HookEditorModel.testMeta(result, event: editor.event, matcher: editor.matcher))
            }
        }
    }

    // MARK: JSON

    private var jsonPane: some View {
        VStack(alignment: .leading, spacing: SH.Space.m) {
            HookHelp("This hook’s entry in \(editor.targetLabel.replacingOccurrences(of: " · ", with: "/")). The same shape works in .claude/settings.json and .codex/hooks.json.")
            TextEditor(text: $editor.jsonText)
                .font(.sh(.code))
                .scrollContentBackground(.hidden)
                .foregroundStyle(Color.sh.textSecondary)
                .padding(SH.Space.l)
                .frame(minHeight: AppLayout.hooksJSONHeight)
                .background(Color.sh.bgBase, in: RoundedRectangle(cornerRadius: SH.Radius.m))
                .shBorder(editor.jsonError == nil ? Color.sh.lineSubtle : Color.sh.failed, radius: SH.Radius.m)
                .disabled(editor.readOnly)
                .accessibilityLabel("Hook entry as JSON")
            if let error = editor.jsonError { HookHelp(error, failed: true) }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: SH.Space.m) {
            if editor.entry != nil, !editor.readOnly {
                Button(editor.confirmingDelete ? "Delete this hook" : "Delete") {
                    if editor.confirmingDelete {
                        Task { if await editor.delete(with: model) { close() } }
                    } else {
                        editor.confirmingDelete = true
                    }
                }
                .buttonStyle(.sh(editor.confirmingDelete ? .dangerFill : .danger, size: .m))
            }
            if let problem = editor.problem {
                Text(problem).font(.sh(.caption)).foregroundStyle(Color.sh.failed).lineLimit(2).textSelection(.enabled)
            }
            Spacer(minLength: SH.Space.l)
            Button(editor.readOnly ? "Close" : "Cancel", action: close)
                .buttonStyle(.sh(.secondary, size: .m))
                .keyboardShortcut(.cancelAction)
            if editor.readOnly {
                Button("Open file") { model.open(editor.target) }.buttonStyle(.sh(.primary, size: .m))
            } else {
                Button("Save") { Task { if await editor.save(with: model) { close() } } }
                    .buttonStyle(.sh(.primary, size: .m))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, SH.Space.xxl)
        .padding(.vertical, SH.Space.l)
    }
}

/// A labeled field with its help line under it.
struct HookField<Control: View>: View {
    let label: String
    let help: String?
    @ViewBuilder var control: Control

    init(_ label: String, help: String? = nil, @ViewBuilder control: () -> Control) {
        self.label = label; self.help = help; self.control = control()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.s) {
            Text(label).font(.sh(.ui, weight: .semibold)).foregroundStyle(Color.sh.textPrimary)
            control
            if let help { HookHelp(help) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The boards' help line: caption on 1.45 in `textTertiary` (`failed` when it says what's wrong).
struct HookHelp: View {
    let text: String
    var failed = false
    init(_ text: String, failed: Bool = false) { self.text = text; self.failed = failed }

    var body: some View {
        Text(text).font(.sh(.caption)).foregroundStyle(failed ? Color.sh.failed : Color.sh.textTertiary)
            .lineSpacing(SH.Space.xxs).fixedSize(horizontal: false, vertical: true)
    }
}

/// A built-in tool in the matcher's Matches line: lit in `running` when the matcher matches it.
struct HookToolChip: View {
    let name: String
    let hit: Bool

    var body: some View {
        Text(name).font(.sh(.micro)).foregroundStyle(hit ? Color.sh.textPrimary : Color.sh.textTertiary)
            .padding(.horizontal, SH.Space.s).frame(height: AppLayout.hooksChipHeight)
            .background(hit ? Color.sh.runningTint : Color.clear, in: RoundedRectangle(cornerRadius: SH.Radius.xs))
            .shBorder(hit ? Color.sh.running : Color.sh.lineSubtle, radius: SH.Radius.xs)
    }
}

/// The sheets' close button: a bordered 26pt circle.
struct HookSheetClose: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: "xmark").font(.sh(.micro)) }
            .buttonStyle(.shIcon(bordered: true, size: AppLayout.hooksCloseSize))
            .accessibilityLabel("Close")
    }
}

/// One handler's card: Command or MCP tool, what it runs, its time limit and status message.
struct HookHandlerCard: View {
    @Binding var handler: HookEditorModel.Handler
    let removable: Bool
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.m) {
            HStack(spacing: SH.Space.m) {
                if handler.type == "command" || handler.type == "mcp_tool" {
                    SHSegmentedPicker("Handler type", selection: $handler.type, options: [("command", "Command"), ("mcp_tool", "MCP tool")], size: .s)
                        .fixedSize()
                } else {
                    Text("\(handler.type) handler · listed, never run").font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                }
                Spacer(minLength: 0)
                if removable {
                    Button("Remove", action: remove).buttonStyle(.shLink(color: Color.sh.textTertiary))
                }
            }
            if handler.type == "mcp_tool" {
                HStack(spacing: SH.Space.l) {
                    HookSubField("Server") { TextField("Server", text: $handler.server).textFieldStyle(.sh(mono: true)) }
                    HookSubField("Tool") { TextField("Tool", text: $handler.tool).textFieldStyle(.sh(mono: true)) }
                }
                HookSubField("Input (JSON, ${field.path} placeholders)") {
                    TextField("Input", text: $handler.input, axis: .vertical).textFieldStyle(.sh(mono: true)).lineLimit(2...6)
                }
            } else if handler.type == "command" {
                HookSubField("Command") {
                    TextField("Command", text: $handler.command, axis: .vertical)
                        .textFieldStyle(.sh(mono: true)).lineLimit(2...6)
                }
            }
            HStack(alignment: .top, spacing: SH.Space.l) {
                HookSubField("Time limit") {
                    HStack(spacing: SH.Space.s) {
                        TextField("Time limit", text: $handler.timeout, prompt: Text("60").foregroundStyle(Color.sh.textTertiary))
                            .textFieldStyle(.sh(mono: true)).frame(width: AppLayout.hooksTimeoutWidth)
                        Text("seconds").font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                    }
                }
                .frame(width: AppLayout.hooksTimeoutColumn, alignment: .leading)
                HookSubField("Status while it runs") {
                    TextField("Status while it runs", text: $handler.statusMessage, prompt: Text("Shown in the thread while it runs").foregroundStyle(Color.sh.textTertiary))
                        .textFieldStyle(.sh)
                }
            }
        }
        .padding(SH.Space.l)
        .background(Color.sh.bgSunken, in: RoundedRectangle(cornerRadius: SH.Radius.m))
        .shBorder(Color.sh.lineSubtle, radius: SH.Radius.m)
    }
}

struct HookSubField<Control: View>: View {
    let label: String
    @ViewBuilder var control: Control
    init(_ label: String, @ViewBuilder control: () -> Control) { self.label = label; self.control = control() }

    var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.s) {
            Text(label).font(.sh(.caption)).foregroundStyle(Color.sh.textSecondary)
            control
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The test's result: the outcome in its color and glyph, the run's meta under it.
struct HookTestResultCard: View {
    let outcome: HookOutcome
    let meta: String

    var body: some View {
        let (glyph, color) = Self.look(outcome)
        VStack(alignment: .leading, spacing: SH.Space.s) {
            Label { Text(outcome.summary).lineLimit(3) } icon: { Image(systemName: glyph) }
                .font(.sh(.ui)).foregroundStyle(color)
            Text(meta).font(.sh(.mono)).foregroundStyle(Color.sh.textTertiary)
        }
        .padding(.horizontal, SH.Space.l).padding(.vertical, SH.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.sh.bgSunken, in: RoundedRectangle(cornerRadius: SH.Radius.m))
        .shBorder(Color.sh.lineSubtle, radius: SH.Radius.m)
        .accessibilityElement(children: .combine)
    }

    @MainActor static func look(_ outcome: HookOutcome) -> (String, Color) {
        switch outcome {
        case .allowed: ("checkmark", Color.sh.done)
        case .blocked: ("xmark", Color.sh.failed)
        case .ask: ("questionmark.circle", Color.sh.lanternText)
        case .context: ("doc.plaintext", Color.sh.running)
        case .failed, .timedOut: ("exclamationmark.triangle", Color.sh.lanternText)
        }
    }
}

/// A file Shepherd reads but never writes (Codex's config.toml).
struct HookReadOnlyNote: View {
    let label: String
    let open: () -> Void

    var body: some View {
        HStack(spacing: SH.Space.m) {
            Image(systemName: "lock").foregroundStyle(Color.sh.textTertiary).accessibilityHidden(true)
            Text("This hook is in \(label). Shepherd reads that file but doesn’t write it; edit it in an editor.")
                .font(.sh(.ui)).foregroundStyle(Color.sh.textSecondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Open file", action: open).buttonStyle(.sh(.secondary, size: .s))
        }
        .padding(SH.Space.m)
        .background(Color.sh.bgSunken, in: RoundedRectangle(cornerRadius: SH.Radius.m))
        .shBorder(Color.sh.lineSubtle, radius: SH.Radius.m)
    }
}
