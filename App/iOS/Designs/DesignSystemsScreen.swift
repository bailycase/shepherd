import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

/// Settings ▸ Design systems (MobileMore's row, now in Settings): the hosts' systems, each opening its page.
struct DesignSystemsScreen: View {
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator
    @State private var problem: String?
    @State private var deleting: (host: UUID, build: Design)?

    var body: some View {
        let designs = MobileDesigns.of(hosts)
        ScrollView {
            VStack(alignment: .leading, spacing: MobileLayout.headerSpacing) {
                if let problem {
                    SHBanner(.failed, title: problem) { Button("OK") { self.problem = nil }.buttonStyle(.sh(.secondary)) }
                }
                // Builds still reading their space: each opens its agent's thread; a long press deletes it there.
                let builds = designs.builds
                if !builds.isEmpty {
                    SHListHeader("Building", count: nil)
                    SHListCard {
                        ForEach(builds, id: \.build.id) { item in
                            Button {
                                if let agent = designs.buildAgent(host: item.host, build: item.build.id) { navigator.open(.thread(agent)) }
                            } label: {
                                SHDesignSystemRow(name: item.build.name, source: [item.space.map { "\($0) · building" } ?? "building", item.hostName]
                                    .joined(separator: " · "))
                            }
                            .buttonStyle(.shRow(radius: 0))
                            .contextMenu {
                                if designs.supports(item.host, RemoteProtocol.designSystemsCapability) {
                                    Button("Delete Design System…", systemImage: "trash", role: .destructive) { deleting = (item.host, item.build) }
                                }
                            }
                        }
                    }
                    SHListHeader("Design systems", count: nil)
                }
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
        .confirmationDialog("Delete “\(deleting?.build.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Stop and delete", role: .destructive) {
                guard let target = deleting else { return }
                Task {
                    do { try await designs.changeSystem(host: target.host, .deleteSystemBuild(designID: target.build.id)) } catch {
                        problem = "Couldn't delete \(target.build.name): \(MobileDesignsError.words(error))"
                    }
                }
            }
        } message: {
            Text("It’s still being built. Deleting stops the build and keeps nothing from it.")
        }
        .toolbar {
            // "Build one from a repo" in a host's space (`design.systems.v1`): its build agent's thread opens.
            let buildable = designs.buildableSpaces
            if !buildable.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("Build from a space", systemImage: "plus") {
                        ForEach(buildable, id: \.host) { host in
                            Section(host.name) {
                                ForEach(host.spaces) { space in
                                    Button(space.name) { build(host: host.host, space: space.id) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func build(host: UUID, space: SpaceID) {
        let designs = MobileDesigns.of(hosts)
        Task {
            do {
                if let agent = try await designs.buildSystem(host: host, space: space) { navigator.open(.thread(agent)) }
            } catch {
                problem = "Couldn't start the build: \(MobileDesignsError.words(error))"
            }
        }
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
        .task(id: MobileDesigns.of(hosts).systemsRevision) { await load() }
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
