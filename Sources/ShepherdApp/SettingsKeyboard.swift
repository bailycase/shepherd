import SwiftUI
import ShepherdUI
import AppKit

// MARK: Keyboard

/// Rebindable shortcuts, grouped as in the menu bar. A row's keycap is a
/// recorder: click, press the new chord, ⎋ cancels. Fixed chords are listed
/// separately and cannot be recorded over.
struct KeyboardSettings: View {
    var vm: ShepherdViewModel
    private var keys: KeybindingsStore { .shared }
    /// The action currently recording, if any — one recorder at a time.
    @State private var recording: ShortcutAction?
    @State private var errorText: String?
    @State private var errorAction: ShortcutAction?

    private static let groups: [(title: String, actions: [ShortcutAction])] = [
        ("Agents", [.newAgent, .newAgentOptions, .newSpace, .renameAgent, .nextAgent, .previousAgent, .deleteAgent, .commandPalette]),
        ("Thread", [.stopAgent, .modelPicker, .previousTurn, .nextTurn, .inspectSubagent]),
        ("Window", [.toggleSidebar, .toggleRightPane]),
        ("Panes", [.splitVertical, .splitHorizontal, .closePane, .focusNextPane, .focusPreviousPane,
                   .toggleTerminal, .maximizeTerminal]),
    ]

    var body: some View {
        SettingsPage(title: "Keyboard", explanation: "Click a shortcut to record a new one. Shortcuts must include ⌘.") {
            ForEach(Self.groups, id: \.title) { group in
                SettingsGroup(title: group.title) {
                    ForEach(group.actions, id: \.self) { action in
                        shortcutRow(action, title: action.sentenceTitle)
                    }
                }
                if group.title == "Thread" { whileWorking }
            }

            SettingsGroup(title: "Fixed", footnote: "Changes apply immediately, everywhere a shortcut is shown.") {
                SettingsRow(title: "Select agent 1–9", subtitle: "Sidebar order; hold ⌘ to see the numbers.") { NWKeycap(keys: ["⌘", "1–9"]) }
                SettingsRow(title: "Settings") { NWKeycap("⌘,") }
                SettingsRow(title: "Confirm / cancel in sheets") { NWKeycap(keys: ["⏎", "esc"]) }
            }

            // Under the last group, trailing: disabled while nothing is changed.
            HStack {
                Spacer(minLength: 0)
                Button("Reset all shortcuts") {
                    keys.resetAll()
                    vm.rebuildSurfaces()
                    clearError()
                }
                .buttonStyle(.nw(.secondary, size: .s))
                .disabled(keys.overrides.isEmpty)
            }
        }
        // A rejected chord's reason discloses under its row.
        .nwAnimation(.disclosure, value: errorText)
    }

    /// The keys for sending while pi works and for the queue, as the Queue & steer boards'
    /// Keyboard card lists them: ↩ and the alternate send say what they do under the Return
    /// setting, and only the alternate send can be rebound.
    private var whileWorking: some View {
        let setting = AppSettings.shared.returnWhileWorking
        return SettingsGroup(title: "While the agent is working") {
            ForEach(WhileWorkingKey.all) { key in
                switch key {
                case .send:
                    SettingsRow(title: key.title(setting)) { NWKeycap(keys.sendDisplay) }
                case .alternateSend:
                    shortcutRow(.alternateSend, title: key.title(setting))
                case .fixed(let chord):
                    SettingsRow(title: key.title(setting)) { NWKeycap(keys: chord.keys) }
                case .steerFocused:
                    SettingsRow(title: key.title(setting)) { NWKeycap(keys.display(.alternateSend)) }
                }
            }
        }
    }

    /// A rebindable shortcut: its keycap records a new chord, and a changed one offers Reset.
    private func shortcutRow(_ action: ShortcutAction, title: String) -> some View {
        SettingsRow(title: title, problem: errorAction == action ? errorText : nil) {
            HStack(spacing: NW.Space.xs) {
                if !keys.isDefault(action) {
                    Button("Reset") {
                        keys.reset(action)
                        vm.rebuildSurfaces()
                        clearError()
                    }
                    .buttonStyle(.nwLink)
                    .accessibilityLabel("Reset \(title)")
                    .nwTransition(.disclosure)
                }
                ShortcutRecorder(title: title, isRecording: recording == action, chordText: keys.display(action)) {
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
            // The recorder swaps its keycap for "Press keys…"; a changed chord
            // grows its Reset link. The rest of the row moves along.
            .nwComponentAnimation(.hover, value: recording == action)
            .nwComponentAnimation(.disclosure, value: keys.isDefault(action))
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
    let title: String
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
                        .font(.nw(.caption))
                        .foregroundStyle(Color.nw.running)
                        .padding(.horizontal, NW.Space.m)
                        .frame(minHeight: NW.Height.controlS - NW.Space.xxs)
                        .background(Color.nw.runningTint, in: RoundedRectangle(cornerRadius: NW.Radius.xs))
                        .nwBorder(Color.nw.running, radius: NW.Radius.xs)
                } else {
                    NWKeycap(chordText)
                }
            }
            .contentShape(Rectangle())
            .nwFocusRing(radius: NW.Radius.xs)
        }
        .buttonStyle(.plain)
        .help(isRecording ? "Press the new shortcut — ⎋ cancels" : "Click, then press the new shortcut")
        .accessibilityLabel("\(title) shortcut")
        .accessibilityValue(isRecording ? "Recording" : chordText)
        .accessibilityHint(isRecording ? "Press the new shortcut, or Escape to cancel" : "Records a new shortcut")
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
