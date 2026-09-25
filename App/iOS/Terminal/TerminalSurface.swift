import SwiftUI
import UIKit
import SwiftTerm
import ShepherdUI

/// A host terminal session's screen: SwiftTerm's iOS `TerminalView`, on Night Watch's terminal
/// colors in Geist Mono. The view belongs to its `MobileTerminalSession`, so a tab shown again
/// reuses it; what it shows always comes from the host (the attach replay, then live output),
/// and what is typed into it goes to the host.
struct TerminalSurface: UIViewRepresentable {
    let session: MobileTerminalSession
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func makeUIView(context: Context) -> TerminalSurfaceView {
        let view = session.surface ?? TerminalSurfaceView(session: session)
        session.surface = view
        view.apply(colorScheme: colorScheme)
        return view
    }

    func updateUIView(_ view: TerminalSurfaceView, context: Context) {
        view.apply(colorScheme: colorScheme)
        // A new text size re-reads the font (and so the grid the host gets).
        _ = dynamicTypeSize
        view.applyFont()
    }
}

/// SwiftTerm's view with Shepherd's colors and font, reporting its grid, its title and whether
/// it has the keyboard to its session. The key row replaces SwiftTerm's own input accessory.
final class TerminalSurfaceView: TerminalView, TerminalViewDelegate {
    private weak var session: MobileTerminalSession?
    private var scheme: ColorScheme?
    private var fontSize: CGFloat = 0

    init(session: MobileTerminalSession) {
        self.session = session
        super.init(frame: .zero)
        terminalDelegate = self
        inputAccessoryView = nil
        optionAsMetaKey = true
        backgroundColor = .clear
        isOpaque = false
        applyFont()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var applicationCursor: Bool { getTerminal().applicationCursor }

    func feed(_ data: Data) {
        feed(byteArray: ArraySlice(data))
    }

    /// Clears the screen and scrollback before the host's replay.
    func reset() {
        getTerminal().resetToInitialState()
        setNeedsDisplay()
    }

    func latch(control: Bool, option: Bool) {
        if controlModifier != control { controlModifier = control }
        if metaModifier != option { metaModifier = option }
    }

    /// The code size of the type ramp, following Dynamic Type up to a size that still leaves a
    /// usable grid.
    func applyFont() {
        let base = NWTextStyle.code.size
        let size = UIFontMetrics(forTextStyle: .callout).scaledValue(for: base, compatibleWith: traitCollection)
        let clamped = min(size, MobileLayout.terminalMaximumFontSize)
        guard clamped != fontSize else { return }
        fontSize = clamped
        func face(_ name: String) -> UIFont {
            UIFont(name: name, size: clamped) ?? .monospacedSystemFont(ofSize: clamped, weight: .regular)
        }
        let regular = face("GeistMono-Regular")
        let bold = face("GeistMono-SemiBold")
        setFonts(normal: regular, bold: bold, italic: regular, boldItalic: bold)
    }

    /// Night Watch's terminal palette for the appearance: its window surface, text, lantern cursor,
    /// selection, and the 16 ANSI colors.
    func apply(colorScheme: ColorScheme) {
        guard scheme != colorScheme else { return }
        scheme = colorScheme
        let variant = ThemeStore.shared.theme.variant(dark: colorScheme == .dark)
        let colors = variant.terminal
        nativeBackgroundColor = UIColor(hex: colors.background)
        nativeForegroundColor = UIColor(hex: colors.foreground)
        caretColor = UIColor(hex: colors.cursor)
        if let selection = colors.selectionBackground { selectedTextBackgroundColor = UIColor(hex: selection) }
        installColors(colors.palette.compactMap(HexColor.init).map {
            SwiftTerm.Color(red: UInt16($0.red * 65535), green: UInt16($0.green * 65535), blue: UInt16($0.blue * 65535))
        })
        indicatorStyle = colorScheme == .dark ? .white : .black
        keyboardAppearance = colorScheme == .dark ? .dark : .light
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { session?.focused = true }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { session?.focused = false }
        return resigned
    }

    // MARK: TerminalViewDelegate

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        // A canned screen (fixtures) is drawn again at each grid, as the host's replay would be.
        if let canned = session?.canned {
            reset()
            feed(canned)
        }
        session?.noteGrid(cols: newCols, rows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        session?.titleChanged(title)
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        session?.send(Array(data))
        // A typed key uses up the key row's latched modifiers, as SwiftTerm's own do.
        if session?.control == true { session?.control = false }
        if session?.option == true { session?.option = false }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        UIApplication.shared.open(url)
    }
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

private extension UIColor {
    convenience init(hex: String) {
        let color = HexColor(hex) ?? HexColor(red: 0, green: 0, blue: 0, alpha: 1)
        self.init(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }
}
