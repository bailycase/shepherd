import SwiftUI

/// Keycaps for a real, wired shortcut: `NWKeycap("⇧⌘B")` draws one cap per key. Menus, the
/// palette, and settings only; never under the composer, never for an unwired chord.
public struct NWKeycap: View {
    let keys: [String]
    @Environment(\.displayScale) private var displayScale

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
        let nw = Color.nw
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.nwMono(10.5))
                    .foregroundStyle(nw.textSecondary)
                    .padding(.horizontal, NW.Space.xs)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(nw.bgRaised, in: RoundedRectangle(cornerRadius: NW.Radius.xs))
                    .nwBorder(nw.lineStrong, radius: NW.Radius.xs)
                    // The board's heavier bottom edge (1.5px against 1px): a cap, not a box. A
                    // second hairline just above the border's, since a device pixel does not split.
                    .overlay(alignment: .bottom) {
                        NWHairline(color: nw.lineStrong)
                            .padding(.horizontal, NW.Radius.xs)
                            .padding(.bottom, NW.hairline(displayScale))
                    }
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(keys.joined())
    }
}

/// A count ("19", "3"): neutral, needs-you, or failed (Controls board).
public struct NWCountBadge: View {
    public enum Tone: Sendable { case neutral, attention, failed }

    let count: Int
    let tone: Tone

    public init(_ count: Int, tone: Tone = .neutral) {
        self.count = count
        self.tone = tone
    }

    public var body: some View {
        let nw = Color.nw
        let (fill, text): (Color, Color) = switch tone {
        case .neutral: (nw.bgSelected, nw.textSecondary)
        case .attention: (nw.lantern, nw.textOnLantern)
        case .failed: (nw.failed, nw.textOnFailed)
        }
        Text("\(count)")
            .font(.nwMono(10, .semibold))
            .monospacedDigit()
            .foregroundStyle(text)
            .nwContentTransition(.numeric())
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 16)
            .background(fill, in: Capsule())
            .fixedSize()
            .nwComponentAnimation(.content, value: count)
            .nwComponentAnimation(.content, value: tone)
    }
}

/// A small tag for roles, models, kinds ("worker", "claude-sonnet", "prompt").
public struct NWTag: View {
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
            .font(mono ? .nwMono(10.5) : .nwSans(11))
            .foregroundStyle(foreground ?? .nw.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, NW.Space.s)
            .frame(height: 18)
            .background(Color.nw.bgSelected, in: RoundedRectangle(cornerRadius: NW.Radius.xs))
            .fixedSize()
    }
}

extension View {
    /// Hover help with its shortcut ("Review changes ⇧⌘B"). Rendered by the system tooltip.
    public func nwHelp(_ label: String, shortcut: String? = nil) -> some View {
        help(shortcut.map { "\(label)  \($0)" } ?? label)
    }
}
