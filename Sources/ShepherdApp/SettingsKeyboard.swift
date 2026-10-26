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
        ("Thread", [.stopAgent, .modelPicker, .cycleThinkingLevel, .previousTurn, .nextTurn, .inspectSubagent]),
        ("Window", [.toggleSidebar, .toggleRightPane]),
        ("Terminal", [.newTerminal, .closeTerminal, .nextTerminal, .previousTerminal,
                      .toggleTerminal, .maximizeTerminal]),
        ("Browser", [.focusAddressBar, .selectElement, .browserNewTab]),
        ("Designs", [.importDesign, .implementInThread, .copyDesignReference]),
    ]

    var body: some View {
        SettingsPage(title: "Keyboard", explanation: "Click a shortcut to record a new one. Shortcuts must include ⌘, except ⇧⇥ for cycling thinking levels.") {
            ForEach(Self.groups, id: \.title) { group in
                SettingsGroup(title: group.title) {
                    ForEach(group.actions, id: \.self) { action in
                        shortcutRow(action, title: action.sentenceTitle)
                    }
                }
                if group.title == "Thread" { whileWorking }
            }

            SettingsGroup(title: "Fixed", footnote: "Changes apply immediately, everywhere a shortcut is shown.") {
                SettingsRow(title: "Select agent 1–9", subtitle: "The first nine in Recents; hold ⌘ to see the numbers.") { SHKeycap(keys: ["⌘", "1–9"]) }
                ForEach(SidePaneTab.allCases, id: \.self) { tab in
                    SettingsRow(title: "Side pane: \(tab.title)") { SHKeycap(tab.shortcutDisplay) }
                }
                SettingsRow(title: "Settings") { SHKeycap("⌘,") }
                SettingsRow(title: "Confirm / cancel in sheets") { SHKeycap(keys: ["⏎", "esc"]) }
            }

            // Under the last group, trailing: disabled while nothing is changed.
            HStack {
                Spacer(minLength: 0)
                Button("Reset all shortcuts") {
                    keys.resetAll()
                    vm.rebuildSurfaces()
                    clearError()
                }
                .buttonStyle(.sh(.secondary, size: .s))
                .disabled(keys.overrides.isEmpty)
            }
        }
        // A rejected chord's reason discloses under its row.
        .shAnimation(.disclosure, value: errorText)
    }

    /// The keys for sending while pi works and for the queue, as the Queue & steer boards'
    /// Keyboard card lists them: ↩ queues, the alternate send steers now, and only the alternate
    /// send can be rebound.
    private var whileWorking: some View {
        SettingsGroup(title: "While the agent is working") {
            ForEach(WhileWorkingKey.all) { key in
                switch key {
                case .send:
                    SettingsRow(title: key.title) { SHKeycap(keys.sendDisplay) }
                case .alternateSend:
                    shortcutRow(.alternateSend, title: key.title)
                case .fixed(let chord):
                    SettingsRow(title: key.title) { SHKeycap(keys: chord.keys) }
                case .steerFocused:
                    SettingsRow(title: key.title) { SHKeycap(keys.display(.alternateSend)) }
                }
            }
        }
    }

    /// A rebindable shortcut: its keycap records a new chord, and a changed one offers Reset.
    private func shortcutRow(_ action: ShortcutAction, title: String) -> some View {
        SettingsRow(title: title, problem: errorAction == action ? errorText : nil) {
            HStack(spacing: SH.Space.xs) {
                if !keys.isDefault(action) {
                    Button {
                        if let error = keys.reset(action) {
                            errorAction = action
                            errorText = "\(action.defaultChord.display): \(error)"
                        } else {
                            vm.rebuildSurfaces()
                            clearError()
                        }
                    } label: {
                        Text("Reset")
                            .frame(minHeight: SH.Height.controlS)
                    }
                    // SettingsKeyboard: Geist 12, 6pt either side, just before the caps.
                    .buttonStyle(.shLink(font: .shSans(AppLayout.shortcutResetSize)))
                    .padding(.horizontal, SH.Space.s)
                    .accessibilityLabel("Reset \(title)")
                    .shTransition(.disclosure)
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
            .shComponentAnimation(.hover, value: recording == action)
            .shComponentAnimation(.disclosure, value: keys.isDefault(action))
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
                        .font(.sh(.caption))
                        .foregroundStyle(Color.sh.running)
                        .padding(.horizontal, SH.Space.m)
                        .frame(minHeight: SHSettingsControlMetrics.keycapHeight)
                        .background(Color.sh.runningTint, in: RoundedRectangle(cornerRadius: SH.Radius.xs))
                        .shBorder(Color.sh.running, radius: SH.Radius.xs)
                } else {
                    SHKeycap(chordText)
                }
            }
            .frame(minHeight: SH.Height.controlS)
            .contentShape(Rectangle())
            .shFocusRing(radius: SH.Radius.xs)
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
