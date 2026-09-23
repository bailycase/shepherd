import SwiftUI
import ShepherdUI

/// Every shared Night Watch component in its states, laid out like the Controls and Status
/// boards, for checking the library against the spec in both appearances. Debug builds open it
/// from the View menu (View ▸ Component Gallery).
struct ComponentGallery: View {
    @State private var segment = "pr"
    @State private var toggle = true
    @State private var toggleOff = false
    @State private var check = true
    @State private var slider = 0.6
    @State private var stepper = 4
    @State private var field = ""
    @State private var search = ""
    @FocusState private var paletteFocused: Bool
    private var keys: KeybindingsStore { .shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NW.Space.xxxl) {
                HStack(alignment: .firstTextBaseline, spacing: NW.Space.xl) {
                    NWWordmark(size: .large)
                    Text("Every block is one SwiftUI view in ShepherdUI.").font(.nw(.body)).foregroundStyle(.nw.textSecondary)
                }
                Grid(horizontalSpacing: AppLayout.galleryColumnGap, verticalSpacing: NW.Space.xxxl) {
                    GridRow(alignment: .top) {
                        column("Buttons") { buttons }
                        column("Selection") { selection }
                        column("Inputs") { inputs }
                    }
                    GridRow(alignment: .top) {
                        column("Agent state") { states }
                        column("Settings card") { settingsCard }
                        column("Feedback") { feedback }
                    }
                }
                palette
            }
            .padding(.horizontal, AppLayout.galleryGutter)
            .padding(.vertical, AppLayout.galleryTop)
        }
        .background(Color.nw.bgWindow)
    }

    private func column<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: AppLayout.galleryBlockSpacing) {
            NWSectionHeader(title)
            content()
        }
        .frame(width: AppLayout.galleryColumnWidth, alignment: .topLeading)
    }

    private var buttons: some View {
        VStack(alignment: .leading, spacing: AppLayout.galleryItemSpacing) {
            HStack(spacing: AppLayout.galleryItemSpacing) {
                Button("Launch") {}.buttonStyle(.nw(.primary))
                Button("Review") {}.buttonStyle(.nw(.secondary))
                Button("Cancel") {}.buttonStyle(.nw(.ghost))
                Button("Stop") {}.buttonStyle(.nw(.danger))
                Button("Delete") {}.buttonStyle(.nw(.dangerFill))
            }
            HStack(spacing: AppLayout.galleryItemSpacing) {
                Button("Small") {}.buttonStyle(.nw(.secondary, size: .s))
                Button("Large") {}.buttonStyle(.nw(.primary, size: .l))
                Button("Disabled") {}.buttonStyle(.nw(.secondary)).disabled(true)
                Button("Show all") {}.buttonStyle(.nwLink)
            }
            HStack(spacing: AppLayout.galleryItemSpacing) {
                Button {} label: { Image(systemName: "sidebar.left") }.buttonStyle(.nwIcon).accessibilityLabel("Sidebar")
                Button {} label: { Image(systemName: "plus.forwardslash.minus") }.buttonStyle(.nwIcon(isOn: true)).accessibilityLabel("Review")
                Button {} label: { Image(systemName: "ellipsis") }.buttonStyle(.nwIcon(bordered: true)).accessibilityLabel("Options")
                Spacer()
                NWComposerActionButton(.send) {}
                NWComposerActionButton(.send, enabled: false) {}
                NWComposerActionButton(.stop) {}
            }
            HStack(spacing: NW.Space.s) {
                Button {} label: { HStack(spacing: NW.Space.s) { Text("/").foregroundStyle(.nw.textTertiary); Text("commands") }.font(.nw(.mono)) }
                    .buttonStyle(.nwComposerChip())
                Button {} label: { HStack(spacing: NW.Space.s) { Text("claude-opus").font(.nw(.mono)); NWChipChevron() } }
                    .buttonStyle(.nwComposerChip(active: true))
                NWAttachmentChip("screenshot.png") {}
            }
        }
    }

    private var selection: some View {
        VStack(alignment: .leading, spacing: AppLayout.galleryBlockSpacing) {
            NWSegmentedPicker("Source", selection: $segment, options: [("local", "Local"), ("pr", "PR #24")])
            NWSegmentedPicker("Mode", selection: $segment, options: [("local", "System"), ("pr", "Light"), ("dark", "Dark")], size: .s)
            HStack(spacing: AppLayout.galleryBlockSpacing) {
                Toggle("On", isOn: $toggle).toggleStyle(.nwSwitch).labelsHidden()
                Toggle("Off", isOn: $toggleOff).toggleStyle(.nwSwitch).labelsHidden()
                Toggle("Done when", isOn: $check).toggleStyle(.nwCheckbox)
            }
            HStack(spacing: NW.Space.l) {
                NWKeycap(keys.display(.newSpace))
                NWCountBadge(19)
                NWCountBadge(3, tone: .attention)
                NWCountBadge(1, tone: .failed)
                NWTag("prompt")
                NWTag("claude-sonnet", mono: true)
            }
            HStack(spacing: NW.Space.l) {
                NWDiffStat(added: 58, removed: 41)
                NWInlineCode("Color.nw.lantern")
            }
        }
    }

    private var inputs: some View {
        VStack(alignment: .leading, spacing: NW.Space.l) {
            TextField("Name this agent", text: $field).textFieldStyle(.nw)
            TextField("Focused field", text: $field).nwField(focused: true)
            NWSearchField("Search settings", text: $search, shortcut: "⌘F")
            NWPopupMenu("claude-sonnet", mono: true) { Button("claude-opus") {}; Button("claude-sonnet") {} }
            NWStepper("Concurrency", value: $stepper, in: 1...16)
            NWValueSlider("Density", value: $slider, in: 0...1, step: 0.05, neutral: 0.5) { "\(Int($0 * 100))%" }
        }
    }

    private var states: some View {
        VStack(alignment: .leading, spacing: NW.Space.m) {
            ForEach(AgentState.allCases, id: \.self) { state in
                HStack(spacing: AppLayout.galleryBlockSpacing) {
                    NWStatusPill(state)
                    NWStatusDot(state)
                    NWStateGlyph(state)
                    NWBranchGlyph(state)
                }
            }
            ProgressView(value: 0.62).progressViewStyle(.nwBar).frame(width: AppLayout.galleryBarWidth)
            NWStepStrip([.done, .done, .running, .attention, .failed, nil]).frame(width: AppLayout.galleryBarWidth)
            HStack(spacing: NW.Space.l) {
                ProgressView().progressViewStyle(.nwSpinner)
                NWSparkline([2, 4, 3, 7, 5, 9, 4, 6, 5, 8])
            }
        }
    }

    private var settingsCard: some View {
        NWGroupCard {
            NWCardRow("Mode", description: "System follows your Mac and switches with it.") {
                NWSegmentedPicker(selection: $segment, options: [("local", "System"), ("pr", "Light"), ("dark", "Dark")])
            }
            NWCardRow("Auto-name agents", description: "Title each agent from its opening prompt.") {
                Toggle("Auto-name agents", isOn: $toggle).toggleStyle(.nwSwitch).labelsHidden()
            }
            NWCardRow("Listener", description: "Serve this Mac to other Shepherds.", problem: "bind failed: Address already in use") {
                Toggle("Listener", isOn: $toggleOff).toggleStyle(.nwSwitch).labelsHidden()
            }
        }
    }

    private var feedback: some View {
        VStack(alignment: .leading, spacing: AppLayout.galleryBlockSpacing) {
            NWBanner(.failed, title: "Lost connection to the agent process.") {
                Button("Reconnect") {}.buttonStyle(.nw(.secondary, size: .s))
            }
            NWBanner(.attention, title: "ios asks: keep MobileTokens as an alias?", message: "Migrating touches 31 call sites.")
            NWEmptyState(Text("New agent in \(Text("~/dev/shepherd").font(.nwMono(AppLayout.emptyThreadPathSize, .medium)))"),
                         message: "Describe the task. Drop or paste images to attach them, or type / for commands.", showsMark: false, framed: true)
        }
    }

    /// The palette's own components, as the command palette lays them out.
    private var palette: some View {
        VStack(alignment: .leading, spacing: AppLayout.galleryBlockSpacing) {
            NWSectionHeader("Popover")
            NWPaletteCard {
                NWPaletteSearchRow("Search commands, agents, subagents…", text: $search, focus: $paletteFocused, submit: {}) {
                    EmptyView()
                }
            } results: {
                VStack(alignment: .leading, spacing: 0) {
                    NWPaletteSectionHeader("Commands")
                    NWPaletteRow("New agent", systemImage: "plus", shortcut: keys.display(.newAgent), highlighted: true) {}
                    NWPaletteRow("Settings…", systemImage: "gearshape", shortcut: "⌘,") {}
                }
            }
            .frame(width: AppLayout.paletteWidth)
        }
    }
}
