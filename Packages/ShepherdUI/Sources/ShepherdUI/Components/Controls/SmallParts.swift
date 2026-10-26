import SwiftUI

/// Keycaps for a real, wired shortcut: `SHKeycap("⇧⌘B")` draws one cap per key. Menus, the
/// palette, and settings only; never under the composer, never for an unwired chord.
public struct SHKeycap: View {
    let keys: [String]
    @Environment(\.displayScale) private var displayScale
    @Environment(\.shControlScale) private var scale

    /// Splits a display chord ("⇧⌘N") into caps: each modifier, then the key.
    public init(_ chord: String) {
        var caps: [String] = []
        var rest = Substring(chord)
        while let first = rest.first, "⌃⌥⇧⌘".contains(first) {
            caps.append(String(first))
            rest = rest.dropFirst()
        }
        if !rest.isEmpty { caps.append(String(rest).uppercased()) }
        keys = caps
    }

    /// Explicit caps (["⌘", "1–9"]).
    public init(keys: [String]) { self.keys = keys }

    public var body: some View {
        let sh = Color.sh
        // The Settings boards' caps: 22pt at radius 5, mono 11.5 in `textPrimary`, 4pt apart.
        let settings = scale == .settings
        let M = SHSettingsControlMetrics.self
        let side: CGFloat = settings ? M.keycapHeight : 18
        let radius = settings ? M.keycapRadius : SH.Radius.xs
        HStack(spacing: settings ? M.keycapSpacing : 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.shMono(settings ? M.keycapTextSize : 10.5))
                    .foregroundStyle(settings ? sh.textPrimary : sh.textSecondary)
                    .padding(.horizontal, settings ? M.keycapPadding : SH.Space.xs)
                    .frame(minWidth: side, minHeight: side)
                    .background(sh.bgRaised, in: RoundedRectangle(cornerRadius: radius))
                    .shBorder(sh.lineStrong, radius: radius)
                    // The board's heavier bottom edge (1.5px against 1px): a cap, not a box. A
                    // second hairline just above the border's, since a device pixel does not split.
                    .overlay(alignment: .bottom) {
                        SHHairline(color: sh.lineStrong)
                            .padding(.horizontal, radius)
                            .padding(.bottom, SH.hairline(displayScale))
                    }
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(keys.joined())
    }
}

/// A count ("19", "3"): neutral, needs-you, or failed (Controls board).
public struct SHCountBadge: View {
    public enum Tone: Sendable { case neutral, attention, failed }

    let count: Int
    let tone: Tone

    public init(_ count: Int, tone: Tone = .neutral) {
        self.count = count
        self.tone = tone
    }

    public var body: some View {
        let sh = Color.sh
        let (fill, text): (Color, Color) = switch tone {
        case .neutral: (sh.bgSelected, sh.textSecondary)
        case .attention: (sh.lantern, sh.textOnLantern)
        case .failed: (sh.failed, sh.textOnFailed)
        }
        Text("\(count)")
            .font(.shMono(10, .semibold))
            .monospacedDigit()
            .foregroundStyle(text)
            .shContentTransition(.numeric())
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 16)
            .background(fill, in: Capsule())
            .fixedSize()
            .shComponentAnimation(.content, value: count)
            .shComponentAnimation(.content, value: tone)
    }
}

/// A small tag for roles, models, kinds ("worker", "claude-sonnet", "prompt").
public struct SHTag: View {
    let text: String
    let mono: Bool
    let foreground: Color?

    /// `foreground` recolors the word (a file status letter in its state color).
    public init(_ text: String, mono: Bool = false, foreground: Color? = nil) {
        self.text = text
        self.mono = mono
        self.foreground = foreground
    }

    public var body: some View {
        Text(text)
            .font(mono ? .shMono(10.5) : .shSans(11))
            .foregroundStyle(foreground ?? .sh.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, SH.Space.s)
            .frame(height: 18)
            .background(Color.sh.bgSelected, in: RoundedRectangle(cornerRadius: SH.Radius.xs))
            .fixedSize()
    }
}

extension View {
    /// Hover help with its shortcut ("Review changes ⇧⌘B"). Rendered by the system tooltip.
    public func shHelp(_ label: String, shortcut: String? = nil) -> some View {
        help(shortcut.map { "\(label)  \($0)" } ?? label)
    }
}
