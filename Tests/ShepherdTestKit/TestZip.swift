import Foundation

/// A ZIP written byte by byte (stored, no compression), so a test can make any archive an
/// import must refuse: a name that climbs out (`../x`), an absolute one, a link, a size that
/// claims more than it holds. Only as much of the format as `/usr/bin/ditto` and the import's
/// reader need.
public enum TestZip {
    public struct Entry: Sendable {
        public var name: String
        public var data: Data
        /// The Unix mode with its type: 0o100644 a file, 0o040755 a folder, 0o120777 a link
        /// (whose data is its target).
        public var mode: UInt32
        /// The size the archive claims, when it isn't the data's (never unpacked then).
        public var claimedSize: UInt32?

        public init(_ name: String, _ data: Data = Data(), mode: UInt32 = 0o100644, claimedSize: UInt32? = nil) {
            self.name = name
            self.data = data
            self.mode = mode
            self.claimedSize = claimedSize
        }

        public static func file(_ name: String, _ text: String) -> Entry { Entry(name, Data(text.utf8)) }
        public static func folder(_ name: String) -> Entry { Entry(name.hasSuffix("/") ? name : name + "/", mode: 0o040755) }
        public static func link(_ name: String, to target: String) -> Entry { Entry(name, Data(target.utf8), mode: 0o120777) }
    }

    public static func make(_ entries: [Entry]) -> Data {
        var body = Data()
        var directory = Data()
        for entry in entries {
            let name = Data(entry.name.utf8)
            let crc = crc32(entry.data)
            let size = UInt32(entry.data.count)
            let claimed = entry.claimedSize ?? size
            let offset = UInt32(body.count)
            body.append(le32(0x0403_4b50))
            body.append(le16(20)); body.append(le16(0x0800)); body.append(le16(0))
            body.append(le16(0)); body.append(le16(0x21))
            body.append(le32(crc)); body.append(le32(size)); body.append(le32(claimed))
            body.append(le16(UInt16(name.count))); body.append(le16(0))
            body.append(name)
            body.append(entry.data)

            directory.append(le32(0x0201_4b50))
            directory.append(le16(0x031E)); directory.append(le16(20)); directory.append(le16(0x0800)); directory.append(le16(0))
            directory.append(le16(0)); directory.append(le16(0x21))
            directory.append(le32(crc)); directory.append(le32(size)); directory.append(le32(claimed))
            directory.append(le16(UInt16(name.count))); directory.append(le16(0)); directory.append(le16(0))
            directory.append(le16(0)); directory.append(le16(0))
            directory.append(le32(entry.mode << 16))
            directory.append(le32(offset))
            directory.append(name)
        }
        var end = Data()
        end.append(le32(0x0605_4b50))
        end.append(le16(0)); end.append(le16(0))
        end.append(le16(UInt16(entries.count))); end.append(le16(UInt16(entries.count)))
        end.append(le32(UInt32(directory.count))); end.append(le32(UInt32(body.count)))
        end.append(le16(0))
        return body + directory + end
    }

    private static func le16(_ value: UInt16) -> Data { Data([UInt8(value & 0xFF), UInt8(value >> 8)]) }
    private static func le32(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)])
    }

    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}
