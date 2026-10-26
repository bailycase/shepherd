import SwiftUI

#Preview("Type ramp") {
    SHPreviewBoth {
        VStack(alignment: .leading, spacing: SH.Space.m) {
            ForEach(SHTextStyle.allCases, id: \.self) { style in
                Text(verbatim: "\(style) · Shepherd design · 0123456789")
                    .shText(style)
                    .foregroundStyle(.sh.textPrimary)
            }
            Text("Section label").shSectionLabel()
        }
    }
}

#Preview("Surfaces and elevation") {
    SHPreviewBoth {
        VStack(alignment: .leading, spacing: SH.Space.xl) {
            HStack(spacing: SH.Space.l) {
                ForEach(Array(zip(["bgBase", "bgWindow", "bgRaised", "bgSunken", "bgBubble"],
                                  [Color.sh.bgBase, .sh.bgWindow, .sh.bgRaised, .sh.bgSunken, .sh.bgBubble])), id: \.0) { name, color in
                    VStack(spacing: SH.Space.xs) {
                        RoundedRectangle(cornerRadius: SH.Radius.s).fill(color).frame(width: 56, height: 40)
                            .shBorder(.sh.lineSubtle, radius: SH.Radius.s)
                        Text(name).font(.sh(.mono)).foregroundStyle(.sh.textSecondary)
                    }
                }
            }
            HStack(spacing: SH.Space.xl) {
                Color.clear.frame(width: 180, height: 70).shCard()
                Color.clear.frame(width: 180, height: 70).shPopover()
            }
            HStack(spacing: SH.Space.m) {
                ForEach([Color.sh.lantern, .sh.running, .sh.done, .sh.failed], id: \.self) { color in
                    Circle().fill(color).frame(width: 18, height: 18)
                }
            }
        }
    }
}

#Preview("Containers") {
    SHPreviewBoth {
        VStack(alignment: .leading, spacing: SH.Space.m) {
            SHSectionHeader("This Mac", count: 19)
            SHGroupCard {
                SHCardRow("Mode", description: "System follows your Mac and switches with it.") { SHTag("System") }
                SHCardRow("Listener", description: "Serve this Mac to other Shepherds.", problem: "bind failed: Address already in use") {
                    Toggle("Listener", isOn: .constant(false)).toggleStyle(.shSwitch).labelsHidden()
                }
            }
            Button {} label: {
                HStack { SHStatusDot(.running); Text("Row").font(.sh(.ui)).foregroundStyle(.sh.textPrimary); Spacer() }
                    .padding(.horizontal, SH.Space.m).frame(height: SH.Height.row)
            }
            .buttonStyle(.shRow(selected: true))
        }
        .frame(width: 420)
    }
}

#Preview("Settings rows") {
    SHPreviewBoth {
        VStack(alignment: .leading, spacing: SH.Space.m) {
            SHSectionHeader("New agents")
            SHGroupCard(fill: Color.sh.bgWindow) {
                SHCardRow("Default model", description: "“Use the agent’s default” passes no `--model` at all.", style: .settings) {
                    SHTag("Use the agent’s default")
                }
                SHCardRow("Listener", description: "Let other Macs with your token connect to agents here.",
                          problem: "Couldn't start: port 7433 is already in use.",
                          problemHelp: "bind failed: Address already in use (errno 48)", style: .settings) {
                    Toggle("Listener", isOn: .constant(true)).toggleStyle(.shSwitch).labelsHidden()
                }
            }
            SHSettingsNavRow("Appearance", systemImage: "circle.lefthalf.filled", selected: true) {}
            SHSettingsNavRow("Remote", systemImage: SHGlyph.remoteConnection.symbolName, selected: false) {}
        }
        .frame(width: 560)
        .padding(SH.Space.xl)
        .background(Color.sh.bgWindow)
    }
}

#Preview("Thread and composer parts") {
    SHPreviewBoth {
        VStack(alignment: .leading, spacing: SH.Space.l) {
            HStack(spacing: SH.Space.l) {
                SHDiffStat(added: 58, removed: 41)
                SHInlineCode("Color.sh.lantern")
                SHAttachmentChip("screenshot.png") {}
            }
            HStack(spacing: SH.Space.s) {
                Button {} label: { HStack(spacing: 6) { Text("claude-opus").font(.sh(.mono)); SHChipChevron() } }
                    .buttonStyle(.shComposerChip(active: true))
                SHComposerActionButton(.send) {}
                SHComposerActionButton(.send, enabled: false) {}
                SHComposerActionButton(.stop) {}
            }
        }
    }
}
