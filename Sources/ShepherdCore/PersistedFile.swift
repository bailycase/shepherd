import Foundation

/// Reads without changing the file. A damaged result retains the bytes if the file was readable;
/// callers must preserve them or refuse writes, not treat damage as a missing file.
public enum PersistedFile<Value: Decodable> {
    case loaded(Value)
    case missing
    case damaged(original: Data?, error: any Error)

    public static func load(from url: URL, validate: (Value) throws -> Void = { _ in }) -> Self {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // A dangling symlink is not a missing file that a writer is free to replace.
            if (error as? CocoaError)?.code == .fileReadNoSuchFile,
               (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil { return .missing }
            return .damaged(original: nil, error: error)
        }
        do {
            let document = try JSONDecoder().decode(Document.self, from: data)
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
        guard object.count == 2, let version = object[Key.version.stringValue], let value = object[Key.value.stringValue] else {
            return object
        }
        let versionData = try JSONSerialization.data(withJSONObject: version, options: [.fragmentsAllowed])
        guard try JSONDecoder().decode(Int.self, from: versionData) == 1, let value = value as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return value
    }

    private struct Document: Decodable {
        let value: Value

        init(from decoder: Decoder) throws {
            if let container = try? decoder.container(keyedBy: Key.self),
               container.allKeys.count == 2, container.contains(.version), container.contains(.value) {
                guard try container.decode(Int.self, forKey: .version) == 1 else {
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
