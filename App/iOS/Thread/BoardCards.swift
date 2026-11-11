import SwiftUI
import UIKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

/// A board the agent showed with design_show or wrote with board_write or board_edit (ThreadBoardShown, ThreadBoardStale,
/// ThreadBoardEdited), or drew for you to add (ThreadBoardDraft, ThreadBoardChange): the copy the host kept, read over
/// `designReferencesCapability` and drawn as the Mac draws it (`BoardCardView`). The picture opens full size; Discard and
/// Add to design settle a drawn one; Open in design goes to the board. A host that can't serve the copy leaves the line.
struct MobileBoardCard<Fallback: View>: View {
    let thread: AgentRef
    let id: UUID
    @ViewBuilder let fallback: () -> Fallback
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator
    @State private var kept: Kept?
    @State private var busy = false
    @State private var failure: String?
    @State private var viewing = false

    struct Kept {
        var payload: DesignReferencePayload
        var freshness: DesignReferenceFreshness
        var image: UIImage?
    }

    var body: some View {
        if let kept {
            card(kept)
        } else {
            fallback().task(id: id) { await load() }
        }
    }

    private func card(_ kept: Kept) -> some View {
        let payload = kept.payload
        // A board the agent drew isn't on the canvas to be compared with.
        let standing = payload.proposal == nil ? kept.freshness : .current
        let file = payload.picture ?? payload.boards?.first?.picture
        let title = payload.reference.board.map { payload.boardTitle ?? $0.stem }
            ?? payload.boards?.first.map { $0.title ?? $0.board.stem } ?? payload.design
        let note = payload.proposal.map { DesignReferencePresentation.boardNote($0, revision: payload.revision) }
            ?? DesignReferencePresentation.boardNote(standing)
        return VStack(alignment: .leading, spacing: MobileLayout.activitySpacing) {
            if let line = DesignReferencePresentation.boardLine(payload) {
                SHActivityLine(kind: .drew, label: line.label, meta: line.meta, status: .done)
            }
            SHBoardCard(design: payload.design, board: title, meta: DesignReferencePresentation.boardMeta(payload, freshness: standing),
                        note: failure ?? note, size: Self.size(payload, file: file),
                        picture: kept.image.map { .picture(Image(uiImage: $0)) } ?? (file == nil ? .missing : .loading),
                        open: kept.image == nil ? nil : { viewing = true }) {
                actions(payload)
            }
        }
        .fullScreenCover(isPresented: $viewing) {
            if let image = kept.image {
                SHImageViewer(name: title, facts: "\(Int(image.size.width * image.scale)) × \(Int(image.size.height * image.scale)) · PNG",
                              content: .picture(Image(uiImage: image)), caption: ([payload.design] + DesignReferencePresentation.boardMeta(payload, freshness: standing).suffix(1)).joined(separator: " · "),
                              copy: { UIPasteboard.general.image = image },
                              pixels: CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale),
                              close: { viewing = false })
            }
        }
    }

    @ViewBuilder private func actions(_ payload: DesignReferencePayload) -> some View {
        if let proposal = payload.proposal {
            if proposal.state == .pending {
                SHBoardBadge(proposal.kind == .draft ? "Draft" : "Changed")
                Button("Discard") { settle(false) }
                    .buttonStyle(.sh(.ghost, size: .s))
                    .disabled(busy)
                Button(proposal.kind == .draft ? "Add to design" : "Apply to design") { settle(true) }
                    .buttonStyle(.sh(.strong, size: .s))
                    .disabled(busy)
            } else if proposal.state == .added {
                openButton(payload)
            }
        } else {
            openButton(payload)
        }
    }

    private func openButton(_ payload: DesignReferencePayload) -> some View {
        Button("Open in design") { open(payload.reference) }
            .buttonStyle(.sh(.ghost, size: .s))
    }

    /// The board as it is now, in the design screen of this layout: its board full screen on a phone, its canvas on iPad.
    private func open(_ reference: DesignReference) {
        guard reference.host == .local else { return }
        switch navigator.layout {
        case .pad: PadDesignHooks.open(PadDesignRef(host: thread.host, design: reference.designID), navigator: navigator)
        case .phone:
            let ref = HostDesignRef(host: thread.host, design: reference.designID)
            navigator.open(reference.board.map { .designs(.board(ref, path: $0.rawValue)) } ?? .designs(.design(ref)))
        }
    }

    private static func size(_ payload: DesignReferencePayload, file: DesignReferencePayload.File?) -> CGSize? {
        if let width = file?.pixelWidth, let height = file?.pixelHeight { return CGSize(width: CGFloat(width) / 2, height: CGFloat(height) / 2) }
        if let width = payload.width, let height = payload.height { return CGSize(width: width, height: height) }
        return nil
    }

    private var library: RemoteDesignLibrary? { MobileDesigns.of(hosts).library(thread.host) }

    /// The host's copy and how it stands, then its picture (in pieces when it is too large for one reply).
    private func load() async {
        guard let library, case .referenceKept(let payload, let bytes, let freshness)? =
                try? await library.request(.referenceKept(agentID: thread.agent, payloadID: id)) else { return }
        kept = Kept(payload: payload, freshness: freshness, image: nil)
        var data = bytes
        if data == nil, payload.picture != nil || payload.boards?.first?.picture != nil {
            data = try? await library.referencePicture(agentID: thread.agent, payloadID: id)
        }
        if let data, let image = UIImage(data: data, scale: 2) { kept?.image = image }
    }

    private func settle(_ accept: Bool) {
        guard let library, !busy else { return }
        busy = true
        Task {
            do {
                guard case .referenceKept(let payload, _, _) = try await library.request(
                    .settleBoardProposal(agentID: thread.agent, payloadID: id, accept: accept)) else { throw MobileBoardCardError() }
                kept?.payload = payload
                failure = nil
            } catch {
                failure = MobileDesignsError.words(error)
            }
            busy = false
        }
    }
}

private struct MobileBoardCardError: Error {}
