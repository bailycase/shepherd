import SwiftUI

#Preview("Buttons") {
    SHPreviewBoth {
        VStack(alignment: .leading, spacing: SH.Space.l) {
            HStack(spacing: 10) {
                Button("Launch") {}.buttonStyle(.sh(.primary))
                Button("Review") {}.buttonStyle(.sh(.secondary))
                Button("Cancel") {}.buttonStyle(.sh(.ghost))
                Button("Stop") {}.buttonStyle(.sh(.danger))
                Button("Delete") {}.buttonStyle(.sh(.dangerFill))
            }
            HStack(spacing: 10) {
                Button("Small") {}.buttonStyle(.sh(.primary, size: .s))
                Button("Medium") {}.buttonStyle(.sh(.primary, size: .m))
                Button("Large") {}.buttonStyle(.sh(.primary, size: .l))
                Button("Disabled") {}.buttonStyle(.sh(.secondary)).disabled(true)
            }
            HStack(spacing: 10) {
                Button {} label: { Label("Fork", systemImage: "arrow.branch") }.buttonStyle(.sh(.secondary))
                Button {} label: { Label("Re-run", systemImage: "arrow.clockwise") }.buttonStyle(.sh(.secondary))
                Button {} label: { SHButtonTitle("Land", chord: "⌘↩") }.buttonStyle(.sh(.primary))
                Button("Show all") {}.buttonStyle(.shLink)
            }
        }
    }
}

#Preview("Icon buttons") {
    SHPreviewBoth {
        HStack(spacing: SH.Space.m) {
            Button {} label: { Image(systemName: "sidebar.left") }.buttonStyle(.shIcon).accessibilityLabel("Sidebar")
            Button {} label: { Image(systemName: "plus.forwardslash.minus") }.buttonStyle(.shIcon(isOn: true)).accessibilityLabel("Review")
            Button {} label: { Image(systemName: "ellipsis") }.buttonStyle(.shIcon(bordered: true)).accessibilityLabel("More")
            Button {} label: { Image(systemName: "paperclip") }.buttonStyle(.shIcon).disabled(true).accessibilityLabel("Attach")
        }
    }
}

#Preview("Selection") {
    @Previewable @State var source = "local"
    @Previewable @State var scope = "commands"
    @Previewable @State var on = true
    @Previewable @State var off = false
    @Previewable @State var check = true
    SHPreviewBoth {
        VStack(alignment: .leading, spacing: SH.Space.l) {
            SHSegmentedPicker("Source", selection: $source, options: [("local", "Local"), ("pr", "PR #24")])
            SHSegmentedPicker("Scope", selection: $scope, options: [("all", "All"), ("commands", "Commands"), ("agents", "Agents")], size: .s)
            HStack(spacing: 14) {
                Toggle("Check for updates", isOn: $on).toggleStyle(.shSwitch).labelsHidden()
                Toggle("Off", isOn: $off).toggleStyle(.shSwitch).labelsHidden()
                Toggle("Disabled", isOn: $on).toggleStyle(.shSwitch).labelsHidden().disabled(true)
            }
            HStack(spacing: 14) {
                Toggle("Done when", isOn: $check).toggleStyle(.shCheckbox)
                Toggle("Unchecked", isOn: $off).toggleStyle(.shCheckbox)
            }
            SHRadioGroup("Channel", selection: $source, options: [("local", "Stable"), ("pr", "Beta")])
        }
    }
}

#Preview("Inputs") {
    @Previewable @State var name = ""
    @Previewable @State var socket = "shepherd.sock"
    @Previewable @State var query = ""
    @Previewable @State var size = 0.62
    @Previewable @State var budget = 3
    SHPreviewBoth {
        VStack(alignment: .leading, spacing: SH.Space.l) {
            TextField("Name this agent", text: $name).textFieldStyle(.sh).frame(width: 220)
            TextField("Socket", text: $socket).shField(error: true, mono: true).frame(width: 220)
                .shFieldMessage("Socket path already in use")
            TextField("Disabled", text: $name).textFieldStyle(.sh).disabled(true).frame(width: 220)
            SHSearchField("Search agents", text: $query, shortcut: "⌘F").frame(width: 220)
            SHPopupMenu("claude-opus", mono: true, minWidth: 200) { Button("claude-opus") {}; Button("claude-sonnet") {} }
            SHStepper("Budget", value: $budget, in: 1...9) { "\($0)M tok" }
            SHValueSlider("Size", value: $size, in: 0...1, step: 0.01, neutral: 0.5) { "\(Int($0 * 100))%" }
        }
    }
}

#Preview("Small parts") {
    SHPreviewBoth {
        VStack(alignment: .leading, spacing: SH.Space.l) {
            HStack(spacing: SH.Space.l) { SHKeycap("⌘K"); SHKeycap("⇧⌘B"); SHKeycap(keys: ["⏎"]) }
            HStack(spacing: 10) { SHCountBadge(19); SHCountBadge(3, tone: .attention); SHCountBadge(1, tone: .failed) }
            HStack(spacing: SH.Space.s) { SHTag("worker"); SHTag("claude-sonnet", mono: true); SHTag("prompt") }
        }
    }
}
