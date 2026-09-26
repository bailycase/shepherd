import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

/// New design on the phone, from Search's "New design" or the Designs screen's +. No board draws
/// it, so it is the least that makes one as the host's own New design does: the brief, the host
/// to make it on (only when several serve designs), and the design system to draw it in. A design
/// belongs to no project. The host makes the design and starts its agent with the brief; the
/// design then opens here.
struct NewDesignScreen: View {
    let brief: String
    let host: UUID?
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var picked: UUID?
    @State private var system: String?
    @State private var starting = false
    @State private var problem: String?
    @FocusState private var focused: Bool

    var body: some View {
        let designs = MobileDesigns.of(hosts)
        let serving = hosts.hosts.filter { designs.serving.contains($0.id) }
        let chosen = (picked ?? host).flatMap { id in serving.first { $0.id == id }?.id } ?? serving.first?.id
        let systems = chosen.flatMap { designs.library($0)?.listing?.systems } ?? []
        NavigationStack {
            Form {
                Section("Brief") {
                    TextField("A checkout funnel dashboard for the product team…", text: $text, axis: .vertical)
                        .lineLimit(3...8)
                        .focused($focused)
                }
                if serving.count > 1 {
                    Section("Host") {
                        Picker("Host", selection: Binding(get: { chosen }, set: { next in
                            // A system names one host's; another host starts with none.
                            if next != chosen { system = nil }
                            picked = next
                        })) {
                            ForEach(serving) { host in
                                Text(host.name).tag(Optional(host.id))
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
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

    private func start(_ host: UUID?) async {
        guard let host, let brief = RemoteDesignCreate.brief(text) else { return }
        starting = true
        defer { starting = false }
        do {
            let ref = try await MobileDesigns.of(hosts).create(host: host, brief: brief, system: system)
            dismiss()
            DesignsHooks.open(ref, navigator: navigator)
        } catch {
            problem = MobileDesignsError.words(error)
        }
    }
}
