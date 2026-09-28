import AppKit
import SwiftUI

/// Only the boundary row has a native marker. A prepend keeps its measured viewport offset,
/// not a lazy stack's estimated content-height delta or an ID's forced top alignment.
@MainActor @Observable
final class ThreadHistoryAnchor {
    private(set) var rowID: String?
    @ObservationIgnored private weak var marker: Marker?
    @ObservationIgnored private var savedTop: CGFloat?
    @ObservationIgnored private var restoring = false
    @ObservationIgnored private var waiting = false
    @ObservationIgnored private var session: String?
    @ObservationIgnored private var generation = 0

    func begin(_ id: String?, session: String?) -> Int {
        cancel()
        guard let id else { return generation }
        self.session = session
        waiting = true
        rowID = id
        if marker?.rowID == id { savedTop = marker?.viewportTop }
        return generation
    }

    func cancel() {
        generation &+= 1
        savedTop = nil
        restoring = false
        waiting = false
        rowID = nil
    }

    func finished(_ token: Int, firstID: String?) {
        guard token == generation, let rowID else { return }
        guard let firstID, firstID != rowID else {
            // A refused/empty page did not prepend anything.
            cancel()
            return
        }
        // loadOlder commits and returns on the main actor, before SwiftUI lays out the new
        // rows. A turn-jump animation may have finished while the reply was pending.
        if marker?.rowID == rowID, let top = marker?.viewportTop { savedTop = top }
        waiting = false
    }

    func prepended(firstID: String?, session: String?, active: Bool, materialize: (String) -> Void) {
        guard active, session == self.session else { cancel(); return }
        guard !waiting, !restoring, let rowID, savedTop != nil, firstID != rowID else { return }
        restoring = true
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { materialize(rowID) }
        scheduleCorrection()
    }

    private func scheduleCorrection() {
        guard restoring else { return }
        let token = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == token, self.restoring,
                  let marker = self.marker, marker.rowID == self.rowID,
                  let scroll = marker.enclosingScrollView, let top = marker.viewportTop,
                  let savedTop = self.savedTop else { return }
            let delta = top - savedTop
            guard abs(delta) > 0.25 else { return }
            let clip = scroll.contentView
            var bounds = clip.bounds
            bounds.origin.y += delta
            clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
            scroll.reflectScrolledClipView(clip)
        }
    }

    /// Keep correcting only this anchor through lazy remeasurement, until the reader moves,
    /// sends, switches session or hides the thread. Geometry bookkeeping never invalidates rows.
    func moved() {
        if waiting, marker?.rowID == rowID { savedTop = marker?.viewportTop }
        scheduleCorrection()
    }

    struct Probe: NSViewRepresentable {
        let anchor: ThreadHistoryAnchor
        let rowID: String

        func makeNSView(context: Context) -> Marker { Marker() }
        func updateNSView(_ view: Marker, context: Context) {
            view.attach(to: anchor, rowID: rowID)
        }
    }

    final class Marker: NSView {
        weak var anchor: ThreadHistoryAnchor?
        var rowID = ""

        func attach(to anchor: ThreadHistoryAnchor, rowID: String) {
            self.anchor = anchor
            self.rowID = rowID
            anchor.marker = self
            anchor.moved()
        }

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        var viewportTop: CGFloat? {
            guard let scroll = enclosingScrollView, window != nil else { return nil }
            let clip = scroll.contentView
            return convert(bounds, to: clip).minY - clip.bounds.minY
        }

        override func layout() {
            super.layout()
            anchor?.moved()
        }
    }
}
