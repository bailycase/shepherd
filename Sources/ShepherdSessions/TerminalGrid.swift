/// Bounds both SwiftTerm allocation and the kernel's UInt16 winsize fields. A dimension cap
/// also bounds the width of each of the screen's 2,000 scrollback lines.
enum TerminalGrid {
    static func isValid(cols: Int, rows: Int) -> Bool {
        (1...1024).contains(cols) && (1...1024).contains(rows)
            && cols * rows <= 262_144
    }
}
