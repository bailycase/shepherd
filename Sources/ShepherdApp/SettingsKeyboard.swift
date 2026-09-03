import SwiftUI
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

    private static let groups: [(title: String, actions: [ShortcutAction])] = [
        ("Agents", [.newAgent, .newAgentOptions, .newSpace, .newShell, .shellDigits, .renameAgent, .nextAgent, .previousAgent, .commandPalette]),
        ("Panes", [.splitVertical, .splitHorizontal, .closePane, .focusNextPane, .focusPreviousPane]),
    ]

    var body: some View {
        ForEach(Self.groups, id: \.title) { group in
            SettingsGroup(title: group.title) {
                ForEach(Array(group.actions.enumerated()), id: \.element) { index, action in
                    SettingsRow(title: action.title, isFirst: index == 0) {
                        HStack(spacing: 6) {
                            if !keys.isDefault(action) {
                                Button("Reset") {
                                    keys.reset(action)
                                    vm.rebuildSurfaces()
                                    errorText = nil
                                }
                                .buttonStyle(.plain)
                                .font(Fonts.mono(10.5))
                                .foregroundStyle(Tokens.textTertiary)
                            }
                            ShortcutRecorder(
                                action: action,
                                isRecording: recording == action,
                                chordText: keys.display(action)
                            ) {
                                errorText = nil
                                recording = recording == action ? nil : action
                            } onChord: { chord in
                                recording = nil
                                if let error = keys.assign(chord, to: action) {
                                    errorText = "\(chord.display): \(error)"
                                } else {
                                    errorText = nil
                                    // Custom chords must fall through focused
                                    // terminals — rebuild surfaces so ghostty
                                    // picks up the new unbind list.
                                    vm.rebuildSurfaces()
                                }
                            }
                        }
                    }
                }
            }
        }

        if let errorText {
            Text(errorText)
                .font(Fonts.mono(10.5))
                .foregroundStyle(Tokens.statusBlocked)
        }

        SettingsGroup(title: "Fixed") {
            SettingsRow(title: "Select Agent 1–9", subtitle: "Sidebar tree order; hold ⌘ to see the numbers.", isFirst: true) {
                Keycap(text: "⌘1–9")
            }
            SettingsRow(title: "Settings") {
                Keycap(text: "⌘,")
            }
            SettingsRow(title: "Confirm / Cancel in Sheets") {
                Keycap(text: "⏎ / ⎋")
            }
        }

        HStack {
            Spacer()
            Button("Reset All Shortcuts") {
                keys.resetAll()
                vm.rebuildSurfaces()
                errorText = nil
            }
            .disabled(keys.overrides.isEmpty)
        }
        SettingsNote(text: "shortcuts must include ⌘ · changes apply immediately, everywhere a hint is shown")
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
            Text(isRecording ? "press keys…" : chordText)
                .font(Fonts.mono(10.5))
                .foregroundStyle(isRecording ? Tokens.focusAccent : Tokens.textSecondary)
                .padding(.vertical, 2)
                .padding(.horizontal, 6)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(isRecording ? Tokens.focusAccent.opacity(0.6) : Tokens.keycapBorder, lineWidth: 1)
                )
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

private struct Keycap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Fonts.mono(10.5))
            .foregroundStyle(Tokens.textSecondary)
            .padding(.vertical, 2)
            .padding(.horizontal, 6)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Tokens.keycapBorder, lineWidth: 1)
            )
    }
}

