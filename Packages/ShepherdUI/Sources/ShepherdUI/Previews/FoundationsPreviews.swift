import SwiftUI

#Preview("Type ramp") {
    NWPreviewBoth {
        VStack(alignment: .leading, spacing: NW.Space.m) {
            ForEach(NWTextStyle.allCases, id: \.self) { style in
                Text(verbatim: "\(style) · Night watch · 0123456789")
                    .nwText(style)
                    .foregroundStyle(.nw.textPrimary)
            }
            Text("Section label").nwSectionLabel()
        }
    }
}

#Preview("Surfaces and elevation") {
    NWPreviewBoth {
        VStack(alignment: .leading, spacing: NW.Space.xl) {
            HStack(spacing: NW.Space.l) {
                ForEach(Array(zip(["bgBase", "bgWindow", "bgRaised", "bgSunken", "bgBubble"],
                                  [Color.nw.bgBase, .nw.bgWindow, .nw.bgRaised, .nw.bgSunken, .nw.bgBubble])), id: \.0) { name, color in
                    VStack(spacing: NW.Space.xs) {
                        RoundedRectangle(cornerRadius: NW.Radius.s).fill(color).frame(width: 56, height: 40)
                            .nwBorder(.nw.lineSubtle, radius: NW.Radius.s)
                        Text(name).font(.nw(.mono)).foregroundStyle(.nw.textSecondary)
                    }
                }
            }
            HStack(spacing: NW.Space.xl) {
                Color.clear.frame(width: 180, height: 70).nwCard()
                Color.clear.frame(width: 180, height: 70).nwPopover()
            }
            HStack(spacing: NW.Space.m) {
                ForEach([Color.nw.lantern, .nw.running, .nw.done, .nw.failed], id: \.self) { color in
                    Circle().fill(color).frame(width: 18, height: 18)
                }
            }
        }
    }
}

#Preview("Containers") {
    NWPreviewBoth {
        VStack(alignment: .leading, spacing: NW.Space.m) {
            NWSectionHeader("This Mac", count: 19)
            NWGroupCard {
                NWCardRow("Mode", description: "System follows your Mac and switches with it.") { NWTag("System") }
                NWCardRow("Listener", description: "Serve this Mac to other Shepherds.", problem: "bind failed: Address already in use") {
                    Toggle("Listener", isOn: .constant(false)).toggleStyle(.nwSwitch).labelsHidden()
                }
            }
            Button {} label: {
                HStack { NWStatusDot(.running); Text("Row").font(.nw(.ui)).foregroundStyle(.nw.textPrimary); Spacer() }
                    .padding(.horizontal, NW.Space.m).frame(height: NW.Height.row)
            }
            .buttonStyle(.nwRow(selected: true))
        }
        .frame(width: 420)
    }
}

#Preview("Thread and composer parts") {
    NWPreviewBoth {
        VStack(alignment: .leading, spacing: NW.Space.l) {
            HStack(spacing: NW.Space.l) {
                NWDiffStat(added: 58, removed: 41)
                NWInlineCode("Color.nw.lantern")
                NWAttachmentChip("screenshot.png") {}
            }
            HStack(spacing: NW.Space.s) {
                Button {} label: { HStack(spacing: 6) { Text("claude-opus").font(.nw(.mono)); NWChipChevron() } }
                    .buttonStyle(.nwComposerChip(active: true))
                NWComposerActionButton(.send) {}
                NWComposerActionButton(.send, enabled: false) {}
                NWComposerActionButton(.stop) {}
            }
        }
    }
}
