import SwiftUI
import UIKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

// Handing a host's design piece to one of that host's threads from the phone or iPad
// (`design.references.v1`): Implement in a Thread… and Copy Reference, as the Mac's canvas offers
// them (RefImplementSheet, RefCopied). No iOS board draws these: the sheet is the Mac sheet's
// parts as a native form. The host pins, keeps and fences the piece; this device only names it.

/// The piece the board screen hands over: the element picked (Comment's or Tweak's), else the
/// board on screen.
struct DesignReferencePick: Equatable {
    var ref: HostDesignRef
    var reference: DesignReference
    /// "card “Checkout funnel”", or the board's label.
    var piece: String
}

/// Implement in a Thread…: the piece pinned as the sheet opens, one of the host's threads, an
/// optional message, and whether the thread opens after sending (remembered for the session).
@MainActor @Observable
final class DesignImplementModel: Identifiable {
    let pick: DesignReferencePick
    let threads: [Agent]
    var thread: AgentID?
    var message = ""
    var opensThread = DesignImplementModel.lastOpensThread
    private(set) var pin: RemoteDesignReferencePin?
    private(set) var sending = false
    var error: String?

    static var lastOpensThread = true

    init(pick: DesignReferencePick, threads: [Agent]) {
        self.pick = pick
        self.threads = threads
        thread = threads.first?.id
    }

    var canSend: Bool { pin != nil && thread != nil && !sending }

    func prepare(_ designs: MobileDesigns) async {
        do {
            pin = try await designs.pinReference(host: pick.ref.host, pick.reference)
        } catch {
            self.error = MobileDesignsError.words(error)
        }
    }

    /// Sends the piece with the message; answers the thread when it went.
    func send(_ designs: MobileDesigns) async -> AgentRef? {
        guard let pin, let thread else { return nil }
        sending = true
        error = nil
        defer { sending = false }
        DesignImplementModel.lastOpensThread = opensThread
        let target = AgentRef(host: pick.ref.host, agent: thread)
        do {
            try await designs.sendReferences([NativeAttachedReference(reference: pin.reference, label: pin.label ?? pick.piece, outline: pin.outline)],
                                             text: message.trimmingCharacters(in: .whitespacesAndNewlines), to: target)
            return target
        } catch {
            self.error = MobileDesignsError.words(error)
            return nil
        }
    }
}

struct DesignImplementSheet: View {
    @Bindable var model: DesignImplementModel
    /// The thread it went to, after sending.
    let sent: (AgentRef, Bool) -> Void
    @Environment(MobileHosts.self) private var hosts
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let designs = MobileDesigns.of(hosts)
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: SH.Space.xs) {
                        Text("Implement \(model.pick.piece)").font(.sh(.headline)).foregroundStyle(Color.sh.textPrimary)
                        HStack(spacing: SH.Space.s) {
                            Text(designs.design(model.pick.ref)?.name ?? "Design").shText(.caption).foregroundStyle(Color.sh.textSecondary)
                            if let version = DesignReferencePresentation.version(model.pin?.reference.revision) {
                                Text(version).font(.sh(.mono)).foregroundStyle(Color.sh.textTertiary)
                            }
                        }
                    }
                }
                Section("Thread on \(hosts.host(model.pick.ref.host)?.name ?? "the host")") {
                    if model.threads.isEmpty {
                        Text("No threads there yet. Start one on the host.").foregroundStyle(Color.sh.textTertiary)
                    } else {
                        Picker("Thread", selection: $model.thread) {
                            ForEach(model.threads) { agent in
                                Text(agent.name).tag(Optional(agent.id))
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                }
                Section {
                    TextField("Anything the agent should know (optional)", text: $model.message, axis: .vertical)
                        .lineLimit(2...6)
                    Toggle("Open the thread after sending", isOn: $model.opensThread)
                } header: {
                    Text("Message")
                } footer: {
                    if let pin = model.pin { Text(DesignReferencePresentation.sends(pin.outline)) }
                }
                if let error = model.error {
                    Section { Text(error).foregroundStyle(Color.sh.failed) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.sh.bgWindow)
            .navigationTitle("Implement in a Thread")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        Task {
                            if let target = await model.send(designs) {
                                dismiss()
                                sent(target, model.opensThread)
                            }
                        }
                    }
                    .disabled(!model.canSend)
                }
            }
            .disabled(model.sending)
        }
        .task { await model.prepare(designs) }
    }
}

extension MobileDesigns {
    /// Copy Reference: the piece pinned by the host, its string (naming the host as this device
    /// knows it) on the pasteboard. Answers the toast's words.
    func copyReference(_ pick: DesignReferencePick) async throws -> String {
        let pin = try await pinReference(host: pick.ref.host, pick.reference)
        UIPasteboard.general.string = pin.reference.fromHost(pick.ref.host).string
        return DesignReferencePresentation.copied(pick.piece)
    }
}
