import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

/// New design on the phone, from Search's "New design" or the Designs screen's +. No board draws
/// it, so it is the least that makes one as the host's own New design does: the brief, the
/// project it belongs to (a host's spaces), and the design system to draw it in. The host makes
/// the design and starts its agent with the brief; the design then opens here.
struct NewDesignScreen: View {
    let brief: String
    let host: UUID?
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var place: Place?
    @State private var system: String?
    @State private var starting = false
    @State private var problem: String?
    @FocusState private var focused: Bool

    /// A project on a host that serves designs.
    struct Place: Hashable {
        var host: UUID
        var space: SpaceID
    }

    var body: some View {
        let designs = MobileDesigns.of(hosts)
        let places = Self.places(hosts, serving: designs.serving)
        let chosen = place ?? places.first(where: { host == nil || $0.place.host == host })?.place
        let systems = chosen.flatMap { designs.library($0.host)?.listing?.systems } ?? []
        NavigationStack {
            Form {
                Section("Brief") {
                    TextField("A checkout funnel dashboard for the product team…", text: $text, axis: .vertical)
                        .lineLimit(3...8)
                        .focused($focused)
                }
                Section("Project") {
                    Picker("Project", selection: Binding(get: { chosen }, set: { next in
                        // A system names one host's; another host's project starts with none.
                        if next?.host != chosen?.host { system = nil }
                        place = next
                    })) {
                        ForEach(places, id: \.place) { entry in
                            Text(entry.title).tag(Optional(entry.place))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section("Design system") {
                    Picker("Design system", selection: $system) {
                        Text("None").tag(String?.none)
                        ForEach(systems, id: \.namespace) { summary in
                            Text(summary.info.title).tag(Optional(summary.namespace))
                        }
                    }
                }
                if let problem {
                    Section { Text(problem).foregroundStyle(Color.nw.failed) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.nw.bgWindow)
            .navigationTitle("New design")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") { Task { await start(chosen) } }
                        .disabled(starting || chosen == nil || RemoteDesignCreate.brief(text) == nil)
                }
            }
        }
        .onAppear {
            if text.isEmpty { text = brief }
            focused = brief.isEmpty
        }
    }

    private func start(_ place: Place?) async {
        guard let place, let brief = RemoteDesignCreate.brief(text) else { return }
        starting = true
        defer { starting = false }
        do {
            let ref = try await MobileDesigns.of(hosts).create(host: place.host, brief: brief, spaceID: place.space, system: system)
            dismiss()
            DesignsHooks.open(ref, navigator: navigator)
        } catch {
            problem = MobileDesignsError.words(error)
        }
    }

    /// Every visible project on the hosts that serve designs, named with its host where several do.
    static func places(_ hosts: MobileHosts, serving: Set<UUID>) -> [(place: Place, title: String)] {
        let serving = hosts.hosts.filter { serving.contains($0.id) }
        return serving.flatMap { host in
            host.state.spaces.filter { !$0.hidden }.map { space in
                (Place(host: host.id, space: space.id), serving.count > 1 ? "\(space.name) · \(host.name)" : space.name)
            }
        }
    }
}
