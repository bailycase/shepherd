import Foundation
import ShepherdCore
import ShepherdProtocol

/// The words of design references in a thread and on the canvas (DesignRefStates), shared by
/// the Mac and the iOS client: what a send will carry, what the chip's preview says the agent
/// gets, and which design_get calls one "Looked at…" line stands for.
public enum DesignReferencePresentation {
    /// The Implement sheet's footer: "Sends a picture, its HTML, 11 styles and 8 tokens from
    /// acme-web." (an element), "…the board’s HTML, 42 styles…" (a board), "Sends a picture and the
    /// HTML of each of its 4 boards…" (a whole design; "of its first 12 of 40 boards" past the cap).
    public static func sends(_ outline: DesignReferenceOutline) -> String {
        let counts = [count(outline.styles, "style"), count(outline.tokens, "token")]
        let from = outline.system.map { " from \($0)" } ?? ""
        switch outline.kind {
        case .element:
            return "Sends a picture, its HTML, " + list(counts) + from + "."
        case .board:
            return "Sends a picture, the board’s HTML, " + list(counts) + from + "."
        case .design:
            let held = outline.boards ?? 0, total = outline.boardCount ?? held
            let boards = total > held ? "its first \(held) of \(total) boards" : "its \(count(held, "board"))"
            return "Sends a picture and the HTML of each of \(boards), " + list(counts) + from + "."
        }
    }

    /// The preview's "The agent gets" row: picture, html, 11 styles, 8 tokens.
    public static func gets(_ outline: DesignReferenceOutline) -> [String] {
        ["picture", "html", count(outline.styles, "style"), count(outline.tokens, "token")]
    }

    /// The chip's version: "v23".
    public static func version(_ revision: UInt64?) -> String? {
        revision.map { "v\($0)" }
    }

    /// The chip's state line: "updated since · now v26", "design deleted · the copy sent here is
    /// kept", "offline · uses the copy from Sep 26"; nil while it is current.
    public static func state(_ freshness: DesignReferenceFreshness, formatDate: (Date) -> String = day) -> String? {
        switch freshness {
        case .current: nil
        case .updatedSince(let latest, _): "updated since · now v\(latest)"
        case .deleted: "design deleted · the copy sent here is kept"
        case .hostOffline(let cachedAt): "offline · uses the copy from \(formatDate(Date(timeIntervalSince1970: cachedAt / 1000)))"
        }
    }

    /// "Send v26", for a reference the design has moved on from.
    public static func sendLatest(_ freshness: DesignReferenceFreshness) -> String? {
        guard case .updatedSince(let latest, _) = freshness else { return nil }
        return "Send v\(latest)"
    }

    /// The toast after a send that stays on the canvas: "Sent card “Checkout funnel” to Checkout
    /// page polish."
    public static func sent(_ piece: String, to thread: String) -> String {
        "Sent \(piece) to \(thread)."
    }

    /// The toast after Copy reference.
    public static func copied(_ piece: String) -> String {
        "Copied a reference to \(piece). Paste it into any thread’s composer."
    }

    /// The piece a menu or toast names: the element's name and words, else the board's title,
    /// else the design's name.
    public static func piece(_ prepared: (kind: DesignReference.Kind, design: String, board: String?, element: String?)) -> String {
        switch prepared.kind {
        case .element: prepared.element ?? prepared.board ?? prepared.design
        case .board: prepared.board ?? prepared.design
        case .design: prepared.design
        }
    }

    public static func day(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }

    static func count(_ value: Int, _ noun: String) -> String {
        "\(value) \(noun)\(value == 1 ? "" : "s")"
    }

    static func list(_ parts: [String]) -> String {
        guard parts.count > 1 else { return parts.first ?? "" }
        return parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
    }
}

/// A run of design_get calls on one reference, which the thread draws as one "Looked at…" line.
public struct DesignReferenceCall: Hashable, Sendable {
    public var ref: String
    public var aspects: Set<DesignReferenceAspect>
    /// The tool rows it stands for, in order.
    public var entryIDs: [String]

    /// The design_get rows among `messages`, consecutive calls on the same ref joined. A call is
    /// read from its arguments (`{"ref": …, "what": …}`); one whose arguments don't read is left out.
    public static func calls(in messages: [NativeThreadMessage]) -> [DesignReferenceCall] {
        var out: [DesignReferenceCall] = []
        var previousWasCall = false
        for message in messages {
            guard message.toolName == "design_get", let arguments = message.argumentsText,
                  let object = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any],
                  let ref = object["ref"] as? String, let what = (object["what"] as? String).flatMap(DesignReferenceAspect.init) else {
                if message.role != "toolResult" || message.toolName != nil { previousWasCall = false }
                continue
            }
            if previousWasCall, let last = out.last, last.ref == ref {
                out[out.count - 1].aspects.insert(what)
                out[out.count - 1].entryIDs.append(message.entryID)
            } else {
                out.append(DesignReferenceCall(ref: ref, aspects: [what], entryIDs: [message.entryID]))
            }
            previousWasCall = true
        }
        return out
    }
}
