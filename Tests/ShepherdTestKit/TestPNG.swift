import Foundation

/// Real, valid PNGs that are small in bytes and large in pixels (an all-zero grey picture deflates about 1000 to 1):
/// what a decoder would still be asked to allocate for. Used by the image pixel-policy tests.
public enum TestPNG {
    private static func be(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8((value >> (24 - 8 * UInt32($0))) & 0xFF) } }

    private static func crc(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            c ^= UInt32(byte)
            for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        }
        return ~c
    }

    private static func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
        be(UInt32(body.count)) + Array(type.utf8) + body + be(crc(Array(type.utf8) + body))
    }

    /// An 8-bit grey `width` × `height` picture of zeros.
    public static func zeros(width: Int, height: Int) -> Data {
        let raw = Data(count: (width + 1) * height)
        let deflated = try! (raw as NSData).compressed(using: .zlib) as Data
        // Adler-32 of n zero bytes: a stays 1 and b is n mod 65521.
        let adler = UInt32(raw.count % 65521) << 16 | 1
        let idat = [0x78, 0x9C] + [UInt8](deflated) + be(adler)
        let ihdr = be(UInt32(width)) + be(UInt32(height)) + [8, 0, 0, 0, 0]
        return Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + chunk("IHDR", ihdr) + chunk("IDAT", idat) + chunk("IEND", []))
    }
}
