import AppKit
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
@testable import ShepherdApp

/// What a drawn-state wait saw when it gave up, so a failure on a runner we cannot reach says whether the transcript drew nothing
/// (a blank scroll view) or drew something the test did not recognize (an accessibility shape that differs by OS). It reads only the
/// test's own synthetic fixture and is bounded; it changes no behavior and no expectation: the original wait still throws, with
/// this report appended to its message.
struct DiagnosedTimeout: Error, CustomStringConvertible {
    let what: String
    let report: String
    var description: String { "timed out waiting for \(what)\n\(report)" }
}

extension OffscreenWindow {
    /// Runs a wait; when it times out, rethrows with `report(...)` appended. `needles` are the words the wait looked for.
    @MainActor
    func diagnosing(stores: [NativeThreadStore], needles: [String], extra: () -> [String] = { [] },
                    _ wait: () async throws -> Void) async throws {
        do {
            try await wait()
        } catch let timeout as WaitTimeout {
            throw DiagnosedTimeout(what: timeout.what, report: report(stores: stores, needles: needles, extra: extra()))
        }
    }

    @MainActor
    func report(stores: [NativeThreadStore], needles: [String], extra: [String]) -> String {
        func clip(_ text: String?, _ limit: Int = 60) -> String {
            guard let text else { return "nil" }
            let line = text.replacingOccurrences(of: "\n", with: "\\n")
            return line.count > limit ? String(line.prefix(limit)) + "…" : line
        }
        let origin = window.frame.origin
        func box(_ rect: CGRect) -> String {
            "\(Int(rect.minX - origin.x)),\(Int(rect.minY - origin.y)) \(Int(rect.width))x\(Int(rect.height))"
        }
        var lines = ["DIAGNOSTIC (failure only, synthetic fixture)"]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        lines.append("os \(os.majorVersion).\(os.minorVersion) nativeTail(ThreadTailAnchor.isNative)=\(ThreadTailAnchor.isNative) window \(Int(window.frame.width))x\(Int(window.frame.height))")
        lines += extra
        for (index, store) in stores.enumerated() {
            lines.append("store\(index) running=\(store.running) rows=\(store.rows.count) messages=\(store.messages.count) pending=\(store.pending.count)")
            for row in store.rows.suffix(8) {
                let messages = row.turn.messages.map { "\($0.role)[\(clip($0.blocks.first?.text, 24))] op=\($0.operationID.map { String($0.uuidString.prefix(4)) } ?? "nil")" }
                lines.append("  row \(clip(row.id, 16)) user=\(row.isUser) live=\(row.live) messages=\(messages.joined(separator: " | "))")
            }
        }
        func scrolls(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] + $0.subviews.flatMap(scrolls) } ?? view.subviews.flatMap(scrolls)
        }
        let found = scrolls(host)
        lines.append("scroll views \(found.count)")
        for scroll in found.prefix(6) {
            let document = scroll.documentView?.frame.size ?? .zero
            lines.append("  scroll frame \(Int(scroll.frame.width))x\(Int(scroll.frame.height)) viewport \(Int(scroll.contentView.bounds.width))x\(Int(scroll.contentView.bounds.height)) offsetY \(Int(scroll.contentView.bounds.minY)) document \(Int(document.width))x\(Int(document.height))")
        }
        let nodes = elements()
        var roles: [String: Int] = [:]
        for node in nodes { roles[node.role ?? "nil", default: 0] += 1 }
        lines.append("ax nodes \(nodes.count) by role \(roles.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        func describe(_ node: AccessibilityNode) -> String {
            "\(node.role ?? "nil") label=\(clip(node.label)) value=\(clip(node.value)) frame \(box(node.frame))"
        }
        // Whether anything said the words, under any role, in label or value: the note's shape is what differs, not whether it is drawn.
        for needle in needles {
            let hits = nodes.filter { ($0.label ?? "").contains(needle) || ($0.value ?? "").contains(needle) }
            lines.append("needle \"\(needle)\" in \(hits.count) nodes")
            for hit in hits.prefix(6) { lines.append("  " + describe(hit)) }
        }
        lines.append("last \(min(80, nodes.count)) ax nodes")
        for node in nodes.suffix(80) { lines.append("  " + describe(node)) }
        return lines.joined(separator: "\n")
    }
}
