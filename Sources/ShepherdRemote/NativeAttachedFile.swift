import Foundation
import ShepherdProtocol

/// A file waiting in a composer beside the draft (a design's boards attached to a thread): its
/// chip's name and where it is on the host. pi reads it from there; the message it goes with
/// lists where each one is under the words.
public struct NativeAttachedFile: Identifiable, Hashable, Sendable {
    public let id: UUID
    /// What its chip says ("A.html").
    public let name: String
    /// Its absolute path on the host that runs the agent.
    public let path: String

    public init(id: UUID = UUID(), name: String, path: String) {
        self.id = id
        self.name = name
        self.path = path
    }

    /// The message that goes: the words, the line saying how many design references go with it
    /// (their records reach pi fenced ahead of the message, never in it), then the attached
    /// files' paths.
    /// Browser elements add no line of their own, except to a message with nothing else in it
    /// (`BrowserElementFence.humanLine`), so it isn't empty.
    public static func message(_ text: String, files: [NativeAttachedFile], references: Int = 0, elements: Int = 0) -> String {
        guard !files.isEmpty || references > 0 || elements > 0 else { return text }
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts = words.isEmpty ? [] : [text]
        if references > 0 { parts.append(DesignReferenceFence.humanLine(count: references)) }
        if !files.isEmpty { parts.append((["Attached files:"] + files.map { "- \($0.path)" }).joined(separator: "\n")) }
        if parts.isEmpty, elements > 0 { parts.append(BrowserElementFence.humanLine(count: elements)) }
        return parts.joined(separator: "\n\n")
    }
}

/// An element picked in the thread's Browser, waiting in the composer beside the draft
/// (docs/design/side-pane-changes.md › Side pane › Browser): its chip, and the element the host fences for pi.
public struct NativeAttachedElement: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let element: BrowserElement

    public init(id: UUID = UUID(), element: BrowserElement) {
        self.id = id
        self.element = element
    }
}

/// A design reference waiting in a composer beside the draft (docs/designs.md › Design
/// references): the piece, pinned at the revision it was picked at, its chip's label, and what
/// it will send (`outline`, the Implement sheet's footer). Sent, the host resolves the piece at
/// that revision, keeps the copy with the message, fences it for pi, and lets the thread's agent
/// read that copy (design_get).
public struct NativeAttachedReference: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let reference: DesignReference
    /// "Checkout › A · Checkout funnel › Primary button".
    public let label: String
    public let outline: DesignReferenceOutline?

    public init(id: UUID = UUID(), reference: DesignReference, label: String, outline: DesignReferenceOutline? = nil) {
        self.id = id
        self.reference = reference
        self.label = label
        self.outline = outline
    }

    /// The record a client sends: the reference alone.
    public var record: DesignReferenceRecord {
        DesignReferenceRecord(reference)
    }
}
