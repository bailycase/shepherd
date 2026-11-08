import SwiftUI
#if canImport(AppKit)
import AppKit
public typealias SHPlatformFont = NSFont
private typealias PlatformColor = NSColor
private typealias PlatformImage = NSImage
#else
import UIKit
public typealias SHPlatformFont = UIFont
private typealias PlatformColor = UIColor
private typealias PlatformImage = UIImage
#endif

/// The composer's inline skill chip ("fix the login bug [debug] and add a test"), drawn in the
/// field's own text on the Mac and on iPhone and iPad: `SHGlyph.skill` in `textSecondary` at
/// caption size, the name in Geist Mono at code size in `textPrimary`, on `bgSunken` with a 1px
/// `lineStrong` line at radius 4, 6pt sides, 4pt between, 2pt above and below the name.
public enum SHSkillChipMetrics {
    /// A long skill name truncates here (at 100% text size).
    public static let nameMaxWidth: CGFloat = 200
}

/// One skill in a composer field's text: a single attachment character drawn as the chip, so it
/// moves, selects and deletes as one piece and the caret never lands inside it. `token` is what
/// the draft spells for it ("/skill:debug").
public final class SHSkillChipAttachment: NSTextAttachment {
    public let token: String

    /// Drawn for `font`, the field's text font, in `dark` or light (iOS bakes its colors; the
    /// Mac's follow the field's appearance as they draw).
    @MainActor public init(token: String, name: String, font: SHPlatformFont, dark: Bool) {
        self.token = token
        super.init(data: nil, ofType: nil)
        let sh = Color.sh
        let scale = font.pointSize / SHTextStyle.body.size
        let monoSize = SHTextStyle.code.size * scale
        let mono = SHPlatformFont(name: SHFonts.postScriptName(mono: true, weight: .regular), size: monoSize)
            ?? .monospacedSystemFont(ofSize: monoSize, weight: .regular)
        #if canImport(AppKit)
        func color(_ color: Color) -> PlatformColor { PlatformColor(color) }
        let glyph = PlatformImage(systemSymbolName: SHGlyph.skill.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: SHTextStyle.caption.size * scale, weight: .medium)
                .applying(.init(paletteColors: [color(sh.textSecondary)])))
        #else
        let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        func color(_ color: Color) -> PlatformColor { PlatformColor(color).resolvedColor(with: traits) }
        let glyph = PlatformImage(systemName: SHGlyph.skill.symbolName,
                                  withConfiguration: UIImage.SymbolConfiguration(pointSize: SHTextStyle.caption.size * scale, weight: .medium))?
            .withTintColor(color(sh.textSecondary), renderingMode: .alwaysOriginal)
        #endif
        let label = NSAttributedString(string: name, attributes: [.font: mono, .foregroundColor: color(sh.textPrimary)])
        let fill = color(sh.bgSunken), line = color(sh.lineStrong)
        let pad = SH.Space.s, gap = SH.Space.xs
        let glyphSize = glyph?.size ?? .zero
        let textWidth = min(ceil(label.size().width), SHSkillChipMetrics.nameMaxWidth * scale)
        let textHeight = ceil(mono.ascender - mono.descender)
        let size = CGSize(width: pad + glyphSize.width + gap + textWidth + pad, height: textHeight + 2 * SH.Space.xxs)
        // Top-down coordinates on both platforms.
        func draw(_ rect: CGRect) {
            let shape = Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: SH.Radius.xs).cgPath
            #if canImport(AppKit)
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            #else
            guard let context = UIGraphicsGetCurrentContext() else { return }
            #endif
            context.addPath(shape)
            context.setFillColor(fill.cgColor)
            context.fillPath()
            context.addPath(shape)
            context.setStrokeColor(line.cgColor)
            context.setLineWidth(1)
            context.strokePath()
            glyph?.draw(in: CGRect(x: pad, y: (rect.height - glyphSize.height) / 2, width: glyphSize.width, height: glyphSize.height))
            label.draw(with: CGRect(x: pad + glyphSize.width + gap, y: (rect.height - textHeight) / 2, width: textWidth, height: textHeight),
                       options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
        }
        #if canImport(AppKit)
        image = NSImage(size: size, flipped: true) { rect in draw(rect); return true }
        image?.accessibilityDescription = "Skill \(name)"
        #else
        image = UIGraphicsImageRenderer(size: size).image { _ in draw(CGRect(origin: .zero, size: size)) }
        image?.accessibilityLabel = "Skill \(name)"
        #endif
        // Centered on the words' x-height, so the chip sits in the line, not on its baseline.
        bounds = CGRect(x: 0, y: (font.xHeight - size.height) / 2, width: size.width, height: size.height)
    }

    required init?(coder: NSCoder) { nil }
}

/// A composer field's text with its skills as chips, and back: the draft stays plain text and
/// the field shows `tokens` (the draft's skill ranges) each as one `SHSkillChipAttachment`.
public enum SHSkillChips {
    /// `text` with each of `tokens` as a chip named by `name`, in `attributes` (which must hold
    /// the field's `.font`); nil when there are none.
    @MainActor public static func attributed(_ text: String, tokens: [Range<String.Index>], name: (Substring) -> String,
                                             attributes: [NSAttributedString.Key: Any], dark: Bool = false) -> NSAttributedString? {
        guard !tokens.isEmpty, let font = attributes[.font] as? SHPlatformFont else { return nil }
        let result = NSMutableAttributedString()
        var at = text.startIndex
        for range in tokens {
            result.append(NSAttributedString(string: String(text[at..<range.lowerBound]), attributes: attributes))
            let chip = NSMutableAttributedString(attachment: SHSkillChipAttachment(token: String(text[range]), name: name(text[range]),
                                                                                    font: font, dark: dark))
            chip.addAttributes(attributes, range: NSRange(location: 0, length: chip.length))
            result.append(chip)
            at = range.upperBound
        }
        result.append(NSAttributedString(string: String(text[at...]), attributes: attributes))
        return result
    }

    /// The draft the field's text spells: each chip as its token. A native string, each run of the
    /// storage read in one bulk copy: Swift walks and compares a bridged UTF-16 string on the slow
    /// path, and transcodes one character at a time.
    public static func text(of attributed: NSAttributedString) -> String {
        var text = ""
        let string = attributed.string as NSString
        attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            if let chip = value as? SHSkillChipAttachment {
                text += String(repeating: chip.token, count: range.length)
            } else {
                text += native(string, range)
            }
        }
        return text
    }

    private static func native(_ string: NSString, _ range: NSRange) -> String {
        guard range.length > 0 else { return "" }
        let units = [UInt16](unsafeUninitializedCapacity: range.length) { buffer, count in
            string.getCharacters(buffer.baseAddress!, range: range)
            count = range.length
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// A field range as a range of the draft: a chip spans its whole token.
    public static func draftRange(_ range: NSRange, in attributed: NSAttributedString) -> NSRange {
        let start = draftOffset(range.location, in: attributed)
        return NSRange(location: start, length: draftOffset(NSMaxRange(range), in: attributed) - start)
    }

    /// A draft range as a range of the field: an offset inside a chip's token lands after it.
    public static func fieldRange(_ range: NSRange, in attributed: NSAttributedString) -> NSRange {
        let start = fieldOffset(range.location, in: attributed)
        return NSRange(location: start, length: max(0, fieldOffset(NSMaxRange(range), in: attributed) - start))
    }

    private static func draftOffset(_ offset: Int, in attributed: NSAttributedString) -> Int {
        var extra = 0
        attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: min(offset, attributed.length))) { value, range, _ in
            if let chip = value as? SHSkillChipAttachment { extra += ((chip.token as NSString).length - 1) * range.length }
        }
        return offset + extra
    }

    private static func fieldOffset(_ offset: Int, in attributed: NSAttributedString) -> Int {
        var extra = 0, result: Int?
        attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, range, stop in
            guard let chip = value as? SHSkillChipAttachment else { return }
            for location in range.location..<NSMaxRange(range) {
                let draftStart = location + extra, length = (chip.token as NSString).length
                if offset <= draftStart { result = offset - extra; stop.pointee = true; return }
                if offset < draftStart + length { result = location + 1; stop.pointee = true; return }
                extra += length - 1
            }
        }
        return min(result ?? offset - extra, attributed.length)
    }
}

#if canImport(UIKit)
extension UIFont {
    /// A ramp style as a UIKit font, for a UIKit field beside SwiftUI text: the same face and size
    /// (`Font.sh`), scaled for `category` as Dynamic Type scales body text.
    @MainActor public static func sh(_ style: SHTextStyle, category: UIContentSizeCategory) -> UIFont {
        SHFonts.register()
        let size = style.size * ThemeStore.shared.textScale
        let base = UIFont(name: SHFonts.postScriptName(mono: style.isMonospaced, weight: style.weight), size: size)
            ?? (style.isMonospaced ? .monospacedSystemFont(ofSize: size, weight: .regular) : .systemFont(ofSize: size))
        return UIFontMetrics(forTextStyle: .body).scaledFont(for: base, compatibleWith: UITraitCollection(preferredContentSizeCategory: category))
    }
}
#endif
