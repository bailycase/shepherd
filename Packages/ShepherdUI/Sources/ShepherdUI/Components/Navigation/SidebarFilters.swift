import SwiftUI

/// A compact bar of independent thread filters. The chips wrap rather than hiding options at
/// narrower sidebar widths or larger text sizes; iPhone and iPad keep full touch targets.
public struct SHSidebarFilterBar<Chip: Identifiable & Hashable, Host: Identifiable>: View where Host.ID == UUID {
    let chips: [Chip]
    let selection: Set<Chip>
    let hosts: [Host]
    let host: UUID?
    let title: (Chip) -> String
    let hostName: (Host) -> String
    let toggle: (Chip) -> Void
    let selectHost: (UUID?) -> Void

    public init(chips: [Chip], selection: Set<Chip>, hosts: [Host], host: UUID?,
                title: @escaping (Chip) -> String, hostName: @escaping (Host) -> String,
                toggle: @escaping (Chip) -> Void, selectHost: @escaping (UUID?) -> Void) {
        self.chips = chips
        self.selection = selection
        self.hosts = hosts
        self.host = host
        self.title = title
        self.hostName = hostName
        self.toggle = toggle
        self.selectHost = selectHost
    }

    public var body: some View {
        SHFlowLayout(spacing: SH.Space.s, lineSpacing: SH.Space.xs) {
            ForEach(chips) { chip in
                let selected = selection.contains(chip)
                Button { toggle(chip) } label: {
                    SHSidebarFilterLabel(title(chip), selected: selected, showsChevron: false)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            if hosts.count > 1 { hostPicker }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Thread filters")
    }

    private var hostPicker: some View {
        let label = hosts.first { $0.id == host }.map(hostName) ?? "All hosts"
        return Menu {
            Picker("Host", selection: Binding(get: { host }, set: selectHost)) {
                Text("All Hosts").tag(nil as UUID?)
                ForEach(hosts) { option in Text(hostName(option)).tag(Optional(option.id)) }
            }
            .pickerStyle(.inline)
        } label: {
            SHSidebarFilterLabel(label, selected: host != nil, showsChevron: true)
                .accessibilityLabel("Filter by host: \(label)")
        }
        #if os(macOS)
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        #else
        .buttonStyle(.plain)
        #endif
    }
}

private struct SHSidebarFilterLabel: View {
    let title: String
    let selected: Bool
    let showsChevron: Bool

    init(_ title: String, selected: Bool, showsChevron: Bool) {
        self.title = title
        self.selected = selected
        self.showsChevron = showsChevron
    }

    var body: some View {
        HStack(spacing: SH.Space.xs) {
            if selected && !showsChevron { Image(systemName: "checkmark").accessibilityHidden(true) }
            Text(title).lineLimit(1)
            if showsChevron { SHChipChevron() }
        }
        .font(.sh(.caption, weight: .medium))
        .foregroundStyle(selected ? Color.sh.textPrimary : Color.sh.textSecondary)
        .padding(.horizontal, SH.Space.s)
        .frame(minHeight: SH.Height.controlS)
        .background(selected ? Color.sh.bgSelected : Color.sh.bgRaised, in: Capsule())
        .shBorder(selected ? Color.sh.lineStrong : Color.sh.lineSubtle, in: Capsule())
        #if !os(macOS)
        .frame(minHeight: SH.Height.touch)
        #endif
        .contentShape(Rectangle())
    }
}

public struct SHSidebarFilterEmpty: View {
    let clear: () -> Void

    public init(clear: @escaping () -> Void) { self.clear = clear }

    public var body: some View {
        HStack(spacing: SH.Space.s) {
            Text("No threads match")
                .shText(.caption)
                .foregroundStyle(Color.sh.textSecondary)
            Spacer(minLength: SH.Space.xs)
            Button("Clear", action: clear)
                .buttonStyle(.sh(.ghost, size: .s))
                .accessibilityLabel("Clear filters")
        }
        #if !os(macOS)
        .frame(minHeight: SH.Height.touch)
        #endif
    }
}

#Preview("Thread filters") {
    SHPreviewBoth {
        VStack(alignment: .leading, spacing: SH.Space.m) {
            SHSidebarFilterLabel("Running", selected: true, showsChevron: false)
            SHSidebarFilterLabel("Needs you", selected: false, showsChevron: false)
            SHSidebarFilterLabel("All hosts", selected: false, showsChevron: true)
            SHSidebarFilterEmpty {}
        }
        .padding(SH.Space.l)
        .background(Color.sh.bgBase)
    }
}
