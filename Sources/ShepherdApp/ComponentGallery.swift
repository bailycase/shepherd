import SwiftUI
import ShepherdDesign

/// Every shared component in every state, laid out like the design's Components board, for
/// checking the library against the spec in both appearances. Debug builds open it from the
/// command palette ("Component Gallery"); `ComponentGalleryTests` renders it to PNG.
struct ComponentGallery: View {
    @State private var segment = "pr"
    @State private var toggle = true
    @State private var toggleOff = false
    @State private var slider = 0.6
    @State private var field = ""
    @State private var search = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text("Components").font(Fonts.display).foregroundStyle(Tokens.text)
                    Text("Every block is one SwiftUI view in ShepherdDesign.").font(Fonts.labelRegular).foregroundStyle(Tokens.textTertiary)
                }
                Grid(horizontalSpacing: 40, verticalSpacing: 32) {
                    GridRow(alignment: .top) {
                        column("Buttons — ShepherdButton") { buttons }
                        column("Segmented control") { segmented }
                        column("Composer chips") { chips }
                    }
                    GridRow(alignment: .top) {
                        column("Sidebar rows") { sidebar }
                        column("Settings card") { settingsCard }
                        column("Feedback") { feedback }
                    }
                }
                palette
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 40)
        }
        .background(Tokens.bgSurface)
    }

    private func column<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title)
            content()
        }
        .frame(width: 400, alignment: .topLeading)
    }

    private var buttons: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button("Primary") {}.buttonStyle(ShepherdButtonStyle(.primary, size: .large))
                Button("Secondary") {}.buttonStyle(ShepherdButtonStyle(.secondary))
                Button("Ghost") {}.buttonStyle(ShepherdButtonStyle(.ghost))
            }
            HStack(spacing: 10) {
                Button("Destructive") {}.buttonStyle(ShepherdButtonStyle(.destructive))
                Button("Disabled") {}.buttonStyle(ShepherdButtonStyle(.secondary)).disabled(true)
                Button("Small") {}.buttonStyle(ShepherdButtonStyle(.secondary, size: .small))
            }
            HStack(spacing: 10) {
                Button {} label: { Image(systemName: "plus") }.buttonStyle(IconButtonStyle()).accessibilityLabel("New agent")
                Button {} label: { Image(systemName: "ellipsis") }.buttonStyle(IconButtonStyle(size: Metrics.buttonMedium)).accessibilityLabel("Options")
                Button {} label: { Image(systemName: "doc.on.doc") }.buttonStyle(IconButtonStyle(bordered: false)).accessibilityLabel("Copy")
                Spacer()
                ComposerActionButton(.send) {}
                ComposerActionButton(.send, enabled: false) {}
                ComposerActionButton(.stop) {}
            }
            Button("Show all") {}.buttonStyle(LinkButtonStyle())
        }
    }

    private var segmented: some View {
        VStack(alignment: .leading, spacing: 14) {
            SegmentedControl(selection: $segment, options: [("local", "Local"), ("pr", "PR #24")])
            SegmentedControl(selection: $segment, options: [("local", "System"), ("pr", "Light"), ("dark", "Dark")], size: .small)
            SectionHeader("Status pill")
            HStack(spacing: 8) {
                StatusPill(.idle)
                StatusPill(.running, label: "Running · 1m 04s")
                StatusPill(.needsYou, label: "1 subagent needs you")
            }
            HStack(spacing: 8) {
                StatusPill(.error)
                StatusPill(.stopped)
            }
            SectionHeader("Status dot · run glyphs")
            HStack(spacing: 18) {
                label(StatusDot(Tokens.success), "running")
                label(StatusDot(Tokens.accent), "current")
                label(StatusDot(Tokens.danger), "failed")
                label(StatusDot(Tokens.dotIdle), "idle")
            }
            HStack(spacing: 14) {
                RunStateGlyph(.running); RunStateGlyph(.done); RunStateGlyph(.failed); RunStateGlyph(.needsYou); RunStateGlyph(.queued)
                BranchGlyph(Tokens.accent); BranchGlyph(Tokens.warning); BranchGlyph(Tokens.success)
                RunCells([Tokens.success, Tokens.success, Tokens.accent, Tokens.warning, Tokens.danger])
            }
            ProgressBar(0.62).frame(width: 240)
        }
    }

    private var chips: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Button {} label: { HStack(spacing: 6) { Text("/").foregroundStyle(Tokens.textMuted); Text("commands") }.font(Fonts.mono(12)) }
                    .buttonStyle(ComposerChipStyle())
                Button {} label: { HStack(spacing: 6) { Text("claude-opus").font(Fonts.mono(12)); ChipChevron() } }
                    .buttonStyle(ComposerChipStyle(active: true))
                Button {} label: {
                    HStack(spacing: 6) {
                        Image(systemName: "lightbulb").font(.system(size: 11)).foregroundStyle(Tokens.textTertiary)
                        Text("Thinking")
                        Text("Medium").foregroundStyle(Tokens.text).fontWeight(.medium)
                        ChipChevron()
                    }
                }
                .buttonStyle(ComposerChipStyle())
            }
            SectionHeader("Attachment chip")
            HStack(spacing: 6) {
                AttachmentChip("screenshot.png") {}
                AttachmentChip("ThreadView.swift", prefix: "@") {}
            }
            SectionHeader("Diff stat · tags · keycaps")
            HStack(spacing: 16) {
                DiffStat(added: 58, removed: 41)
                Text("6 blocks").font(Fonts.micro).foregroundStyle(Tokens.textMuted)
                Tag("prompt")
                Keycaps(chord: "⇧⌘N")
            }
            HStack(spacing: 4) {
                Text("Inline code like").font(Fonts.body).foregroundStyle(Tokens.text)
                InlineCode("Tokens.textMuted")
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionHeader("This Mac", count: 19).padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 4)
            sidebarRow("Default", dot: Tokens.dotIdle, selected: false)
            sidebarRow("Selected (current)", dot: Tokens.accent, selected: true)
            sidebarRow("Running elsewhere", dot: Tokens.success, selected: false, trailing: "2m")
            sidebarRow("Needs you", dot: Tokens.warning, selected: false, trailing: "needs you")
            sidebarRow("Unreachable host", dot: Tokens.dotIdle, selected: false).opacity(0.55)
            SectionHeader("Horizon") { Text("Unreachable").font(Fonts.sans(11, .medium)).foregroundStyle(Tokens.dangerText) }
                .padding(.horizontal, 8).padding(.top, 12).padding(.bottom, 4)
        }
        .padding(8)
        .frame(width: 256)
        .background(Tokens.bgCanvas, in: RoundedRectangle(cornerRadius: Radius.lg))
        .overlay { RoundedRectangle(cornerRadius: Radius.lg).strokeBorder(Tokens.border, lineWidth: 1) }
    }

    private func sidebarRow(_ title: String, dot: Color, selected: Bool, trailing: String? = nil) -> some View {
        Button {} label: {
            HStack(spacing: 8) {
                StatusDot(dot)
                Text(title).font(selected ? Fonts.label : Fonts.labelRegular).foregroundStyle(Tokens.text).lineLimit(1)
                Spacer(minLength: 4)
                if let trailing { Text(trailing).font(Fonts.micro).foregroundStyle(Tokens.textMuted) }
            }
            .padding(.leading, 22)
            .padding(.trailing, 8)
            .frame(height: Metrics.sidebarRowHeight)
        }
        .buttonStyle(RowButtonStyle(selected: selected))
    }

    private var settingsCard: some View {
        GroupCard {
            CardRow("Mode", description: "System follows your Mac and switches with it.") {
                SegmentedControl(selection: $segment, options: [("local", "System"), ("pr", "Light"), ("dark", "Dark")])
            }
            CardRow("Auto-name agents", description: "Title each agent from its opening prompt.") {
                Toggle("", isOn: $toggle).toggleStyle(.shepherdSwitch).labelsHidden()
            }
            CardRow("Listener", description: "Serve this Mac to other Shepherds.", problem: "bind failed: Address already in use") {
                Toggle("", isOn: $toggleOff).toggleStyle(.shepherdSwitch).labelsHidden()
            }
            CardRow("Default model") {
                PopupMenu("claude-sonnet", mono: true) { Button("claude-opus") {}; Button("claude-sonnet") {} }
            }
            CardRow("Density") {
                HStack(spacing: 10) {
                    Slider(value: $slider).tint(Tokens.accent).frame(width: 160)
                    Text("105%").font(Fonts.micro).foregroundStyle(Tokens.textSecondary).frame(width: 40, alignment: .trailing)
                }
            }
        }
    }

    private var feedback: some View {
        VStack(alignment: .leading, spacing: 14) {
            InlineError("Lost connection to the agent process.", actionTitle: "Reconnect") {}
            EmptyState(Text("New agent in \(Text("~/dev/shepherd").font(Fonts.mono(15, .medium)))"),
                       caption: "Describe the task. Attach files with ⌘⇧A, or type / for commands.")
            TextField("Field", text: $field).shepherdField()
            TextField("Focused field", text: $field).shepherdField(focused: true)
            SearchField("Search settings", text: $search, shortcut: "⌘F")
        }
    }

    private var palette: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader("Menu surface")
            VStack(alignment: .leading, spacing: 0) {
                SearchField("Search commands, agents, subagents…", text: $search, large: true)
                Tokens.border.frame(height: 1)
                VStack(alignment: .leading, spacing: 2) {
                    SectionHeader("Commands", small: true).padding(.horizontal, 12).padding(.vertical, 6)
                    menuRow("New agent", icon: "plus", chord: "⌘N", selected: true)
                    menuRow("New shell", icon: "terminal", chord: "⌘T", selected: false)
                }
                .padding(8)
            }
            .frame(width: Metrics.paletteWidth)
            .menuSurface(radius: Radius.xxl)
        }
    }

    private func menuRow(_ title: String, icon: String, chord: String, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(selected ? Tokens.accent : Tokens.textTertiary).frame(width: 18)
            Text(title).font(Fonts.sans(14)).foregroundStyle(Tokens.text)
            Spacer()
            Keycaps(chord: chord)
        }
        .padding(.horizontal, 12)
        .frame(height: Metrics.paletteRowHeight)
        .rowBackground(selected: selected, hovering: false, selectedFill: Tokens.accentBg)
    }

    private func label(_ dot: StatusDot, _ text: String) -> some View {
        HStack(spacing: 6) { dot; Text(text).font(Fonts.caption).foregroundStyle(Tokens.textSecondary) }
    }
}
