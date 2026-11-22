import AppKit
import ShepherdUI
import SwiftUI

/// Only the boundary row has a native marker. A prepend keeps its measured viewport offset,
/// not a lazy stack's estimated content-height delta or an ID's forced top alignment.
@MainActor @Observable
final class ThreadHistoryAnchor {
    private(set) var rowID: String?
    /// A page is loading or being restored. Read it from actions and AppKit callbacks only: in a body it would observe `rowID`.
    var isEngaged: Bool { rowID != nil }
    @ObservationIgnored var animating = false
    // Keep the target through lazy row replacement; a one-shot proxy request can be dropped.
    var position = ScrollPosition(idType: String.self)
    // Old probes can update after the new boundary attaches. Resolve by row, not update order.
    @ObservationIgnored private let markers = NSMapTable<NSString, Marker>(keyOptions: .strongMemory, valueOptions: .weakMemory)
    private var marker: Marker? { rowID.flatMap { markers.object(forKey: $0 as NSString) } }
    @ObservationIgnored private weak var scroll: NSScrollView?
    @ObservationIgnored private var savedTop: CGFloat?
    @ObservationIgnored private var restoring = false
    @ObservationIgnored private var waiting = false
    @ObservationIgnored private var pendingMaterialization: ((String) -> Void)?
    @ObservationIgnored private var session: String?
    @ObservationIgnored private var generation = 0

    #if DEBUG
    @ObservationIgnored private var prepend: (delta: CGFloat, oldDocumentHeight: CGFloat)?
    @ObservationIgnored private(set) var correctingPrepend = false
    var hasPrepend: Bool { prepend != nil || correctingPrepend }

    func preparePrepend(before firstID: String, delta: CGFloat) {
        guard firstID == rowID, prepend == nil, let scroll, delta > 0 else { return }
        prepend = (delta, scroll.contentView.documentRect.height)
    }

    func correctPrepend(in scroll: NSScrollView?, pass: String) -> Bool {
        guard let prepend, let scroll, self.scroll === scroll else { return false }
        let clip = scroll.contentView
        let height = clip.documentRect.height
        let origin = clip.bounds.minY
        let target = clip.bounds.offsetBy(dx: 0, dy: prepend.delta)
        SHRenderProbe.scrollEvent("probe.prepend.pass", "\(pass) document=\(height) clip=\(origin)",
                                  from: scroll, target: rowID, kind: "layout")
        // A stack callback can arrive before the scroll view can accommodate the new origin.
        guard height > prepend.oldDocumentHeight, abs(clip.constrainBoundsRect(target).minY - target.minY) <= 1 else { return false }
        self.prepend = nil
        guard MacScrollValidationTrace.current?.physicalScrollerHeld != true else { return false }
        correctingPrepend = true
        defer { correctingPrepend = false }
        Self.correct(prepend.delta, in: scroll, rowID: rowID)
        SHRenderProbe.scrollEvent("probe.prepend.result",
                                  "\(pass) delta=\(prepend.delta) clip=\(origin)->\(clip.bounds.minY)",
                                  from: scroll, target: rowID, kind: "layout")
        return true
    }
    #endif

    func begin(_ id: String?, session: String?, measuredScroll: NSScrollView? = nil) -> Int {
        cancel()
        guard let id else { return generation }
        self.session = session
        waiting = true
        rowID = id
        scroll = measuredScroll ?? marker?.enclosingScrollView
        if marker?.rowID == id { savedTop = marker?.viewportTop }
        return generation
    }

    func cancel() {
        if rowID != nil {
            ThreadScrollTrace.write("thread.write.M5", "history.cancel", in: scroll, target: rowID)
            position = ScrollPosition(idType: String.self)
        }
        generation &+= 1
        savedTop = nil
        scroll = nil
        restoring = false
        waiting = false
        pendingMaterialization = nil
        #if DEBUG
        prepend = nil
        #endif
        rowID = nil
    }

    func finished(_ token: Int, firstID: String?) {
        guard token == generation, let rowID else { return }
        guard let firstID, firstID != rowID else {
            // A refused/empty page did not prepend anything.
            cancel()
            return
        }
        #if DEBUG
        if ThreadScrollValidation.measuredHistory {
            waiting = false
            return
        }
        #endif
        // SwiftUI can observe the prepend before this awaiting task resumes. Do not replace
        // the saved offset with a position already shifted by the new rows in that ordering.
        let pending = pendingMaterialization
        pendingMaterialization = nil
        if pending == nil, marker?.rowID == rowID, let top = marker?.viewportTop { savedTop = top }
        waiting = false
        if let pending { prepended(firstID: firstID, session: session, active: true, materialize: pending) }
    }

    func prepended(firstID: String?, session: String?, active: Bool, materialize: @escaping (String) -> Void) {
        guard active, session == self.session else { cancel(); return }
        #if DEBUG
        if ThreadScrollValidation.measuredHistory { return }
        #endif
        guard !restoring, let rowID, savedTop != nil, firstID != rowID else { return }
        if waiting {
            pendingMaterialization = materialize
            return
        }
        restoring = true
        let token = generation
        // The first-ID change arrives before the lazy stack commits its new scroll targets.
        // Materializing in that callback can target the removed view instead of the new row.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == token, self.restoring, self.rowID == rowID else { return }
            // A queue turn alone need not commit the new targets; the old marker can be detached.
            self.scroll?.window?.contentView?.layoutSubtreeIfNeeded()
            guard self.generation == token, self.restoring, self.rowID == rowID else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { materialize(rowID) }
            self.scheduleCorrection()
        }
    }

    private func scheduleCorrection() {
        guard restoring else { return }
        let token = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == token, self.restoring,
                  let marker = self.marker, marker.rowID == self.rowID,
                  let scroll = marker.enclosingScrollView, let savedTop = self.savedTop else { return }
            // SwiftUI can materialize the row before its final AppKit layout is committed.
            // Measuring then would apply a correction to a stale marker position.
            scroll.window?.contentView?.layoutSubtreeIfNeeded()
            guard self.generation == token, self.restoring, self.marker === marker,
                  let top = marker.viewportTop else { return }
            let delta = top - savedTop
            guard abs(delta) > 0.25 else { return }
            Self.correct(delta, in: scroll, rowID: self.rowID)
        }
    }

    static func correct(_ delta: CGFloat, in scroll: NSScrollView, rowID: String?,
                        actor: StaticString = "thread.write.M6", caller: String = "history.correct") {
        let clip = scroll.contentView
        var bounds = clip.bounds
        bounds.origin.y += delta
        ThreadScrollTrace.write(actor, caller, in: scroll, target: rowID)
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        scroll.reflectScrolledClipView(clip)
    }

    /// Keep correcting only this anchor through lazy remeasurement, until the reader moves,
    /// sends, switches session or hides the thread. Geometry bookkeeping never invalidates rows.
    /// `ThreadView` calls it from its scroll observer while engaged.
    func moved() {
        SHRenderProbe.tick("thread.historyMove")
        // Lazy row replacement can temporarily detach the marker. Keep the last real offset.
        if waiting, pendingMaterialization == nil, marker?.rowID == rowID, let top = marker?.viewportTop {
            savedTop = top
        }
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
            anchor.markers.setObject(self, forKey: rowID as NSString)
            if anchor.isEngaged { anchor.moved() }
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
            if let anchor, anchor.isEngaged { anchor.moved() }
        }
    }
}
