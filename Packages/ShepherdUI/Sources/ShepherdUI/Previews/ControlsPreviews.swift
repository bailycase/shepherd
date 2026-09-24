import SwiftUI

#Preview("Buttons") {
    NWPreviewBoth {
        VStack(alignment: .leading, spacing: NW.Space.l) {
            HStack(spacing: 10) {
                Button("Launch") {}.buttonStyle(.nw(.primary))
                Button("Review") {}.buttonStyle(.nw(.secondary))
                Button("Cancel") {}.buttonStyle(.nw(.ghost))
                Button("Stop") {}.buttonStyle(.nw(.danger))
                Button("Delete") {}.buttonStyle(.nw(.dangerFill))
            }
            HStack(spacing: 10) {
                Button("Small") {}.buttonStyle(.nw(.primary, size: .s))
                Button("Medium") {}.buttonStyle(.nw(.primary, size: .m))
                Button("Large") {}.buttonStyle(.nw(.primary, size: .l))
                Button("Disabled") {}.buttonStyle(.nw(.secondary)).disabled(true)
            }
            HStack(spacing: 10) {
                Button {} label: { Label("Fork", systemImage: "arrow.branch") }.buttonStyle(.nw(.secondary))
                Button {} label: { Label("Re-run", systemImage: "arrow.clockwise") }.buttonStyle(.nw(.secondary))
                Button("Show all") {}.buttonStyle(.nwLink)
            }
        }
    }
}

#Preview("Icon buttons") {
    NWPreviewBoth {
        HStack(spacing: NW.Space.m) {
            Button {} label: { Image(systemName: "sidebar.left") }.buttonStyle(.nwIcon).accessibilityLabel("Sidebar")
            Button {} label: { Image(systemName: "plus.forwardslash.minus") }.buttonStyle(.nwIcon(isOn: true)).accessibilityLabel("Review")
            Button {} label: { Image(systemName: "ellipsis") }.buttonStyle(.nwIcon(bordered: true)).accessibilityLabel("More")
            Button {} label: { Image(systemName: "paperclip") }.buttonStyle(.nwIcon).disabled(true).accessibilityLabel("Attach")
        }
    }
}

#Preview("Selection") {
    @Previewable @State var source = "local"
    @Previewable @State var scope = "commands"
    @Previewable @State var on = true
    @Previewable @State var off = false
    @Previewable @State var check = true
    NWPreviewBoth {
        VStack(alignment: .leading, spacing: NW.Space.l) {
            NWSegmentedPicker("Source", selection: $source, options: [("local", "Local"), ("pr", "PR #24")])
            NWSegmentedPicker("Scope", selection: $scope, options: [("all", "All"), ("commands", "Commands"), ("agents", "Agents")], size: .s)
            HStack(spacing: 14) {
                Toggle("Check for updates", isOn: $on).toggleStyle(.nwSwitch).labelsHidden()
                Toggle("Off", isOn: $off).toggleStyle(.nwSwitch).labelsHidden()
                Toggle("Disabled", isOn: $on).toggleStyle(.nwSwitch).labelsHidden().disabled(true)
            }
            HStack(spacing: 14) {
                Toggle("Done when", isOn: $check).toggleStyle(.nwCheckbox)
                Toggle("Unchecked", isOn: $off).toggleStyle(.nwCheckbox)
            }
        }
    }
}

#Preview("Inputs") {
    @Previewable @State var name = ""
    @Previewable @State var socket = "shepherd.sock"
    @Previewable @State var query = ""
    @Previewable @State var size = 0.62
    @Previewable @State var budget = 3
    NWPreviewBoth {
        VStack(alignment: .leading, spacing: NW.Space.l) {
            TextField("Name this agent", text: $name).textFieldStyle(.nw).frame(width: 220)
            TextField("Socket", text: $socket).nwField(error: true, mono: true).frame(width: 220)
            TextField("Disabled", text: $name).textFieldStyle(.nw).disabled(true).frame(width: 220)
            NWSearchField("Search agents", text: $query, shortcut: "⌘F").frame(width: 220)
            NWPopupMenu("claude-opus", mono: true, minWidth: 200) { Button("claude-opus") {}; Button("claude-sonnet") {} }
            NWStepper("Budget", value: $budget, in: 1...9) { "\($0)M tok" }
            NWValueSlider("Size", value: $size, in: 0...1, step: 0.01, neutral: 0.5) { "\(Int($0 * 100))%" }
        }
    }
}

#Preview("Small parts") {
    NWPreviewBoth {
        VStack(alignment: .leading, spacing: NW.Space.l) {
            HStack(spacing: NW.Space.l) { NWKeycap("⌘K"); NWKeycap("⇧⌘B"); NWKeycap(keys: ["⏎"]) }
            HStack(spacing: 10) { NWCountBadge(19); NWCountBadge(3, tone: .attention); NWCountBadge(1, tone: .failed) }
            HStack(spacing: NW.Space.s) { NWTag("worker"); NWTag("claude-sonnet", mono: true); NWTag("prompt") }
        }
    }
}
