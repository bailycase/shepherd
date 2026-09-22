import SwiftUI

/// ComposerChip: a 32pt ghost chip in the composer's action row (model, thinking, commands).
public struct ComposerChipStyle: ButtonStyle {
    let active: Bool

    public init(active: Bool = false) { self.active = active }

    public func makeBody(configuration: Configuration) -> some View {
        Chip(configuration: configuration, active: active)
    }

    private struct Chip: View {
        let configuration: ButtonStyleConfiguration
        let active: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(Fonts.caption)
                .foregroundStyle(Tokens.textSecondary)
                .padding(.horizontal, 10)
                .frame(height: Metrics.chipHeight)
                .background(active || hovering ? Tokens.bgHover : .clear, in: RoundedRectangle(cornerRadius: Radius.md))
                .contentShape(RoundedRectangle(cornerRadius: Radius.md))
                .onHover { hovering = $0 }
        }
    }
}

/// The down chevron chips and popups use.
public struct ChipChevron: View {
    public init() {}
    public var body: some View {
        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(Tokens.textMuted)
    }
}

/// AttachmentChip: a file or image queued with the next message, removable.
public struct AttachmentChip: View {
    let name: String
    var prefix: String?
    let remove: () -> Void

    public init(_ name: String, prefix: String? = nil, remove: @escaping () -> Void) {
        self.name = name
        self.prefix = prefix
        self.remove = remove
    }

    public var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                if let prefix { Text(prefix).foregroundStyle(Tokens.textMuted) }
                Text(name).foregroundStyle(Tokens.text)
            }
            .font(Fonts.mono(12))
            .lineLimit(1)
            .truncationMode(.middle)
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Tokens.textMuted)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(name)")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: Metrics.attachmentChipHeight)
        .background(Tokens.bgSurface, in: RoundedRectangle(cornerRadius: Radius.sm))
        .overlay(RoundedRectangle(cornerRadius: Radius.sm).strokeBorder(Tokens.border, lineWidth: 1))
    }
}

/// Small bordered tag ("prompt", a file status letter).
public struct Tag: View {
    let text: String
    var color: Color?

    public init(_ text: String, color: Color? = nil) {
        self.text = text
        self.color = color
    }

    public var body: some View {
        Text(text)
            .font(Fonts.mono(10.5))
            .foregroundStyle(color ?? Tokens.textMuted)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: Radius.xs).strokeBorder(Tokens.border, lineWidth: 1))
            .fixedSize()
    }
}

/// Inline code in prose: code face on bgHover with a subtle border.
public struct InlineCode: View {
    let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text)
            .font(Fonts.mono(13))
            .foregroundStyle(Tokens.text)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Tokens.bgHover, in: RoundedRectangle(cornerRadius: Radius.xs))
            .overlay(RoundedRectangle(cornerRadius: Radius.xs).strokeBorder(Tokens.border, lineWidth: 1))
    }
}
