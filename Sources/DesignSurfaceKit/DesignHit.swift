import CoreGraphics
import Foundation
import ShepherdProtocol

/// One element of a board as the canvas selects it: what the bridge's hit test reports, checked.
/// `tid` and `path` name it as view-state.md does (`DesignElementID`), `rect` is where it is drawn
/// in the board's own points, and `kind`, `label` and `name` say what it is for the view record and
/// the canvas's tag.
public struct DesignHit: Equatable, Sendable {
    public var tid: Int
    public var path: [Int]
    public var rect: CGRect
    public var kind: DesignElementKind
    /// The template's own text in it (holes as written), an image's `alt`; one line, cut short.
    public var label: String?
    /// Its `data-el` name ("Checkout funnel"), or an import's board name.
    public var name: String?
    /// What the canvas's tag calls it: "card", "text", "button", "image", "component"…
    public var noun: String

    /// The nouns a tag may use; the bridge's anything else reads "element".
    public static let nouns: Set<String> = ["text", "image", "line", "shape", "card", "group", "button", "link", "field", "component"]
    static let maxName = 60
    /// Beyond any board: a rect past it is not a board's.
    static let maxCoordinate: CGFloat = 100_000

    public init(tid: Int, path: [Int], rect: CGRect, kind: DesignElementKind, label: String? = nil, name: String? = nil, noun: String) {
        self.tid = tid
        self.path = path
        self.rect = rect
        self.kind = kind
        self.label = label
        self.name = name
        self.noun = noun
    }

    /// A bridge answer, or nil when it isn't one: a tid or path outside the view record's
    /// grammar, or a rect that isn't finite and on the board.
    public init?(bridge value: Any?) {
        guard let object = value as? [String: Any],
              let tid = Self.integer(object["tid"]), let raw = object["path"] as? [Any] else { return nil }
        let path = raw.compactMap(Self.integer)
        guard path.count == raw.count, DesignElementID(board: "B.dc.html", tid: tid, path: path) != nil else { return nil }
        guard let x = Self.number(object["x"]), let y = Self.number(object["y"]),
              let width = Self.number(object["width"]), let height = Self.number(object["height"]),
              width >= 0, height >= 0, width <= Self.maxCoordinate, height <= Self.maxCoordinate,
              abs(x) <= Self.maxCoordinate, abs(y) <= Self.maxCoordinate else { return nil }
        self.tid = tid
        self.path = path
        rect = CGRect(x: x, y: y, width: width, height: height)
        kind = (object["kind"] as? String).flatMap(DesignElementKind.init(rawValue:)) ?? .other
        label = (object["label"] as? String).flatMap(DesignViewRecord.label)
        name = (object["name"] as? String).flatMap(DesignViewRecord.label).map { String($0.prefix(Self.maxName)) }
        let noun = object["noun"] as? String ?? ""
        self.noun = Self.nouns.contains(noun) ? noun : "element"
    }

    /// Its id on `board`.
    public func id(on board: DesignPath) -> DesignElementID? {
        DesignElementID(board: board.viewName, tid: tid, path: path)
    }

    /// The canvas's tag: "card · Checkout funnel", the noun alone when it has no words.
    public var tag: String {
        guard let words = name ?? label else { return noun }
        return "\(noun) · \(words)"
    }

    /// A JavaScript number (never a boolean, which bridges as 0 or 1).
    private static func jsNumber(_ value: Any?) -> NSNumber? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = jsNumber(value) else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double == double.rounded(), abs(double) < 1_000_000 else { return nil }
        return Int(double)
    }

    private static func number(_ value: Any?) -> CGFloat? {
        guard let number = jsNumber(value) else { return nil }
        let double = number.doubleValue
        return double.isFinite ? CGFloat(double) : nil
    }
}
