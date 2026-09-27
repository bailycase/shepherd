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
    public static func message(_ text: String, files: [NativeAttachedFile], references: Int = 0) -> String {
        guard !files.isEmpty || references > 0 else { return text }
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts = words.isEmpty ? [] : [text]
        if references > 0 { parts.append(DesignReferenceFence.humanLine(count: references)) }
        if !files.isEmpty { parts.append((["Attached files:"] + files.map { "- \($0.path)" }).joined(separator: "\n")) }
        return parts.joined(separator: "\n\n")
    }
}

/// A design reference waiting in a composer beside the draft (docs/designs.md › Design
/// references): the piece, its chip's label, and the files drawn for it (its image, page,
/// element and tokens), which go with the message like attached files. Sent, the host reads the
/// piece from the design, fences it for pi, and lets the thread's agent read it (design_get).
public struct NativeAttachedReference: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let reference: DesignReference
    /// "Checkout › A · Checkout funnel › Primary button".
    public let label: String
    public let files: [NativeAttachedFile]

    public init(id: UUID = UUID(), reference: DesignReference, label: String, files: [NativeAttachedFile]) {
        self.id = id
        self.reference = reference
        self.label = label
        self.files = files
    }

    /// The record a client sends: the reference, and its files' names.
    public var record: DesignReferenceRecord {
        var record = DesignReferenceRecord(reference)
        record.files = files.isEmpty ? nil : files.map(\.name)
        return record
    }
}
