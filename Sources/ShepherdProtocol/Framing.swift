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
        buffer.append(chunk)
        var lines: [Data] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let payloadBytes = buffer.distance(from: buffer.startIndex, to: newlineIndex)
            guard payloadBytes <= NDJSON.maxPayloadBytes else {
                buffer.removeAll(keepingCapacity: false)
                throw LineBufferError.payloadTooLarge(bytes: payloadBytes, terminated: true)
            }
            lines.append(buffer.subdata(in: buffer.startIndex..<newlineIndex))
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
        }
        guard buffer.count <= NDJSON.maxPayloadBytes else {
            let payloadBytes = buffer.count
            buffer.removeAll(keepingCapacity: false)
            throw LineBufferError.payloadTooLarge(bytes: payloadBytes, terminated: false)
        }
        return lines
    }
}

