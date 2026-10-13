import SwiftUI

/// One ShepherdUI component the design system page draws live (DesignSystemComponents): its type
/// name, its group, and a specimen built from the real component.
public struct NWComponentCatalogEntry: Identifiable {
    /// The component's type name ("NWStatusPill"): what a person greps for.
    public let id: String
    public let group: String
    public let specimen: @MainActor () -> AnyView
}

/// The components the Design system page lists, one entry per component the app's Component Gallery
/// (View ▸ Component Gallery, Debug builds) draws: buttons, selection, inputs, agent state, the settings
/// card, feedback and the palette. The page's count, its groups and its specimens all come from this list.
///
/// It is not every `NW*` view. The rest are drawn by a domain's own `#Preview` from that domain's data (a
/// thread, a diff, a design), which a specimen here would have to invent; add one when a component can be
/// drawn from literals. The count is this list's, never a claim about the library.
public enum NWComponentCatalog {
    public static let allGroups = "All groups"

    @MainActor public static var entries: [NWComponentCatalogEntry] {
        [
            // Actions
            entry("NWButtonStyle", "Actions") {
                HStack(spacing: NW.Space.m) {
                    Button("Launch") {}.buttonStyle(.nw(.primary))
                    Button("Review") {}.buttonStyle(.nw(.secondary))
                    Button("Cancel") {}.buttonStyle(.nw(.ghost))
                    Button("Stop") {}.buttonStyle(.nw(.danger))
                    Button("Delete") {}.buttonStyle(.nw(.dangerFill))
                    Button("Disabled") {}.buttonStyle(.nw(.secondary)).disabled(true)
                }
            },
            entry("NWLinkButtonStyle", "Actions") { Button("Show all") {}.buttonStyle(.nwLink) },
            entry("NWButtonTitle", "Actions") { Button {} label: { NWButtonTitle("Land", chord: "⌘↩") }.buttonStyle(.nw(.primary)) },
            entry("NWIconButtonStyle", "Actions") {
                HStack(spacing: NW.Space.m) {
                    Button {} label: { Image(systemName: "sidebar.left") }.buttonStyle(.nwIcon).accessibilityLabel("Sidebar")
                    Button {} label: { Image(systemName: "ellipsis") }.buttonStyle(.nwIcon(bordered: true)).accessibilityLabel("Options")
                }
            },
            entry("NWComposerActionButton", "Actions") {
                HStack(spacing: NW.Space.m) {
                    NWComposerActionButton(.send) {}
                    NWComposerActionButton(.send, enabled: false) {}
                    NWComposerActionButton(.stop) {}
                }
            },
            entry("NWComposerChipStyle", "Actions") {
                HStack(spacing: NW.Space.s) {
                    Button {} label: { Text("commands").font(.nw(.mono)) }.buttonStyle(.nwComposerChip())
                    Button {} label: { HStack(spacing: NW.Space.s) { Text("claude-opus").font(.nw(.mono)); NWChipChevron() } }
                        .buttonStyle(.nwComposerChip(active: true))
                }
            },
            entry("NWAttachmentChip", "Actions") { NWAttachmentChip("screenshot.png") {} },
            entry("NWKeycap", "Actions") { NWKeycap("⇧⌘N") },

            // Status
            entry("NWStatusPill", "Status") {
                HStack(spacing: NW.Space.m) { ForEach(AgentState.allCases, id: \.self) { NWStatusPill($0) } }
            },
            entry("NWStatusDot", "Status") {
                HStack(spacing: NW.Space.l) { ForEach(AgentState.allCases, id: \.self) { NWStatusDot($0) } }
            },
            entry("NWStateGlyph", "Status") {
                HStack(spacing: NW.Space.l) { ForEach(AgentState.allCases, id: \.self) { NWStateGlyph($0) } }
            },
            entry("NWBranchGlyph", "Status") {
                HStack(spacing: NW.Space.l) { ForEach(AgentState.allCases, id: \.self) { NWBranchGlyph($0) } }
            },
            entry("NWBarProgressStyle", "Status") { ProgressView(value: 0.62).progressViewStyle(.nwBar).frame(width: 160) },
            entry("NWStepStrip", "Status") { NWStepStrip([.done, .done, .running, .attention, .failed, nil]).frame(width: 160) },
            entry("NWSpinnerStyle", "Status") { ProgressView().progressViewStyle(.nwSpinner) },
            entry("NWSparkline", "Status") { NWSparkline([2, 4, 3, 7, 5, 9, 4, 6, 5, 8]) },
            entry("NWCountBadge", "Status") {
                HStack(spacing: NW.Space.m) {
                    NWCountBadge(19)
                    NWCountBadge(3, tone: .attention)
                    NWCountBadge(1, tone: .failed)
                }
            },
            entry("NWTag", "Status") {
                HStack(spacing: NW.Space.m) {
                    NWTag("prompt")
                    NWTag("claude-sonnet", mono: true)
                }
            },
            entry("NWDiffStat", "Status") { NWDiffStat(added: 58, removed: 41) },
            entry("NWInlineCode", "Status") { NWInlineCode("Color.nw.lantern") },
            entry("NWWordmark", "Status") { NWWordmark(size: .large) },

            // Fields
            entry("NWTextFieldStyle", "Fields") {
                VStack(alignment: .leading, spacing: NW.Space.m) {
                    TextField("Name this agent", text: .constant("")).textFieldStyle(.nw)
                    TextField("Socket", text: .constant("shepherd.sock")).textFieldStyle(.nw(mono: true, error: true))
                        .nwFieldMessage("Socket path already in use")
                }
                .frame(width: 220)
            },
            entry("NWSearchField", "Fields") { NWSearchField("Search settings", text: .constant(""), shortcut: "⌘F").frame(width: 220) },
            entry("NWPopupMenu", "Fields") { NWPopupMenu("claude-sonnet", mono: true) {} },
            entry("NWStepper", "Fields") { NWStepper("Concurrency", value: .constant(4), in: 1...16) },
            entry("NWValueSlider", "Fields") {
                NWValueSlider("Density", value: .constant(0.6), in: 0...1, step: 0.05, neutral: 0.5) { "\(Int($0 * 100))%" }
            },

            // Selection
            entry("NWSegmentedPicker", "Selection") {
                NWSegmentedPicker("Mode", selection: .constant("light"),
                                  options: [("system", "System"), ("light", "Light"), ("dark", "Dark")])
            },
            entry("NWRadioGroup", "Selection") {
                NWRadioGroup("Update channel", selection: .constant("beta"), options: [("stable", "Stable"), ("beta", "Beta")])
            },
            entry("NWSwitchToggleStyle", "Selection") {
                HStack(spacing: NW.Space.l) {
                    Toggle("On", isOn: .constant(true)).labelsHidden().toggleStyle(.nwSwitch)
                    Toggle("Off", isOn: .constant(false)).labelsHidden().toggleStyle(.nwSwitch)
                }
            },
            entry("NWCheckboxToggleStyle", "Selection") { Toggle("Done when", isOn: .constant(true)).toggleStyle(.nwCheckbox) },

            // Containers and feedback
            entry("NWSectionHeader", "Containers") { NWSectionHeader("Agent state") },
            entry("NWGroupCard", "Containers") {
                NWGroupCard {
                    NWCardRow("Auto-name agents", description: "Title each agent from its opening prompt.") {
                        Toggle("Auto-name agents", isOn: .constant(true)).toggleStyle(.nwSwitch).labelsHidden()
                    }
                    NWCardRow("Listener", description: "Serve this Mac to other Shepherds.", problem: "bind failed: Address already in use") {
                        Toggle("Listener", isOn: .constant(false)).toggleStyle(.nwSwitch).labelsHidden()
                    }
                }
                .frame(width: 420)
            },
            entry("NWBanner", "Containers") {
                VStack(alignment: .leading, spacing: NW.Space.m) {
                    NWBanner(.failed, title: "Lost connection to the agent process.") {
                        Button("Reconnect") {}.buttonStyle(.nw(.secondary, size: .s))
                    }
                    NWBanner(.attention, title: "ios asks: keep MobileTokens as an alias?", message: "Migrating touches 31 call sites.")
                }
                .frame(width: 420)
            },
            entry("NWEmptyState", "Containers") {
                NWEmptyState(Text("New agent in ~/dev/shepherd"),
                             message: "Describe the task. Drop or paste images to attach them, or type / for commands.",
                             showsMark: false, framed: true)
                    .frame(width: 420)
            },

            // Navigation and design tool
            entry("NWPaletteCard", "Navigation") { PaletteSpecimen() },
            entry("NWDesignSystemChip", "Design tool") {
                NWDesignSystemChip("night-watch", colors: [Color.nw.lantern, Color.nw.running, Color.nw.done])
            },
        ]
    }

    /// The groups, in the order the entries first name them.
    @MainActor public static var groups: [String] {
        entries.reduce(into: [String]()) { if !$0.contains($1.group) { $0.append($1.group) } }
    }

    private static func entry<Specimen: View>(_ id: String, _ group: String,
                                              @ViewBuilder _ specimen: @escaping @MainActor () -> Specimen) -> NWComponentCatalogEntry {
        NWComponentCatalogEntry(id: id, group: group, specimen: { AnyView(specimen()) })
    }
}

/// The palette card needs a focus binding of its own.
private struct PaletteSpecimen: View {
    @FocusState private var focused: Bool

    var body: some View {
        NWPaletteCard {
            NWPaletteSearchRow("Search commands, agents, subagents…", text: .constant(""), focus: $focused, submit: {}) { EmptyView() }
        } results: {
            VStack(alignment: .leading, spacing: 0) {
                NWPaletteSectionHeader("Commands")
                NWPaletteRow("New agent", systemImage: "plus", shortcut: "⌘N", highlighted: true) {}
                NWPaletteRow("Settings…", systemImage: "gearshape", shortcut: "⌘,") {}
            }
        }
        .frame(width: NWPaletteMetrics.width)
    }
}
