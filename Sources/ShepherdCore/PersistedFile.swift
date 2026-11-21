import Foundation

/// Reads without changing the file. A damaged result retains the bytes if the file was readable;
/// callers must preserve them or refuse writes, not treat damage as a missing file.
public enum PersistedFile<Value: Decodable> {
    case loaded(Value)
    case missing
    case damaged(original: Data?, error: any Error)

    public static func load(from url: URL, dateDecodingStrategy: JSONDecoder.DateDecodingStrategy = .deferredToDate,
                            exactEnvelope: Bool = false, validateBytes: (Data) throws -> Void = { _ in },
                            validate: (Value) throws -> Void = { _ in }) -> Self {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // Foundation can report a directory as "no such file" too. Only absence at the path,
            // without following a dangling symlink, permits a writer to start fresh.
            var entry = stat()
            if (error as? CocoaError)?.code == .fileReadNoSuchFile,
               lstat(url.path, &entry) == -1, errno == ENOENT { return .missing }
            return .damaged(original: nil, error: error)
        }
        do {
            try validateBytes(data)
        } catch {
            return .damaged(original: data, error: error)
        }
        return decode(data, dateDecodingStrategy: dateDecodingStrategy, exactEnvelope: exactEnvelope, validate: validate)
    }

    /// For stores that read their own bytes to fence an atomic replacement.
    package static func decode(_ data: Data, dateDecodingStrategy: JSONDecoder.DateDecodingStrategy = .deferredToDate,
                               exactEnvelope: Bool = false, validate: (Value) throws -> Void = { _ in }) -> Self {
        do {
            // Foundation's decoder reads UTF-16 and may repair invalid UTF-8, so the next save would write
            // over what was really there. Every writer emits UTF-8 with NUL escaped; anything else is damage.
            guard !data.contains(0), String(data: data, encoding: .utf8) != nil else { throw NotUTF8Text() }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = dateDecodingStrategy
            decoder.userInfo[exactEnvelopeKey] = exactEnvelope
            let document = try decoder.decode(Document.self, from: data)
            try validate(document.value)
            return .loaded(document.value)
        } catch {
            return .damaged(original: data, error: error)
        }
    }

    /// Raw fields for recovery only. Normal load decodes directly from the original data.
    package static func jsonObject(in data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        // A `value` key marks the envelope; unknown extra keys are tolerated, never read as a bare file.
        guard let value = object[Key.value.stringValue] else { return object }
        guard let version = object[Key.version.stringValue] else { throw CocoaError(.fileReadCorruptFile) }
        let versionData = try JSONSerialization.data(withJSONObject: version, options: [.fragmentsAllowed])
        guard try JSONDecoder().decode(Int.self, from: versionData) == 1, let value = value as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return value
    }

    private static var exactEnvelopeKey: CodingUserInfoKey { CodingUserInfoKey(rawValue: "PersistedFile.exactEnvelope")! }

    private struct Document: Decodable {
        let value: Value

        init(from decoder: Decoder) throws {
            // A `value` key marks the envelope, so an extra key can't make it fall through to a bare
            // decode, where a missing field defaults (all hooks on). No stored model has a `value` field.
            if let container = try? decoder.container(keyedBy: Key.self), container.contains(.value) {
                guard decoder.userInfo[PersistedFile.exactEnvelopeKey] as? Bool != true || container.allKeys.count == 2,
                      try container.decode(Int.self, forKey: .version) == 1 else {
                    throw DecodingError.dataCorruptedError(forKey: .version, in: container,
                                                          debugDescription: "Unsupported persisted file version")
                }
                value = try container.decode(Value.self, forKey: .value)
            } else {
                value = try decoder.singleValueContainer().decode(Value.self)
            }
        }
    }

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
        static var version: Self { .init(stringValue: "version") }
        static var value: Self { .init(stringValue: "value") }
    }
}

/// Why `PersistedFile` reports bytes that are not UTF-8 text (or hold a literal NUL) as damaged.
public struct NotUTF8Text: Error, CustomStringConvertible {
    public init() {}
    public var description: String { "The file isn't UTF-8 text." }
}

/// Decodes each element independently and retains its JSON, including fields the model ignores.
/// Rejections caused by relationships use that same raw record, not a model re-encode.
public struct LossyJSONArray<Element: Decodable> {
    public private(set) var records: [(value: Element, raw: Any)] = []
    public private(set) var rejected: [Any] = []

    public init(_ array: [Any]) throws {
        let decoder = JSONDecoder()
        for raw in array {
            let data = try JSONSerialization.data(withJSONObject: raw, options: [.fragmentsAllowed])
            if let value = try? decoder.decode(Element.self, from: data) {
                records.append((value, raw))
            } else {
                rejected.append(raw)
            }
        }
    }

    public mutating func reject(where shouldReject: (Element) -> Bool) {
        var removed: [Any] = []
        records.removeAll { record in
            guard shouldReject(record.value) else { return false }
            removed.append(record.raw)
            return true
        }
        rejected.append(contentsOf: removed)
    }
}
