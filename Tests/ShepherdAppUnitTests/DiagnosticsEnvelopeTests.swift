import Foundation
import Testing
import zlib
@testable import ShepherdApp

@Suite("Diagnostics envelope privacy")
struct DiagnosticsEnvelopeTests {
    private let secret = "PRIVATE_PROMPT_PATH_OR_SYMBOL"

    private func chunk() -> [String: Any] {
        ["version": "2", "chunk_id": "0123456789abcdef0123456789abcdef", "profiler_id": "abcdef0123456789abcdef0123456789",
         "platform": "cocoa", "release": secret, "environment": secret, "client_sdk": ["name": secret], "extra": ["prompt": secret],
         "profile": [
            "frames": [["instruction_addr": "0x1234", "symbol_addr": "0x1200", "image_addr": "0x1000",
                        "function": secret, "filename": secret, "source": secret, "vars": ["prompt": secret]]],
            "stacks": [[0]],
            "samples": [["timestamp": 100.5, "thread_id": "42", "stack_id": 0, "queue_address": "0x4567", "extra": secret],
                        ["timestamp": 100.6, "thread_id": "43", "stack_id": 0]],
            "thread_metadata": ["42": ["name": secret, "priority": 31], "43": ["name": "main", "priority": true], secret: ["name": secret]],
            "queue_metadata": ["0x4567": ["label": secret]]],
         "measurements": ["memory_footprint": ["unit": "byte", "values": [["timestamp": 100.5, "value": 4096, "extra": secret]]],
                          "cpu_usage": ["unit": "percent", "values": [["timestamp": 100.5, "value": 12.5]]],
                          "cpu_energy_usage": ["unit": "nanojoule", "values": [["timestamp": 100.5, "value": 64]]],
                          secret: ["unit": "byte", "values": [["timestamp": 100.5, "value": 1]]]],
         "debug_meta": ["images": [["debug_id": "12345678-1234-1234-1234-123456789ABC", "type": "macho",
                                    "image_addr": "0x1000", "image_vmaddr": "0x0", "image_size": 4096,
                                    "code_file": "/Users/\(secret)/Shepherd", "extra": secret]]]]
    }

    private func item(_ payload: Data, type: String = "profile_chunk") throws -> Data {
        var header: [String: Any] = ["type": type, "length": payload.count]
        if type == "attachment" { header["filename"] = secret }
        var data = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        data.append(10)
        data.append(payload)
        return data
    }

    private func envelope(_ source: [String: Any]? = nil) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: ["trace": ["user_segment": secret], "sdk": ["name": secret]])
        data.append(10)
        data.append(try item(JSONSerialization.data(withJSONObject: source ?? chunk())))
        return data
    }

    @Test func onlyNumericProfileStructureAndSymbolicationIdentifiersSurvive() throws {
        let clean = try #require(try DiagnosticsEnvelopeFilter.sanitized(envelope(), release: "Shepherd@1.2+3", environment: "nightly"))
        #expect(!String(decoding: clean, as: UTF8.self).contains(secret))
        let lines = clean.split(separator: 10)
        #expect(String(decoding: lines[0], as: UTF8.self) == "{}")
        let header = try #require(JSONSerialization.jsonObject(with: Data(lines[1])) as? [String: Any])
        #expect(header["length"] as? Int == lines[2].count)
        let payload = try #require(JSONSerialization.jsonObject(with: Data(lines[2])) as? [String: Any])
        #expect(payload["release"] as? String == "Shepherd@1.2+3" && payload["environment"] as? String == "nightly")
        #expect(payload["client_sdk"] == nil)
        let profile = try #require(payload["profile"] as? [String: Any])
        #expect(profile["stacks"] as? [[Int]] == [[0]])
        #expect((profile["frames"] as? [[String: String]])?.first == ["instruction_addr": "0x1234", "symbol_addr": "0x1200", "image_addr": "0x1000"])
        let samples = try #require(profile["samples"] as? [[String: Any]])
        #expect(samples.count == 2 && samples[0]["timestamp"] as? Double == 100.5)
        #expect(samples[0]["thread_id"] as? String == "42" && samples[0]["stack_id"] as? Int == 0)
        let threads = try #require(profile["thread_metadata"] as? [String: [String: Any]])
        #expect(threads.count == 2 && threads["42"]?["priority"] as? Int == 31 && threads["42"]?["name"] == nil)
        #expect(threads["43"]?["name"] as? String == "main" && threads["43"]?["priority"] == nil)
        #expect(profile["queue_metadata"] == nil)
        let measurements = try #require(payload["measurements"] as? [String: [String: Any]])
        #expect(Set(measurements.keys) == ["memory_footprint", "cpu_usage", "cpu_energy_usage"])
        #expect(measurements["cpu_usage"]?["unit"] as? String == "percent")
        #expect((measurements["cpu_usage"]?["values"] as? [[String: Double]]) == [["timestamp": 100.5, "value": 12.5]])
        let images = try #require((payload["debug_meta"] as? [String: Any])?["images"] as? [[String: Any]])
        #expect(images.first?["debug_id"] as? String == "12345678-1234-1234-1234-123456789ABC")
        #expect(images.first?["code_file"] as? String == "Shepherd")
    }

    @Test func binaryAttachmentsAreDiscardedWithoutCorruptingSiblingItems() throws {
        let binary = Data([0, 255, 10]) + Data("{\"type\":\"profile_chunk\"}\nprivate bytes".utf8)
        let attachment = try item(binary, type: "attachment")
        let event = try item(Data("{\"message\":\"already sanitized\"}".utf8), type: "event")
        let unchanged = Data("{}\n".utf8) + event
        #expect(try DiagnosticsEnvelopeFilter.sanitized(unchanged) == nil)
        for parts in [[attachment, event], [event, attachment], [attachment, event, attachment]] {
            let input = Data("{}\n".utf8) + parts.dropFirst().reduce(parts[0]) { $0 + Data([10]) + $1 }
            #expect(try DiagnosticsEnvelopeFilter.sanitized(input) == unchanged)
            #expect(try DiagnosticsEnvelopeFilter.sanitized(gzip(input), gzip: true, allowProfiles: false) == unchanged)
        }
        let onlyAttachment = Data("{}\n".utf8) + attachment
        #expect(throws: DiagnosticsEnvelopeFilter.Failure.self) { try DiagnosticsEnvelopeFilter.sanitized(onlyAttachment) }
        let mixed = onlyAttachment + Data([10]) + event + Data([10]) + (try item(JSONSerialization.data(withJSONObject: chunk())))
        let clean = try #require(try DiagnosticsEnvelopeFilter.sanitized(mixed))
        #expect(clean.starts(with: unchanged + Data([10])))
        #expect(!String(decoding: clean, as: UTF8.self).contains(secret))
        #expect(!String(decoding: clean, as: UTF8.self).contains("private bytes"))
        #expect(!String(decoding: clean, as: UTF8.self).contains(secret))
    }

    @Test func gzipAndBodyStreamsAreSanitizedAndStaleHTTPHeadersAreRemoved() throws {
        let compressed = try gzip(envelope())
        var request = URLRequest(url: URL(string: "https://diagnostics.invalid/envelope/")!)
        request.httpMethod = "POST"
        request.httpBodyStream = InputStream(data: compressed)
        request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        request.setValue(String(compressed.count), forHTTPHeaderField: "Content-Length")
        let clean = try DiagnosticsEnvelopeFilter.sanitized(request)
        #expect(clean.httpBodyStream == nil)
        #expect(clean.value(forHTTPHeaderField: "Content-Encoding") == nil)
        #expect(clean.value(forHTTPHeaderField: "Content-Length") == nil)
        #expect(clean.httpBody == (try DiagnosticsEnvelopeFilter.sanitized(envelope())))
        let event = Data("{}\n".utf8) + (try item(Data("{}".utf8), type: "session"))
        let zippedEvent = try gzip(event)
        request.httpBodyStream = nil
        request.httpBody = zippedEvent
        #expect(try DiagnosticsEnvelopeFilter.sanitized(request).httpBody == zippedEvent)
    }

    @Test func disabledProfilingRejectsPlainAndCompressedCachedChunksButKeepsSessions() throws {
        #expect(throws: (any Error).self) { try DiagnosticsEnvelopeFilter.sanitized(envelope(), allowProfiles: false) }
        #expect(throws: (any Error).self) { try DiagnosticsEnvelopeFilter.sanitized(gzip(envelope()), gzip: true, allowProfiles: false) }
        let session = Data("{}\n".utf8) + (try item(Data("{}".utf8), type: "session"))
        #expect(try DiagnosticsEnvelopeFilter.sanitized(session, allowProfiles: false) == nil)
    }

    @Test func malformedFramingUnknownProfileTypesAndInvalidNumericValuesFailClosed() throws {
        let payload = try JSONSerialization.data(withJSONObject: chunk())
        let malformed = [Data(), Data("{}\n{\"type\":\"profile_chunk\"}\n{}".utf8),
                         Data("{}\n{\"type\":\"profile_chunk\",\"length\":999999}\n{}".utf8),
                         Data("{}\n{\"type\":\"event\",\"length\":true}\nx".utf8),
                         try envelope() + Data("garbage".utf8),
                         Data("{}\n".utf8) + (try item(payload, type: "profile")),
                         Data("{}\n".utf8) + (try item(payload, type: "profile_chunk_v3"))]
        for data in malformed { #expect(throws: (any Error).self) { try DiagnosticsEnvelopeFilter.sanitized(data) } }
        for field in ["timestamp", "stack_id", "thread_id"] {
            for invalid: Any in [true, -1, "PRIVATE", "1.5"] {
                var source = chunk()
                var profile = try #require(source["profile"] as? [String: Any])
                var samples = try #require(profile["samples"] as? [[String: Any]])
                samples[0][field] = invalid
                profile["samples"] = samples
                source["profile"] = profile
                #expect(throws: (any Error).self) { try DiagnosticsEnvelopeFilter.sanitized(envelope(source)) }
            }
        }
        var version = chunk()
        version["version"] = "3"
        #expect(throws: (any Error).self) { try DiagnosticsEnvelopeFilter.sanitized(envelope(version)) }
        var tooFew = chunk()
        var profile = try #require(tooFew["profile"] as? [String: Any])
        profile["samples"] = [["timestamp": 100, "thread_id": "42", "stack_id": 0]]
        tooFew["profile"] = profile
        #expect(throws: (any Error).self) { try DiagnosticsEnvelopeFilter.sanitized(envelope(tooFew)) }
    }

    @Test func byteExpansionItemAndStackCountLimitsFailClosed() throws {
        let tooLarge = Data(repeating: 32, count: DiagnosticsEnvelopeFilter.maximumBodyBytes + 1)
        #expect(throws: (any Error).self) { try DiagnosticsEnvelopeFilter.sanitized(tooLarge) }
        let bomb = try gzip(Data(repeating: 32, count: DiagnosticsEnvelopeFilter.maximumExpandedBytes + 1))
        #expect(throws: (any Error).self) { try DiagnosticsEnvelopeFilter.sanitized(bomb, gzip: true) }
        let validGzip = try gzip(envelope())
        #expect(throws: (any Error).self) { try DiagnosticsEnvelopeFilter.sanitized(validGzip.dropLast(), gzip: true) }
        #expect(throws: (any Error).self) { try DiagnosticsEnvelopeFilter.sanitized(validGzip + validGzip, gzip: true) }
        var manyItems = Data("{}\n".utf8)
        for _ in 0...DiagnosticsEnvelopeFilter.maximumItems { manyItems.append(try item(Data("{}".utf8), type: "session") + Data([10])) }
        #expect(throws: (any Error).self) { try DiagnosticsEnvelopeFilter.sanitized(manyItems) }
        var source = chunk()
        var profile = try #require(source["profile"] as? [String: Any])
        profile["stacks"] = [Array(repeating: 0, count: 513)]
        source["profile"] = profile
        #expect(throws: (any Error).self) { try DiagnosticsEnvelopeFilter.sanitized(envelope(source)) }
        source["extra"] = String(repeating: "[", count: 33) // A quoted bracket is not nesting.
        profile["stacks"] = [[0]]
        source["profile"] = profile
        #expect(try DiagnosticsEnvelopeFilter.sanitized(envelope(source)) != nil)
        let nested = Data(("{}\n{\"type\":\"profile_chunk\",\"length\":68}\n" + String(repeating: "[", count: 34) + String(repeating: "]", count: 34)).utf8)
        #expect(throws: (any Error).self) { try DiagnosticsEnvelopeFilter.sanitized(nested) }
    }

    private func gzip(_ data: Data) throws -> Data {
        var stream = z_stream()
        try #require(deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY,
                                  ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK)
        defer { deflateEnd(&stream) }
        var output = Data(count: Int(deflateBound(&stream, uLong(data.count))))
        let status = data.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { destination in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress)
                stream.avail_in = uInt(input.count)
                stream.next_out = destination.bindMemory(to: UInt8.self).baseAddress
                stream.avail_out = uInt(destination.count)
                return deflate(&stream, Z_FINISH)
            }
        }
        try #require(status == Z_STREAM_END)
        return output.prefix(Int(stream.total_out))
    }
}
