import Foundation

/// What a push's long-press preview draws, carried in the relay's `detail` field and forwarded
/// as `shepherd.detail`. Every string is bounded so the whole event stays inside the relay's
/// 2048-byte body; the relay checks the same bounds.
public struct PushDetail: Codable, Hashable, Sendable {
    /// A question's options, each a button under the push.
    public var options: [String]?

    public init(options: [String]? = nil) {
        self.options = options
    }

    /// The relay's bounds (shepherd-landing `detail`): counts, then characters per string.
    public enum Limit {
        public static let options = 4, option = 40
    }

    /// A question's options as buttons, only when every one fits whole: a clipped title would answer something else.
    public static func question(options: [String]) -> PushDetail? {
        guard !options.isEmpty, options.count <= Limit.options,
              options.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.count <= Limit.option && !$0.contains(where: \.isNewline) }) else { return nil }
        return PushDetail(options: options)
    }

    /// Every string, through `transform` (the host's redaction). What the relay would refuse is
    /// dropped here, since a refusal reads as an older relay and costs every later push its detail.
    public func mapText(_ transform: (String) -> String) -> PushDetail {
        var detail = self
        // An option is sent whole or not at all.
        if let options, options.map(transform) != options || Self.question(options: options) == nil { detail.options = nil }
        return detail
    }
}
