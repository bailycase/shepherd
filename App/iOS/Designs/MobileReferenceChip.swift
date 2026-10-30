import SwiftUI
import UIKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

/// A design reference's chip on iOS (DesignRefStates' chip): a sent one above its message's words,
/// or one waiting beside the draft with its remove button. Its picture is the piece's board (else
/// the design's first board) drawn on this device from the host's files; `reference` names the
/// host's design as the host sees it.
struct MobileReferenceChip: View {
    let host: UUID
    let reference: DesignReference?
    let crumbs: [String]
    let version: String?
    var remove: (() -> Void)? = nil
    @Environment(MobileHosts.self) private var hosts
    @State private var image: UIImage?

    var body: some View {
        SHDesignReferenceChip(crumbs: crumbs, version: version,
                              thumbnail: image.map { SHReferenceImage(id: reference?.string ?? "", image: Image(uiImage: $0)) },
                              remove: remove)
            // As wide as what it says, so a sent one sits against the message's trailing edge.
            .fixedSize(horizontal: true, vertical: false)
            .task(id: reference?.string) { image = await picture() }
    }

    private func picture() async -> UIImage? {
        guard let reference, reference.host == .local, reference.page == nil else { return nil }
        let designs = MobileDesigns.of(hosts)
        let ref = HostDesignRef(host: host, design: reference.designID)
        guard let source = designs.source(ref), let index = await designs.sync(ref),
              let path = reference.board ?? index.snapshot.index.order.first,
              let board = index.snapshot.index.boards[path], let sha = index.snapshot.boards[path] else { return nil }
        return await DesignRendering.shared.image(ref, source: source, path: path, sha256: sha, size: CGSize(width: board.w, height: board.h),
                                                  width: SHReferenceMetrics.thumbnail.width)
    }
}
