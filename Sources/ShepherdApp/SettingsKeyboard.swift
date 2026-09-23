import SwiftUI
import ShepherdDesign
import AppKit

// MARK: Keyboard

/// Rebindable shortcuts, grouped as in the menu bar. A row's keycap is a
/// recorder: click, press the new chord, ⎋ cancels. Fixed chords are listed
/// separately and cannot be recorded over.
struct KeyboardSettings: View {
    var vm: ShepherdViewModel
    @ObservedObject private var keys = KeybindingsStore.shared
    /// The action currently recording, if any — one recorder at a time.
    @State private var recording: ShortcutAction?
    @State private var errorText: String?
    @State private var errorAction: ShortcutAction?

    private static let groups: [(title: String, actions: [ShortcutAction])] = [
        ("Agents", [.newAgent, .newAgentOptions, .newSpace, .renameAgent, .nextAgent, .previousAgent, .deleteAgent, .commandPalette]),
        ("Thread", [.stopAgent, .modelPicker, .previousTurn, .nextTurn, .inspectSubagent]),
        ("Window", [.toggleSidebar, .toggleRightPane]),
        ("Panes", [.splitVertical, .splitHorizontal, .closePane, .focusNextPane, .focusPreviousPane]),
    ]

    var body: some View {
        SettingsPage(title: "Keyboard", explanation: "Click a shortcut to record a new one. Shortcuts must include ⌘.") {
            ForEach(Self.groups, id: \.title) { group in
                SettingsGroup(title: group.title) {
                    ForEach(group.actions, id: \.self) { action in
                        SettingsRow(title: action.sentenceTitle, problem: errorAction == action ? errorText : nil) {
                            HStack(spacing: 8) {
                                if !keys.isDefault(action) {
                                    Button("Reset") {
                                        keys.reset(action)
                                        vm.rebuildSurfaces()
                                        clearError()
                                    }
                                    .buttonStyle(LinkButtonStyle(color: Tokens.accentText, font: Fonts.caption))
                                }
                                ShortcutRecorder(action: action, isRecording: recording == action, chordText: keys.display(action)) {
                                    clearError()
                                    recording = recording == action ? nil : action
                                } onChord: { chord in
                                    recording = nil
                                    if let error = keys.assign(chord, to: action) {
                                        errorAction = action
                                        errorText = "\(chord.display): \(error)"
                                    } else {
                                        clearError()
                                        // Custom chords must fall through focused terminals — rebuild
                                        // surfaces so ghostty picks up the new unbind list.
                                        vm.rebuildSurfaces()
                                    }
                                }
                            }
                        }
                    }
                }
            }

            SettingsGroup(title: "Fixed", footnote: "Changes apply immediately, everywhere a shortcut is shown.") {
                SettingsRow(title: "Select agent 1–9", subtitle: "Sidebar order; hold ⌘ to see the numbers.") { Keycaps(["⌘", "1–9"]) }
                SettingsRow(title: "Settings") { Keycaps(chord: "⌘,") }
                SettingsRow(title: "Confirm or cancel in sheets") { Keycaps(["⏎", "⎋"]) }
                SettingsRow(title: "Reset all shortcuts") {
                    Button("Reset all") {
                        keys.resetAll()
                        vm.rebuildSurfaces()
                        clearError()
                    }
                    .buttonStyle(ShepherdButtonStyle(.destructive, size: .small))
                    .disabled(keys.overrides.isEmpty)
                }
            }
        }
    }

    private func clearError() {
        errorText = nil
        errorAction = nil
    }
}

/// The clickable keycap. While recording it swallows key events through a
/// local monitor: ⎋ cancels, anything else becomes the proposed chord.
private struct ShortcutRecorder: View {
    let action: ShortcutAction
    let isRecording: Bool
    let chordText: String
    let onToggle: () -> Void
    let onChord: (KeyChord) -> Void
    @State private var monitor: Any?

    var body: some View {
        Button(action: onToggle) {
            Group {
                if isRecording {
                    Text("Press keys…")
                        .font(Fonts.caption)
                        .foregroundStyle(Tokens.accentText)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(Tokens.accentBg, in: RoundedRectangle(cornerRadius: Radius.xs))
                        .overlay { RoundedRectangle(cornerRadius: Radius.xs).strokeBorder(Tokens.accent, lineWidth: 1) }
                } else {
                    Keycaps(chord: chordText)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isRecording ? "Press the new shortcut — ⎋ cancels" : "Click, then press the new shortcut")
        .onChange(of: isRecording, initial: true) { _, now in
            now ? startMonitor() : stopMonitor()
        }
        .onDisappear { stopMonitor() }
    }

    private func startMonitor() {
        guard monitor == nil else { return }
        KeybindingsStore.shared.isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                if event.keyCode == 53 { // ⎋
                    onToggle()
                } else if let chord = KeyChord(event: event) {
                    onChord(chord)
                } else {
                    NSSound.beep()
                }
            }
            return nil // recording swallows the event either way
        }
    }

    private func stopMonitor() {
        KeybindingsStore.shared.isRecording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
