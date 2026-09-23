import SwiftUI

/// "+58 −41": additions in `done`, removals in `failed`, mono, with a true minus sign.
public struct NWDiffStat: View {
    let added: Int
    let removed: Int
    let font: Font?

    public init(added: Int, removed: Int, font: Font? = nil) {
        self.added = added
        self.removed = removed
        self.font = font
    }

    public var body: some View {
        HStack(spacing: NW.Space.s) {
            Text("+\(added)").foregroundStyle(.nw.done)
            Text("\u{2212}\(removed)").foregroundStyle(.nw.failed)
        }
        .font(font ?? .nw(.mono))
        .monospacedDigit()
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(added) added, \(removed) removed")
    }
}

/// Code in prose: mono on `bgSunken` with a 1px line.
public struct NWInlineCode: View {
    let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text)
            .font(.nwMono(12.5))
            .foregroundStyle(.nw.textPrimary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.nw.bgSunken, in: RoundedRectangle(cornerRadius: NW.Radius.xs))
            .nwBorder(.nw.lineSubtle, radius: NW.Radius.xs)
    }
}

/// A file or image queued with the next message, removable.
public struct NWAttachmentChip: View {
    let name: String
    let prefix: String?
    let remove: () -> Void

    public init(_ name: String, prefix: String? = nil, remove: @escaping () -> Void) {
        self.name = name
        self.prefix = prefix
        self.remove = remove
    }

    public var body: some View {
        let nw = Color.nw
        HStack(spacing: NW.Space.m) {
            HStack(spacing: 0) {
                if let prefix { Text(prefix).foregroundStyle(nw.textTertiary) }
                Text(name).foregroundStyle(nw.textPrimary)
            }
            .font(.nw(.mono))
            .lineLimit(1)
            .truncationMode(.middle)
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(nw.textTertiary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(name)")
        }
        .padding(.leading, 10)
        .padding(.trailing, NW.Space.s)
        .frame(height: NW.Height.controlM)
        .nwCard(radius: NW.Radius.s)
    }
}
