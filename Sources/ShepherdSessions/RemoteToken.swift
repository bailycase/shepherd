/// The remote listener's token check.
enum RemoteToken {
    /// Whether `presented` is `expected`, in time that depends only on `expected`'s length: every
    /// byte is compared, with no exit at the first difference, so a client can't find the token
    /// a byte at a time by timing its rejections.
    static func matches(_ presented: String, expected: String) -> Bool {
        let given = Array(presented.utf8)
        var difference: UInt8 = given.count == expected.utf8.count ? 0 : 1
        for (index, byte) in expected.utf8.enumerated() {
            difference |= (index < given.count ? given[index] : 0) ^ byte
        }
        return difference == 0
    }
}
