import Foundation

/// Newline-delimited JSON framing. One message per line; payloads carry binary
/// data as base64 (Codable's default for `Data`), so a bare `\n` is a safe delimiter.
public enum NDJSON {
    /// Maximum encoded UTF-8 payload size, excluding the terminating LF.
    public static let maxPayloadBytes = 1_048_576

    public static func encode<M: Encodable>(_ message: M) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        var data = try encoder.encode(message)
        data.append(0x0A)
        return data
    }

    public static func decode<M: Decodable>(_ type: M.Type, from line: Data) throws -> M {
        try JSONDecoder().decode(type, from: line)
    }
}

public enum LineBufferError: Error, Equatable, CustomStringConvertible, Sendable {
    case payloadTooLarge(bytes: Int, terminated: Bool)

    public var description: String {
        switch self {
        case .payloadTooLarge(let bytes, let terminated):
            return "NDJSON payload is too large (\(bytes) bytes, terminated: \(terminated))"
        }
    }
}

/// Accumulates a byte stream and yields complete lines as they arrive.
public struct LineBuffer: Sendable {
    private var buffer = Data()

    public init() {}

    /// Appends bytes and returns complete payloads. A payload is limited by
    /// `NDJSON.maxPayloadBytes`; an overflow clears the partial frame before
    /// throwing so callers cannot accidentally reuse unsafe buffered data.
    public mutating func append(_ chunk: Data) throws -> [Data] {
        guard !chunk.isEmpty else { return [] }
        // Only the new bytes can hold the next LF, and the consumed prefix is dropped once per
        // chunk: rescanning and shifting a large partial frame per line was quadratic.
        var searchFrom = buffer.count
        buffer.append(chunk)
        var lines: [Data] = []
        var consumed = 0
        let base = buffer.startIndex
        while let lf = Self.newline(in: buffer, from: searchFrom) {
            let payloadBytes = lf - consumed
            guard payloadBytes <= NDJSON.maxPayloadBytes else {
                buffer.removeAll(keepingCapacity: false)
                throw LineBufferError.payloadTooLarge(bytes: payloadBytes, terminated: true)
            }
            lines.append(buffer.subdata(in: (base + consumed)..<(base + lf)))
            consumed = lf + 1
            searchFrom = consumed
        }
        if consumed > 0 { buffer.removeSubrange(base..<(base + consumed)) }
        guard buffer.count <= NDJSON.maxPayloadBytes else {
            let payloadBytes = buffer.count
            buffer.removeAll(keepingCapacity: false)
            throw LineBufferError.payloadTooLarge(bytes: payloadBytes, terminated: false)
        }
        return lines
    }

    /// The offset of the first LF at or after `offset`.
    private static func newline(in data: Data, from offset: Int) -> Int? {
        data.withUnsafeBytes { raw -> Int? in
            guard offset < raw.count, let base = raw.baseAddress,
                  let hit = memchr(base + offset, 0x0A, raw.count - offset) else { return nil }
            return base.distance(to: UnsafeRawPointer(hit))
        }
    }
}

