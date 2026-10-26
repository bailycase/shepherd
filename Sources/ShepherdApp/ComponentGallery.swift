import SwiftUI
import ShepherdUI

/// Every shared Shepherd Design component in its states, laid out like the Controls and Status
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
            VStack(alignment: .leading, spacing: SH.Space.xxxl) {
                HStack(alignment: .firstTextBaseline, spacing: SH.Space.xl) {
                    SHWordmark(size: .large)
                    Text("Every block is one SwiftUI view in ShepherdUI.").font(.sh(.body)).foregroundStyle(.sh.textSecondary)
                }
                Grid(horizontalSpacing: AppLayout.galleryColumnGap, verticalSpacing: SH.Space.xxxl) {
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
        .background(Color.sh.bgWindow)
    }

    private func column<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: AppLayout.galleryBlockSpacing) {
            SHSectionHeader(title)
            content()
        }
        .frame(width: AppLayout.galleryColumnWidth, alignment: .topLeading)
    }

    private var buttons: some View {
        VStack(alignment: .leading, spacing: AppLayout.galleryItemSpacing) {
            HStack(spacing: AppLayout.galleryItemSpacing) {
                Button("Launch") {}.buttonStyle(.sh(.primary))
                Button("Review") {}.buttonStyle(.sh(.secondary))
                Button("Cancel") {}.buttonStyle(.sh(.ghost))
                Button("Stop") {}.buttonStyle(.sh(.danger))
                Button("Delete") {}.buttonStyle(.sh(.dangerFill))
            }
            HStack(spacing: AppLayout.galleryItemSpacing) {
                Button("Small") {}.buttonStyle(.sh(.secondary, size: .s))
                Button("Large") {}.buttonStyle(.sh(.primary, size: .l))
                Button("Disabled") {}.buttonStyle(.sh(.secondary)).disabled(true)
                Button("Show all") {}.buttonStyle(.shLink)
            }
            HStack(spacing: AppLayout.galleryItemSpacing) {
                Button {} label: { Label("Fork", systemImage: "arrow.branch") }.buttonStyle(.sh(.secondary))
                Button {} label: { SHButtonTitle("Land", chord: "⌘↩") }.buttonStyle(.sh(.primary))
            }
            HStack(spacing: AppLayout.galleryItemSpacing) {
                Button {} label: { Image(systemName: "sidebar.left") }.buttonStyle(.shIcon).accessibilityLabel("Sidebar")
                Button {} label: { Image(systemName: "plus.forwardslash.minus") }.buttonStyle(.shIcon(isOn: true)).accessibilityLabel("Review")
                Button {} label: { Image(systemName: "ellipsis") }.buttonStyle(.shIcon(bordered: true)).accessibilityLabel("Options")
                Spacer()
                SHComposerActionButton(.send) {}
                SHComposerActionButton(.send, enabled: false) {}
                SHComposerActionButton(.stop) {}
            }
            HStack(spacing: SH.Space.s) {
                Button {} label: { HStack(spacing: SH.Space.s) { Text("/").foregroundStyle(.sh.textTertiary); Text("commands") }.font(.sh(.mono)) }
                    .buttonStyle(.shComposerChip())
                Button {} label: { HStack(spacing: SH.Space.s) { Text("claude-opus").font(.sh(.mono)); SHChipChevron() } }
                    .buttonStyle(.shComposerChip(active: true))
                SHAttachmentChip("screenshot.png") {}
            }
        }
    }

    private var selection: some View {
        VStack(alignment: .leading, spacing: AppLayout.galleryBlockSpacing) {
            SHSegmentedPicker("Source", selection: $segment, options: [("local", "Local"), ("pr", "PR #24")])
            SHSegmentedPicker("Mode", selection: $segment, options: [("local", "System"), ("pr", "Light"), ("dark", "Dark")], size: .s)
            HStack(spacing: AppLayout.galleryBlockSpacing) {
                Toggle("On", isOn: $toggle).toggleStyle(.shSwitch).labelsHidden()
                Toggle("Off", isOn: $toggleOff).toggleStyle(.shSwitch).labelsHidden()
                Toggle("Done when", isOn: $check).toggleStyle(.shCheckbox)
            }
            SHRadioGroup("Update channel", selection: $segment, options: [("local", "Stable"), ("pr", "Beta")])
            HStack(spacing: SH.Space.l) {
                SHKeycap(keys.display(.newSpace))
                SHCountBadge(19)
                SHCountBadge(3, tone: .attention)
                SHCountBadge(1, tone: .failed)
                SHTag("prompt")
                SHTag("claude-sonnet", mono: true)
            }
            HStack(spacing: SH.Space.l) {
                SHDiffStat(added: 58, removed: 41)
                SHInlineCode("Color.sh.lantern")
            }
        }
    }

    private var inputs: some View {
        VStack(alignment: .leading, spacing: SH.Space.l) {
            TextField("Name this agent", text: $field).textFieldStyle(.sh)
            TextField("Focused field", text: $field).shField(focused: true)
            TextField("Socket", text: .constant("shepherd.sock")).textFieldStyle(.sh(mono: true, error: true))
                .shFieldMessage("Socket path already in use")
            SHSearchField("Search settings", text: $search, shortcut: "⌘F")
            SHPopupMenu("claude-sonnet", mono: true) { Button("claude-opus") {}; Button("claude-sonnet") {} }
            SHStepper("Concurrency", value: $stepper, in: 1...16)
            SHValueSlider("Density", value: $slider, in: 0...1, step: 0.05, neutral: 0.5) { "\(Int($0 * 100))%" }
        }
    }

    private var states: some View {
        VStack(alignment: .leading, spacing: SH.Space.m) {
            ForEach(AgentState.allCases, id: \.self) { state in
                HStack(spacing: AppLayout.galleryBlockSpacing) {
                    SHStatusPill(state)
                    SHStatusDot(state)
                    SHStateGlyph(state)
                    SHBranchGlyph(state)
                }
            }
            ProgressView(value: 0.62).progressViewStyle(.shBar).frame(width: AppLayout.galleryBarWidth)
            SHStepStrip([.done, .done, .running, .attention, .failed, nil]).frame(width: AppLayout.galleryBarWidth)
            HStack(spacing: SH.Space.l) {
                ProgressView().progressViewStyle(.shSpinner)
                SHSparkline([2, 4, 3, 7, 5, 9, 4, 6, 5, 8])
            }
        }
    }

    private var settingsCard: some View {
        SHGroupCard {
            SHCardRow("Mode", description: "System follows your Mac and switches with it.") {
                SHSegmentedPicker(selection: $segment, options: [("local", "System"), ("pr", "Light"), ("dark", "Dark")])
            }
            SHCardRow("Auto-name agents", description: "Title each agent from its opening prompt.") {
                Toggle("Auto-name agents", isOn: $toggle).toggleStyle(.shSwitch).labelsHidden()
            }
            SHCardRow("Listener", description: "Serve this Mac to other Shepherds.", problem: "bind failed: Address already in use") {
                Toggle("Listener", isOn: $toggleOff).toggleStyle(.shSwitch).labelsHidden()
            }
        }
    }

    private var feedback: some View {
        VStack(alignment: .leading, spacing: AppLayout.galleryBlockSpacing) {
            SHBanner(.failed, title: "Lost connection to the agent process.") {
                Button("Reconnect") {}.buttonStyle(.sh(.secondary, size: .s))
            }
            SHBanner(.attention, title: "ios asks: keep MobileTokens as an alias?", message: "Migrating touches 31 call sites.")
            SHEmptyState(Text("New agent in \(Text("~/dev/shepherd").font(.shMono(AppLayout.emptyThreadPathSize, .medium)))"),
                         message: "Describe the task. Drop or paste images to attach them, or type / for commands.", showsMark: false, framed: true)
        }
    }

    /// The palette's own components, as the command palette lays them out.
    private var palette: some View {
        VStack(alignment: .leading, spacing: AppLayout.galleryBlockSpacing) {
            SHSectionHeader("Popover")
            SHPaletteCard {
                SHPaletteSearchRow("Search commands, agents, subagents…", text: $search, focus: $paletteFocused, submit: {}) {
                    EmptyView()
                }
            } results: {
                VStack(alignment: .leading, spacing: 0) {
                    SHPaletteSectionHeader("Commands")
                    SHPaletteRow("New agent", systemImage: "plus", shortcut: keys.display(.newAgent), highlighted: true) {}
                    SHPaletteRow("Settings…", systemImage: "gearshape", shortcut: "⌘,") {}
                }
            }
            .frame(width: AppLayout.paletteWidth)
        }
    }
}
