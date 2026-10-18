import Foundation
import zlib

/// Only installed on the SDK's session. Profile chunks bypass Sentry's beforeSend callback.
final class DiagnosticsEnvelopeProtocol: URLProtocol, @unchecked Sendable {
    static let contextHeader = "X-Shepherd-Diagnostics-Context"
    private static let registry = Registry()
    private let lock = NSLock()
    private var child: URLSessionDataTask?
    private var stopped = false

    private final class Registry: @unchecked Sendable {
        struct Entry { weak var context: Context? }
        let lock = NSLock()
        var entries: [String: Entry] = [:]
    }

    /// Retain once per diagnostics instance, and revoke before cancelling the SDK session.
    /// No configuration is shared between contexts; an absent/revoked context fails closed.
    final class Context: @unchecked Sendable {
        fileprivate let id = UUID().uuidString
        fileprivate let release: String?
        fileprivate let environment: String?
        fileprivate let allowProfiles: Bool
        private let lock = NSLock()
        private var session: URLSession?

        fileprivate init(configuration: URLSessionConfiguration, release: String?, environment: String?, allowProfiles: Bool) {
            self.release = release
            self.environment = environment
            self.allowProfiles = allowProfiles
            session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        }

        func revoke() {
            DiagnosticsEnvelopeProtocol.registry.lock.withLock {
                _ = DiagnosticsEnvelopeProtocol.registry.entries.removeValue(forKey: id)
            }
            let retired = lock.withLock { let value = session; session = nil; return value }
            retired?.invalidateAndCancel()
        }

        // Weak registry slots are pruned at setup. Do not reenter its lock from a weak load's deinit.
        deinit { session?.invalidateAndCancel() }

        fileprivate func task(for request: URLRequest,
                              completion: @escaping @Sendable (Data?, URLResponse?, (any Error)?) -> Void) -> URLSessionDataTask? {
            lock.withLock { session?.dataTask(with: request, completionHandler: completion) }
        }
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            // Never send diagnostics to a different endpoint via an HTTP redirect.
            completionHandler(nil)
        }
    }

    static func configure(on configuration: URLSessionConfiguration, release: String? = nil, environment: String? = nil,
                          allowProfiles: Bool = false) -> Context {
        let forwarding = configuration.copy() as! URLSessionConfiguration
        forwarding.protocolClasses = (forwarding.protocolClasses ?? []).filter { $0 != DiagnosticsEnvelopeProtocol.self }
        var headers = forwarding.httpAdditionalHeaders ?? [:]
        for key in headers.keys where String(describing: key).lowercased() == contextHeader.lowercased() {
            headers.removeValue(forKey: key)
        }
        forwarding.httpAdditionalHeaders = headers
        let context = Context(configuration: forwarding, release: release, environment: environment, allowProfiles: allowProfiles)
        let registered = registry.lock.withLock {
            registry.entries = registry.entries.filter { $0.value.context != nil }
            guard registry.entries.count < 16 else { return false }
            registry.entries[context.id] = Registry.Entry(context: context)
            return true
        }
        if !registered { context.revoke() } // Exhaustion fails closed, never uses another session's configuration.
        headers[contextHeader] = context.id
        configuration.httpAdditionalHeaders = headers
        configuration.protocolClasses = [DiagnosticsEnvelopeProtocol.self] + (forwarding.protocolClasses ?? [])
        return context
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let id = request.value(forHTTPHeaderField: Self.contextHeader),
                  let context = Self.registry.lock.withLock({ Self.registry.entries[id]?.context }) else {
                throw URLError(.cancelled)
            }
            var outgoing = try DiagnosticsEnvelopeFilter.sanitized(request, release: context.release, environment: context.environment,
                                                                   allowProfiles: context.allowProfiles)
            outgoing.setValue(nil, forHTTPHeaderField: Self.contextHeader)
            let task = context.task(for: outgoing) { [weak self] data, response, error in
                guard let self, !self.lock.withLock({ self.stopped }) else { return }
                if let error { self.client?.urlProtocol(self, didFailWithError: error); return }
                guard let response else {
                    self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
                }
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                if let data { self.client?.urlProtocol(self, didLoad: data) }
                self.client?.urlProtocolDidFinishLoading(self)
            }
            guard let task else { throw URLError(.cancelled) }
            lock.withLock {
                if stopped { task.cancel() } else { child = task; task.resume() }
            }
        } catch {
            if !lock.withLock({ stopped }) { client?.urlProtocol(self, didFailWithError: error) }
        }
    }

    override func stopLoading() {
        let task = lock.withLock { stopped = true; let task = child; child = nil; return task }
        task?.cancel()
    }
}

/// Byte-framed envelopes, not newline-split payloads: attachments can contain arbitrary binary.
/// Unknown profile formats and malformed input are rejected, never forwarded unsanitized.
enum DiagnosticsEnvelopeFilter {
    static let maximumBodyBytes = 8 * 1024 * 1024
    static let maximumExpandedBytes = 16 * 1024 * 1024
    static let maximumProfileBytes = 8 * 1024 * 1024
    static let maximumItems = 256
    static let maximumEntries = 100_000
    enum Failure: Error { case invalid }

    static func sanitized(_ request: URLRequest, release: String? = nil, environment: String? = nil, allowProfiles: Bool = true) throws -> URLRequest {
        var body = request.httpBody ?? Data()
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count >= 0 else { throw Failure.invalid }
                if count == 0 { break }
                guard body.count <= maximumBodyBytes - count else { throw Failure.invalid }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        let encoding = request.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
        guard encoding == nil || encoding == "gzip" || encoding == "identity" else { throw Failure.invalid }
        let filtered = try sanitized(body, gzip: encoding == "gzip" || body.starts(with: [0x1f, 0x8b]), release: release,
                                     environment: environment, allowProfiles: allowProfiles)
        var result = request
        // Streams have been consumed even when no transformation was necessary.
        result.httpBodyStream = nil
        result.httpBody = filtered ?? body
        if filtered != nil {
            result.setValue(nil, forHTTPHeaderField: "Content-Encoding")
            result.setValue(nil, forHTTPHeaderField: "Content-Length")
        }
        return result
    }

    /// nil means the original bytes (including compression) are safe to retain unchanged.
    static func sanitized(_ body: Data, gzip: Bool = false, release: String? = nil, environment: String? = nil, allowProfiles: Bool = true) throws -> Data? {
        guard body.count <= maximumBodyBytes else { throw Failure.invalid }
        let data = try gzip ? inflateBody(body) : Data(body)
        var cursor = 0
        func line() throws -> Data {
            let end = min(data.count, cursor + 16 * 1024)
            guard cursor < end, let newline = data[cursor..<end].firstIndex(of: 10) else { throw Failure.invalid }
            defer { cursor = newline + 1 }
            return data.subdata(in: cursor..<newline)
        }
        _ = try object(line())
        // HTTP authentication routes the envelope; ambient trace/scope headers must not escape with profiles.
        var output = Data("{}\n".utf8)
        var changed = false
        var items = 0
        while cursor < data.count {
            items += 1
            guard items <= maximumItems else { throw Failure.invalid }
            let rawHeader = try line()
            let header = try object(rawHeader)
            guard let type = header["type"] as? String,
                  let length = integer(header["length"]), length <= data.count - cursor else { throw Failure.invalid }
            let payload = data.subdata(in: cursor..<(cursor + length))
            cursor += length
            if type == "profile_chunk" {
                // Also blocks SDK cache replay from a build where profiling had been approved.
                guard allowProfiles else { throw Failure.invalid }
                let clean = try profile(payload, release: release, environment: environment)
                let cleanHeader: [String: Any] = ["type": "profile_chunk", "length": clean.count, "platform": "cocoa"]
                output.append(try JSONSerialization.data(withJSONObject: cleanHeader, options: [.sortedKeys]))
                output.append(10)
                output.append(clean)
                changed = true
            } else {
                guard !type.lowercased().contains("profil") else { throw Failure.invalid }
                output.append(rawHeader)
                output.append(10)
                output.append(payload)
            }
            if cursor < data.count {
                guard data[cursor] == 10 else { throw Failure.invalid }
                output.append(10)
                cursor += 1
            }
            guard output.count <= maximumExpandedBytes else { throw Failure.invalid }
        }
        guard items > 0 else { throw Failure.invalid }
        return changed ? output : nil
    }

    private static func inflateBody(_ input: Data) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, 31, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw Failure.invalid }
        defer { inflateEnd(&stream) }
        var output = Data()
        try input.withUnsafeBytes { bytes in
            stream.next_in = UnsafeMutablePointer(mutating: bytes.bindMemory(to: UInt8.self).baseAddress)
            stream.avail_in = uInt(bytes.count)
            var buffer = [UInt8](repeating: 0, count: 32 * 1024)
            while true {
                let status = buffer.withUnsafeMutableBytes { destination in
                    stream.next_out = destination.bindMemory(to: UInt8.self).baseAddress
                    stream.avail_out = uInt(destination.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let count = buffer.count - Int(stream.avail_out)
                guard output.count <= maximumExpandedBytes - count else { throw Failure.invalid }
                output.append(contentsOf: buffer.prefix(count))
                if status == Z_STREAM_END {
                    guard stream.avail_in == 0 else { throw Failure.invalid }
                    return
                }
                guard status == Z_OK, count > 0 else { throw Failure.invalid }
            }
        }
        return output
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        // Bound nesting before Foundation allocates containers, including fields we will discard.
        var depth = 0
        var quoted = false
        var escaped = false
        var values = 0
        for byte in data {
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 123 || byte == 91 { depth += 1; values += 1; guard depth <= 32 else { throw Failure.invalid } }
            else if byte == 125 || byte == 93 { depth -= 1 }
            else if byte == 44 { values += 1 }
            guard values <= 1_000_000 else { throw Failure.invalid }
        }
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.invalid }
        return result
    }

    private static func number(_ value: Any?) -> NSNumber? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0 else { return nil }
        return number
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = number(value), number.doubleValue < Double(Int.max),
              number.doubleValue.rounded(.down) == number.doubleValue else { return nil }
        return number.intValue
    }

    private static func address(_ value: Any?) -> String? {
        guard let value = value as? String, value.hasPrefix("0x"), (3...18).contains(value.utf8.count),
              value.dropFirst(2).utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return nil }
        return value
    }

    private static func identifier(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let hex = value.replacingOccurrences(of: "-", with: "")
        guard hex.utf8.count == 32, hex.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return nil }
        return hex.lowercased()
    }

    private static func profile(_ data: Data, release: String?, environment: String?) throws -> Data {
        guard data.count <= maximumProfileBytes else { throw Failure.invalid }
        let source = try object(data)
        guard source["version"] as? String == "2", let chunk = identifier(source["chunk_id"]),
              let profiler = identifier(source["profiler_id"]), let profile = source["profile"] as? [String: Any],
              let frames = profile["frames"] as? [[String: Any]], frames.count <= maximumEntries,
              let stacks = profile["stacks"] as? [[Any]], stacks.count <= maximumEntries,
              let samples = profile["samples"] as? [[String: Any]], (2...maximumEntries).contains(samples.count) else { throw Failure.invalid }
        let cleanFrames: [[String: Any]] = try frames.map { frame in
            guard let instruction = address(frame["instruction_addr"]) else { throw Failure.invalid }
            var clean: [String: Any] = ["instruction_addr": instruction]
            for key in ["symbol_addr", "image_addr"] { if let value = address(frame[key]) { clean[key] = value } }
            return clean
        }
        var indices = 0
        let cleanStacks: [[Int]] = try stacks.map { stack in
            indices += stack.count
            guard stack.count <= 512, indices <= 1_000_000 else { throw Failure.invalid }
            return try stack.map { value in
                guard let index = integer(value), index < frames.count else { throw Failure.invalid }
                return index
            }
        }
        let cleanSamples: [[String: Any]] = try samples.map { sample in
            guard let timestamp = number(sample["timestamp"]), let stack = integer(sample["stack_id"]), stack < stacks.count,
                  let thread = sample["thread_id"] as? String, !thread.isEmpty, thread.utf8.count <= 20,
                  thread.utf8.allSatisfy({ (48...57).contains($0) }), UInt64(thread) != nil else { throw Failure.invalid }
            return ["timestamp": timestamp, "stack_id": stack, "thread_id": thread]
        }
        let metadata = profile["thread_metadata"] as? [String: [String: Any]] ?? [:]
        var threads: [String: [String: Any]] = [:]
        for thread in Set(cleanSamples.compactMap({ $0["thread_id"] as? String })) {
            var entry: [String: Any] = [:]
            if let priority = integer(metadata[thread]?["priority"]) { entry["priority"] = priority }
            if metadata[thread]?["name"] as? String == "main" { entry["name"] = "main" }
            threads[thread] = entry
        }
        var clean: [String: Any] = ["version": "2", "platform": "cocoa", "chunk_id": chunk, "profiler_id": profiler,
                                    "profile": ["samples": cleanSamples, "stacks": cleanStacks, "frames": cleanFrames, "thread_metadata": threads]]
        // Release/edition come only from app configuration, never an SDK scope or cached payload.
        clean["release"] = release
        clean["environment"] = environment
        if let metrics = source["measurements"] as? [String: Any] {
            var measurements: [String: Any] = [:]
            for (name, unit) in ["memory_footprint": "byte", "cpu_usage": "percent", "cpu_energy_usage": "nanojoule"] {
                guard let metric = metrics[name] as? [String: Any], metric["unit"] as? String == unit,
                      let values = metric["values"] as? [[String: Any]] else { continue }
                guard values.count <= maximumEntries else { throw Failure.invalid }
                let readings: [[String: Any]] = try values.map { value in
                    guard let time = number(value["timestamp"]), let amount = number(value["value"]) else { throw Failure.invalid }
                    return ["timestamp": time, "value": amount]
                }
                measurements[name] = ["unit": unit, "values": readings]
            }
            if !measurements.isEmpty { clean["measurements"] = measurements }
        }
        if let debug = source["debug_meta"] as? [String: Any], let images = debug["images"] as? [[String: Any]] {
            guard images.count <= 2048 else { throw Failure.invalid }
            clean["debug_meta"] = ["images": images.compactMap { image -> [String: Any]? in
                guard let id = image["debug_id"] as? String, let uuid = UUID(uuidString: id),
                      let start = address(image["image_addr"]) else { return nil }
                var clean: [String: Any] = ["debug_id": uuid.uuidString, "image_addr": start, "type": "macho"]
                if let size = integer(image["image_size"]) { clean["image_size"] = size }
                if let vm = address(image["image_vmaddr"]) { clean["image_vmaddr"] = vm }
                if let file = image["code_file"] as? String {
                    let name = file.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? ""
                    if !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255,
                       !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) { clean["code_file"] = name }
                }
                return clean
            }]
        }
        return try JSONSerialization.data(withJSONObject: clean, options: [.sortedKeys])
    }
}
