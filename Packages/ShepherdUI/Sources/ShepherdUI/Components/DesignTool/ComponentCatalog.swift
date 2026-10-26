import SwiftUI

/// One ShepherdUI component the design system page draws live (DesignSystemComponents): its type
/// name, its group, and a specimen built from the real component.
public struct SHComponentCatalogEntry: Identifiable {
    /// The component's type name ("SHStatusPill"): what a person greps for.
    public let id: String
    public let group: String
    public let specimen: @MainActor () -> AnyView
}

/// The components the Design system page lists, one entry per component the app's Component Gallery
/// (View ▸ Component Gallery, Debug builds) draws: buttons, selection, inputs, agent state, the settings
/// card, feedback and the palette. The page's count, its groups and its specimens all come from this list.
///
/// It is not every `SH*` view. The rest are drawn by a domain's own `#Preview` from that domain's data (a
/// thread, a diff, a design), which a specimen here would have to invent; add one when a component can be
/// drawn from literals. The count is this list's, never a claim about the library.
public enum SHComponentCatalog {
    public static let allGroups = "All groups"

    @MainActor public static var entries: [SHComponentCatalogEntry] {
        [
            // Actions
            entry("SHButtonStyle", "Actions") {
                HStack(spacing: SH.Space.m) {
                    Button("Launch") {}.buttonStyle(.sh(.primary))
                    Button("Review") {}.buttonStyle(.sh(.secondary))
                    Button("Cancel") {}.buttonStyle(.sh(.ghost))
                    Button("Stop") {}.buttonStyle(.sh(.danger))
                    Button("Delete") {}.buttonStyle(.sh(.dangerFill))
                    Button("Disabled") {}.buttonStyle(.sh(.secondary)).disabled(true)
                }
            },
            entry("SHLinkButtonStyle", "Actions") { Button("Show all") {}.buttonStyle(.shLink) },
            entry("SHButtonTitle", "Actions") { Button {} label: { SHButtonTitle("Land", chord: "⌘↩") }.buttonStyle(.sh(.primary)) },
            entry("SHIconButtonStyle", "Actions") {
                HStack(spacing: SH.Space.m) {
                    Button {} label: { Image(systemName: "sidebar.left") }.buttonStyle(.shIcon).accessibilityLabel("Sidebar")
                    Button {} label: { Image(systemName: "ellipsis") }.buttonStyle(.shIcon(bordered: true)).accessibilityLabel("Options")
                }
            },
            entry("SHComposerActionButton", "Actions") {
                HStack(spacing: SH.Space.m) {
                    SHComposerActionButton(.send) {}
                    SHComposerActionButton(.send, enabled: false) {}
                    SHComposerActionButton(.stop) {}
                }
            },
            entry("SHComposerChipStyle", "Actions") {
                HStack(spacing: SH.Space.s) {
                    Button {} label: { Text("commands").font(.sh(.mono)) }.buttonStyle(.shComposerChip())
                    Button {} label: { HStack(spacing: SH.Space.s) { Text("claude-opus").font(.sh(.mono)); SHChipChevron() } }
                        .buttonStyle(.shComposerChip(active: true))
                }
            },
            entry("SHAttachmentChip", "Actions") { SHAttachmentChip("screenshot.png") {} },
            entry("SHKeycap", "Actions") { SHKeycap("⇧⌘N") },

            // Status
            entry("SHStatusPill", "Status") {
                HStack(spacing: SH.Space.m) { ForEach(AgentState.allCases, id: \.self) { SHStatusPill($0) } }
            },
            entry("SHStatusDot", "Status") {
                HStack(spacing: SH.Space.l) { ForEach(AgentState.allCases, id: \.self) { SHStatusDot($0) } }
            },
            entry("SHStateGlyph", "Status") {
                HStack(spacing: SH.Space.l) { ForEach(AgentState.allCases, id: \.self) { SHStateGlyph($0) } }
            },
            entry("SHBranchGlyph", "Status") {
                HStack(spacing: SH.Space.l) { ForEach(AgentState.allCases, id: \.self) { SHBranchGlyph($0) } }
            },
            entry("SHBarProgressStyle", "Status") { ProgressView(value: 0.62).progressViewStyle(.shBar).frame(width: 160) },
            entry("SHStepStrip", "Status") { SHStepStrip([.done, .done, .running, .attention, .failed, nil]).frame(width: 160) },
            entry("SHSpinnerStyle", "Status") { ProgressView().progressViewStyle(.shSpinner) },
            entry("SHSparkline", "Status") { SHSparkline([2, 4, 3, 7, 5, 9, 4, 6, 5, 8]) },
            entry("SHCountBadge", "Status") {
                HStack(spacing: SH.Space.m) {
                    SHCountBadge(19)
                    SHCountBadge(3, tone: .attention)
                    SHCountBadge(1, tone: .failed)
                }
            },
            entry("SHTag", "Status") {
                HStack(spacing: SH.Space.m) {
                    SHTag("prompt")
                    SHTag("claude-sonnet", mono: true)
                }
            },
            entry("SHDiffStat", "Status") { SHDiffStat(added: 58, removed: 41) },
            entry("SHInlineCode", "Status") { SHInlineCode("Color.sh.lantern") },
            entry("SHWordmark", "Status") { SHWordmark(size: .large) },

            // Fields
            entry("SHTextFieldStyle", "Fields") {
                VStack(alignment: .leading, spacing: SH.Space.m) {
                    TextField("Name this agent", text: .constant("")).textFieldStyle(.sh)
                    TextField("Socket", text: .constant("shepherd.sock")).textFieldStyle(.sh(mono: true, error: true))
                        .shFieldMessage("Socket path already in use")
                }
                .frame(width: 220)
            },
            entry("SHSearchField", "Fields") { SHSearchField("Search settings", text: .constant(""), shortcut: "⌘F").frame(width: 220) },
            entry("SHPopupMenu", "Fields") { SHPopupMenu("claude-sonnet", mono: true) {} },
            entry("SHStepper", "Fields") { SHStepper("Concurrency", value: .constant(4), in: 1...16) },
            entry("SHValueSlider", "Fields") {
                SHValueSlider("Density", value: .constant(0.6), in: 0...1, step: 0.05, neutral: 0.5) { "\(Int($0 * 100))%" }
            },

            // Selection
            entry("SHSegmentedPicker", "Selection") {
                SHSegmentedPicker("Mode", selection: .constant("light"),
                                  options: [("system", "System"), ("light", "Light"), ("dark", "Dark")])
            },
            entry("SHRadioGroup", "Selection") {
                SHRadioGroup("Update channel", selection: .constant("beta"), options: [("stable", "Stable"), ("beta", "Beta")])
            },
            entry("SHSwitchToggleStyle", "Selection") {
                HStack(spacing: SH.Space.l) {
                    Toggle("On", isOn: .constant(true)).labelsHidden().toggleStyle(.shSwitch)
                    Toggle("Off", isOn: .constant(false)).labelsHidden().toggleStyle(.shSwitch)
                }
            },
            entry("SHCheckboxToggleStyle", "Selection") { Toggle("Done when", isOn: .constant(true)).toggleStyle(.shCheckbox) },

            // Containers and feedback
            entry("SHSectionHeader", "Containers") { SHSectionHeader("Agent state") },
            entry("SHGroupCard", "Containers") {
                SHGroupCard {
                    SHCardRow("Auto-name agents", description: "Title each agent from its opening prompt.") {
                        Toggle("Auto-name agents", isOn: .constant(true)).toggleStyle(.shSwitch).labelsHidden()
                    }
                    SHCardRow("Listener", description: "Serve this Mac to other Shepherds.", problem: "bind failed: Address already in use") {
                        Toggle("Listener", isOn: .constant(false)).toggleStyle(.shSwitch).labelsHidden()
                    }
                }
                .frame(width: 420)
            },
            entry("SHBanner", "Containers") {
                VStack(alignment: .leading, spacing: SH.Space.m) {
                    SHBanner(.failed, title: "Lost connection to the agent process.") {
                        Button("Reconnect") {}.buttonStyle(.sh(.secondary, size: .s))
                    }
                    SHBanner(.attention, title: "ios asks: keep MobileTokens as an alias?", message: "Migrating touches 31 call sites.")
                }
                .frame(width: 420)
            },
            entry("SHEmptyState", "Containers") {
                SHEmptyState(Text("New agent in ~/dev/shepherd"),
                             message: "Describe the task. Drop or paste images to attach them, or type / for commands.",
                             showsMark: false, framed: true)
                    .frame(width: 420)
            },

            // Navigation and design tool
            entry("SHPaletteCard", "Navigation") { PaletteSpecimen() },
            entry("SHDesignSystemChip", "Design tool") {
                SHDesignSystemChip("shepherd-design", colors: [Color.sh.lantern, Color.sh.running, Color.sh.done])
            },
        ]
    }

    /// The groups, in the order the entries first name them.
    @MainActor public static var groups: [String] {
        entries.reduce(into: [String]()) { if !$0.contains($1.group) { $0.append($1.group) } }
    }

    private static func entry<Specimen: View>(_ id: String, _ group: String,
                                              @ViewBuilder _ specimen: @escaping @MainActor () -> Specimen) -> SHComponentCatalogEntry {
        SHComponentCatalogEntry(id: id, group: group, specimen: { AnyView(specimen()) })
    }
}

/// The palette card needs a focus binding of its own.
private struct PaletteSpecimen: View {
    @FocusState private var focused: Bool

    var body: some View {
        SHPaletteCard {
            SHPaletteSearchRow("Search commands, agents, subagents…", text: .constant(""), focus: $focused, submit: {}) { EmptyView() }
        } results: {
            VStack(alignment: .leading, spacing: 0) {
                SHPaletteSectionHeader("Commands")
                SHPaletteRow("New agent", systemImage: "plus", shortcut: "⌘N", highlighted: true) {}
                SHPaletteRow("Settings…", systemImage: "gearshape", shortcut: "⌘,") {}
            }
        }
        .frame(width: SHPaletteMetrics.width)
    }
}
