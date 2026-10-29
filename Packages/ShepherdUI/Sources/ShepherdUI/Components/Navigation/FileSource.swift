import SwiftUI

// A read-only file's text and its loading/failure notice, as the iPhone and iPad Files pane draws them.

public enum SHFileMetrics {
    /// A document sits 18pt in from the pane's edge.
    public static let documentInset: CGFloat = 18
    /// The most a file's source draws: more is cut with a note, so a megabyte of text is never laid out as one view.
    public static let sourceCharacterLimit = 200_000
}

/// A file's source: the text in mono on `bgSunken`, selectable, cut at `SHFileMetrics.sourceCharacterLimit` with a note.
public struct SHFileSource: View {
    let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        let sh = Color.sh
        let cut = text.count > SHFileMetrics.sourceCharacterLimit
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: SH.Space.m) {
                Text(cut ? String(text.prefix(SHFileMetrics.sourceCharacterLimit)) : text)
                    .font(.sh(.code))
                    .foregroundStyle(sh.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                if cut {
                    Text("Showing the first \(SHFileMetrics.sourceCharacterLimit.formatted()) characters.")
                        .font(.sh(.caption)).foregroundStyle(sh.textTertiary)
                }
            }
            .padding(SHFileMetrics.documentInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(sh.bgSunken)
    }
}

/// What an open file shows while its file is on its way, or when it cannot be had.
public struct SHFileNotice: View {
    public enum Kind: Equatable, Sendable { case loading, unavailable, failed(String) }
    let kind: Kind
    let retry: (() -> Void)?

    public init(_ kind: Kind, retry: (() -> Void)? = nil) {
        self.kind = kind
        self.retry = retry
    }

    public var body: some View {
        let sh = Color.sh
        VStack(spacing: SH.Space.m) {
            switch kind {
            case .loading:
                Text("Opening…").font(.sh(.ui)).foregroundStyle(sh.textTertiary)
            case .unavailable:
                Text("This file isn’t available").font(.sh(.headline)).foregroundStyle(sh.textPrimary)
                Text("It was moved or deleted, it is too large to open here, or the host can’t serve it.")
                    .font(.sh(.caption)).foregroundStyle(sh.textTertiary).multilineTextAlignment(.center)
            case .failed(let message):
                Text(message).font(.sh(.ui)).foregroundStyle(sh.textSecondary).multilineTextAlignment(.center)
                if let retry { Button("Try again", action: retry).buttonStyle(.sh(.secondary, size: .s)) }
            }
        }
        .padding(SH.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(sh.bgWindow)
        .accessibilityElement(children: .contain)
    }
}
