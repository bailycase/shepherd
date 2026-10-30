import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

// A host's design changed from the phone or iPad, through its host's own mutations: Rename (its
// canvas title), Duplicate and Remove from Recents (`design.lifecycle.v1`), Delete with Undo
// (`design.delete.v1`). No board draws these: they are the Mac's DesignMenu as a native menu.

/// A design action that asks first.
enum DesignActionPrompt: Identifiable {
    case rename(HostDesignRef, name: String)
    case delete(HostDesignRef, name: String)

    var id: String {
        switch self {
        case .rename(let ref, _): "rename.\(ref.design.rawValue)"
        case .delete(let ref, _): "delete.\(ref.design.rawValue)"
        }
    }
}

/// The items of a design's menu: what its host does for this device.
struct DesignActionItems: View {
    let ref: HostDesignRef
    @Binding var prompt: DesignActionPrompt?
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        let designs = MobileDesigns.of(hosts)
        let name = designs.design(ref)?.name ?? "Design"
        let lifecycle = designs.supports(ref.host, RemoteProtocol.designLifecycleCapability)
        Button("Rename…", systemImage: "pencil") { prompt = .rename(ref, name: name) }
        if lifecycle {
            Button("Duplicate", systemImage: "plus.square.on.square") {
                Task {
                    do {
                        let copy = try await designs.duplicate(ref)
                        DesignsHooks.open(copy, navigator: navigator)
                    } catch {
                        designs.report("Couldn't duplicate \(name): \(MobileDesignsError.words(error))")
                    }
                }
            }
            Button("Remove from Recents", systemImage: "clock.badge.xmark") {
                Task {
                    do { try await designs.removeFromRecents(ref) } catch {
                        designs.report("Couldn't remove \(name) from Recents: \(MobileDesignsError.words(error))")
                    }
                }
            }
        }
        if designs.supports(ref.host, RemoteProtocol.designDeleteCapability) {
            Divider()
            Button("Delete Design…", systemImage: "trash", role: .destructive) { prompt = .delete(ref, name: name) }
        }
    }
}

/// Rename's field and Delete's confirmation for `prompt`; `deleted` runs once a design is gone
/// (a screen showing it goes back).
struct DesignActionPrompts: ViewModifier {
    @Binding var prompt: DesignActionPrompt?
    var deleted: () -> Void = {}
    @Environment(MobileHosts.self) private var hosts
    @State private var name = ""

    func body(content: Content) -> some View {
        let designs = MobileDesigns.of(hosts)
        content
            .alert("Rename design", isPresented: renaming, presenting: prompt) { prompt in
                TextField("Name", text: $name)
                Button("Cancel", role: .cancel) {}
                Button("Rename") {
                    guard case .rename(let ref, let old) = prompt else { return }
                    let next = name
                    Task {
                        do { try await designs.rename(ref, to: next) } catch {
                            designs.report("Couldn't rename \(old): \(MobileDesignsError.words(error))")
                        }
                    }
                }
            }
            .confirmationDialog(deleteTitle, isPresented: deleting, titleVisibility: .visible, presenting: prompt) { prompt in
                Button("Delete", role: .destructive) {
                    guard case .delete(let ref, let old) = prompt else { return }
                    Task {
                        do {
                            try await designs.deleteWithUndo(ref, name: old)
                            deleted()
                        } catch {
                            designs.report("Couldn't delete \(old): \(MobileDesignsError.words(error))")
                        }
                    }
                }
            } message: { _ in
                Text("Its boards, versions, comments and its agent’s chat go from its host. You can undo right after.")
            }
            .onChange(of: prompt?.id) {
                if case .rename(_, let old) = prompt { name = old }
            }
    }

    private var renaming: Binding<Bool> {
        Binding(get: { if case .rename = prompt { true } else { false } }, set: { if !$0 { prompt = nil } })
    }

    private var deleting: Binding<Bool> {
        Binding(get: { if case .delete = prompt { true } else { false } }, set: { if !$0 { prompt = nil } })
    }

    private var deleteTitle: String {
        if case .delete(_, let name) = prompt { "Delete “\(name)”?" } else { "Delete design?" }
    }
}

/// Undo after a deletion, and why the last design action failed, over the Designs screen.
struct DesignActionBanners: View {
    @Environment(MobileHosts.self) private var hosts

    var body: some View {
        let designs = MobileDesigns.of(hosts)
        if let problem = designs.problem {
            SHBanner(.failed, title: problem) {
                Button("OK") { designs.report(nil) }.buttonStyle(.sh(.secondary))
            }
        }
        if let deleted = designs.deleted {
            SHBanner(.idle, title: "Deleted \(deleted.name).", message: "Undo brings it back on \(hosts.host(deleted.ref.host)?.name ?? "its host").",
                     systemImage: "trash") {
                Button("Undo") { Task { await designs.undoLastDelete() } }.buttonStyle(.sh(.secondary))
            }
        }
    }
}
