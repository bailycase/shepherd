import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

/// More ▸ Design systems (MobileMore's row): the hosts' systems, each opening its page.
struct DesignSystemsScreen: View {
    @Environment(MobileHosts.self) private var hosts

    var body: some View {
        let designs = MobileDesigns.of(hosts)
        ScrollView {
            VStack(alignment: .leading, spacing: MobileLayout.headerSpacing) {
                if designs.model.systems.isEmpty {
                    NWEmptyState(Text("No design systems"), message: "A host's design systems show here while it serves designs.",
                                 showsMark: false)
                        .frame(maxWidth: .infinity)
                        .padding(.top, NW.Space.xxxl)
                } else {
                    DesignSystemsCard(rows: designs.model.systems, swatches: designs.swatches)
                }
            }
            .padding(.horizontal, MobileDesignLayout.gutter)
            .padding(.vertical, NW.Space.l)
            .frame(maxWidth: MobileLayout.homeMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .background(Color.nw.bgWindow)
        .refreshable { await designs.refresh() }
        .task { await designs.refresh() }
        .navigationTitle("Design systems")
    }
}

/// One design system on the phone. No board draws it: the least that says what the host read,
/// its source and counts, then its colors, type styles and steps as rows.
struct DesignSystemScreen: View {
    let host: UUID
    let namespace: String
    @Environment(MobileHosts.self) private var hosts
    @State private var system: DesignSystemRead?
    @State private var problem: String?

    var body: some View {
        List {
            if let system {
                Section {
                    Text(DesignSystemPresentation.counts(system.summary.counts))
                        .nwText(.caption).foregroundStyle(Color.nw.textSecondary)
                }
                if let colors = system.tokens?.colors, !colors.isEmpty {
                    Section("Colors") {
                        ForEach(colors, id: \.name) { color in
                            HStack(spacing: NW.Space.l) {
                                RoundedRectangle(cornerRadius: NWPhoneDesignMetrics.swatchRadius)
                                    .fill(DesignSystemPresentation.Swatch(color).map { Color(light: $0.light, dark: $0.dark) } ?? .clear)
                                    .frame(width: NWPhoneDesignMetrics.swatchHeight, height: NWPhoneDesignMetrics.swatchHeight)
                                    .nwBorder(Color.nw.lineSubtle, radius: NWPhoneDesignMetrics.swatchRadius)
                                VStack(alignment: .leading, spacing: NW.Space.xxs) {
                                    Text(color.name).font(.nw(.mono)).foregroundStyle(Color.nw.textPrimary)
                                    Text(DesignSystemPresentation.detail(color)).nwText(.caption).foregroundStyle(Color.nw.textTertiary)
                                }
                            }
                        }
                    }
                }
                if let type = system.tokens?.type, !type.isEmpty {
                    Section("Type") {
                        ForEach(type, id: \.name) { style in
                            LabeledContent(style.name, value: DesignSystemPresentation.detail(style))
                        }
                    }
                }
                if let steps = system.tokens.map({ $0.spacing + $0.radii }), !steps.isEmpty {
                    Section("Spacing & radii") {
                        ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                            LabeledContent(step.name, value: DesignSystemPresentation.detail(step))
                        }
                    }
                }
            } else if let problem {
                Text(problem).foregroundStyle(Color.nw.failed)
            } else {
                ProgressView().progressViewStyle(.nwSpinner).frame(maxWidth: .infinity)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.nw.bgWindow)
        .navigationTitle(system?.summary.info.title ?? namespace)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                system = try await MobileDesigns.of(hosts).system(host: host, namespace: namespace)
            } catch {
                problem = MobileDesignsError.words(error)
            }
        }
    }
}
