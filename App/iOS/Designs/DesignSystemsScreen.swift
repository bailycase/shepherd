import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

/// Settings ▸ Design systems (MobileMore's row, now in Settings): the hosts' systems, each opening its page.
struct DesignSystemsScreen: View {
    @Environment(MobileHosts.self) private var hosts

    var body: some View {
        let designs = MobileDesigns.of(hosts)
        ScrollView {
            VStack(alignment: .leading, spacing: MobileLayout.headerSpacing) {
                if designs.model.systems.isEmpty {
                    SHEmptyState(Text("No design systems"), message: "A host's design systems show here while it serves designs.",
                                 showsMark: false)
                        .frame(maxWidth: .infinity)
                        .padding(.top, SH.Space.xxxl)
                } else {
                    DesignSystemsCard(rows: designs.model.systems, swatches: designs.swatches)
                }
            }
            .padding(.horizontal, MobileDesignLayout.gutter)
            .padding(.vertical, SH.Space.l)
            .frame(maxWidth: MobileLayout.homeMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .background(Color.sh.bgWindow)
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
    @Environment(MobileNavigator.self) private var navigator
    @Environment(\.dismiss) private var dismiss
    @State private var system: DesignSystemRead?
    @State private var problem: String?
    @State private var renaming = false
    @State private var deleting = false
    @State private var title = ""

    var body: some View {
        List {
            if let system {
                if let problem {
                    Section { Text(problem).foregroundStyle(Color.sh.failed) }
                }
                Section {
                    Text(DesignSystemPresentation.counts(system.summary.counts))
                        .shText(.caption).foregroundStyle(Color.sh.textSecondary)
                }
                if let colors = system.tokens?.colors, !colors.isEmpty {
                    Section("Colors") {
                        ForEach(colors, id: \.name) { color in
                            HStack(spacing: SH.Space.l) {
                                RoundedRectangle(cornerRadius: SHPhoneDesignMetrics.swatchRadius)
                                    .fill(DesignSystemPresentation.Swatch(color).map { Color(light: $0.light, dark: $0.dark) } ?? .clear)
                                    .frame(width: SHPhoneDesignMetrics.swatchHeight, height: SHPhoneDesignMetrics.swatchHeight)
                                    .shBorder(Color.sh.lineSubtle, radius: SHPhoneDesignMetrics.swatchRadius)
                                VStack(alignment: .leading, spacing: SH.Space.xxs) {
                                    Text(color.name).font(.sh(.mono)).foregroundStyle(Color.sh.textPrimary)
                                    Text(DesignSystemPresentation.detail(color)).shText(.caption).foregroundStyle(Color.sh.textTertiary)
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
                Text(problem).foregroundStyle(Color.sh.failed)
            } else {
                ProgressView().progressViewStyle(.shSpinner).frame(maxWidth: .infinity)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.sh.bgWindow)
        .navigationTitle(system?.summary.info.title ?? namespace)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // What the host does with its systems for other devices (`design.systems.v1`), as
            // the Mac's SystemMenu offers it.
            if let summary = system?.summary, MobileDesigns.of(hosts).supports(host, RemoteProtocol.designSystemsCapability) {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("More", systemImage: "ellipsis") {
                        if !summary.builtIn {
                            if summary.info.spaceID != nil, !summary.info.sources.isEmpty {
                                Button("Re-sync", systemImage: "arrow.triangle.2.circlepath") { change(.resyncSystem(namespace: namespace)) }
                            }
                            Button("Rename…", systemImage: "pencil") {
                                title = summary.info.title
                                renaming = true
                            }
                        }
                        Button(summary.builtIn ? "Duplicate as a New System" : "Duplicate", systemImage: "plus.square.on.square") {
                            change(.duplicateSystem(namespace: namespace), open: true)
                        }
                        if !summary.builtIn {
                            Divider()
                            Button("Delete Design System…", systemImage: "trash", role: .destructive) { deleting = true }
                        }
                    }
                }
            }
        }
        .alert("Rename design system", isPresented: $renaming) {
            TextField("Title", text: $title)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { change(.renameSystem(namespace: namespace, title: title)) }
        }
        .confirmationDialog("Delete the design system “\(system?.summary.info.title ?? namespace)”?", isPresented: $deleting,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { change(.deleteSystem(namespace: namespace), gone: true) }
        } message: {
            Text("Designs drawn in it keep their copy, and the project it was read from isn’t touched.")
        }
        .task { await load() }
    }

    private func load() async {
        do {
            system = try await MobileDesigns.of(hosts).system(host: host, namespace: namespace)
            problem = nil
        } catch {
            problem = MobileDesignsError.words(error)
        }
    }

    /// A change on the host; then this page reads the system again, opens the copy, or goes back.
    private func change(_ request: RemoteDesignRequest, open: Bool = false, gone: Bool = false) {
        let designs = MobileDesigns.of(hosts)
        Task {
            do {
                let summary = try await designs.changeSystem(host: host, request)
                if gone {
                    dismiss()
                } else if open, let copy = summary {
                    navigator.open(.designs(.system(host: host, namespace: copy.namespace)))
                } else {
                    await load()
                }
            } catch {
                problem = MobileDesignsError.words(error)
            }
        }
    }
}
