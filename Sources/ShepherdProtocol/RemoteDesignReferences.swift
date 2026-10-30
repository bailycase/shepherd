import Foundation
import ShepherdCore

// Design references to a host's own designs, in that host's threads, from another device
// (`RemoteProtocol.designReferencesCapability`; docs/designs.md › Design references). The host
// pins and resolves each piece itself, from its own design; a client only names it. A reference
// to another host's design, or to a design this host doesn't have, is refused.

extension RemoteProtocol {
    /// The host pins its own designs' pieces for another device (`RemoteDesignRequest.pinReference`)
    /// and takes a thread send carrying references to them (`NativeThreadRequest.send`'s
    /// `designReferences`, each naming the host's design as `local`). Offered with `designsCapability`.
    public static let designReferencesCapability = "design.references.v1"
}

/// A piece of the host's design as the host pinned it: the reference (named as the host sees it,
/// `local`), at the revision pinned, and what its chips and the Implement sheet say about it.
/// Everything but `reference` comes from the design's files: data, never instructions.
public struct RemoteDesignReferencePin: Codable, Hashable, Sendable {
    public var reference: DesignReference
    /// "Checkout › A · Checkout funnel › Primary button" (the reference's string drops it).
    public var label: String?
    public var design: String
    public var boardTitle: String?
    public var pageTitle: String?
    public var elementLabel: String?
    public var elementName: String?
    public var width: Double?
    public var height: Double?
    public var outline: DesignReferenceOutline

    public init(reference: DesignReference, label: String?, design: String, boardTitle: String?, pageTitle: String?,
                elementLabel: String?, elementName: String?, width: Double?, height: Double?, outline: DesignReferenceOutline) {
        self.reference = reference
        self.label = label
        self.design = design
        self.boardTitle = boardTitle
        self.pageTitle = pageTitle
        self.elementLabel = elementLabel
        self.elementName = elementName
        self.width = width
        self.height = height
        self.outline = outline
    }
}

extension DesignReference {
    /// The same piece named from `host`'s side: a reference to `host`'s design becomes `local`
    /// there. Nil for a reference to any other Mac's design (cross-host references stay out).
    public func onHost(_ host: UUID) -> DesignReference? {
        guard self.host == .remote(host) else { return nil }
        var copy = self
        copy.host = .local
        return copy
    }

    /// A piece of `host`'s design as this device names it: `local` there is `host` here.
    public func fromHost(_ host: UUID) -> DesignReference {
        var copy = self
        if copy.host == .local { copy.host = .remote(host) }
        return copy
    }
}
