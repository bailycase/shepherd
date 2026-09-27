import SwiftUI

// The first launch's sheet (PiImport*) and the sign-in sheet (SignIn*): their header and footer,
// the import's steps and summary, and the sign-in's steps, code and boxes.

/// A sheet's header: a 38pt tile (a state's glyph, or a provider's badge), the title in 17/600
/// over the subtitle, and a close button when it has one.
public struct NWSheetHeader<Subtitle: View>: View {
    public enum Leading: Equatable, Sendable {
        /// A glyph on its tone's tile.
        case glyph(String, Tone)
        /// A provider's monogram.
        case badge(String)
    }

    public enum Tone: Sendable { case neutral, done, attention, failed }

    let leading: Leading
    let title: String
    let subtitle: Subtitle
    let close: (() -> Void)?

    public init(_ title: String, leading: Leading, close: (() -> Void)? = nil, @ViewBuilder subtitle: () -> Subtitle) {
        self.title = title
        self.leading = leading
        self.close = close
        self.subtitle = subtitle()
    }

    public var body: some View {
        let nw = Color.nw
        let M = NWPiSignInMetrics.self
        HStack(alignment: .top, spacing: 14) {
            tile
            VStack(alignment: .leading, spacing: NW.Space.xs) {
                Text(title)
                    .font(.nwSans(M.sheetTitleSize, .semibold))
                    .foregroundStyle(nw.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                subtitle
            }
            .padding(.top, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            if let close {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.nwSans(12, .medium))
                        .foregroundStyle(nw.textSecondary)
                        .frame(width: M.closeButton, height: M.closeButton)
                        .overlay(Circle().strokeBorder(nw.lineStrong, lineWidth: 1))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close")
            }
        }
        .padding(.top, M.sheetInset)
        .padding(.leading, M.sheetInset)
        .padding(.trailing, M.sheetTrailing)
    }

    @ViewBuilder private var tile: some View {
        let nw = Color.nw
        let M = NWPiSignInMetrics.self
        switch leading {
        case .badge(let letters):
            NWProviderBadge(letters, size: M.sheetTile)
        case .glyph(let name, let tone):
            let (fill, ink, line): (Color, Color, Color?) = switch tone {
            case .neutral: (nw.bgRaised, nw.textSecondary, nw.lineStrong)
            case .done: (nw.doneTint, nw.done, nil)
            case .attention: (nw.lanternTint, nw.lanternText, nil)
            case .failed: (nw.failedTint, nw.failed, nil)
            }
            Image(systemName: name)
                .font(.nwSans(17, .medium))
                .foregroundStyle(ink)
                .frame(width: M.sheetTile, height: M.sheetTile)
                .background(fill, in: RoundedRectangle(cornerRadius: M.sheetTileRadius))
                .overlay { if let line { RoundedRectangle(cornerRadius: M.sheetTileRadius).strokeBorder(line, lineWidth: 1) } }
                .accessibilityHidden(true)
        }
    }
}

extension NWSheetHeader where Subtitle == NWSheetSubtitle {
    public init(_ title: String, subtitle: String, leading: Leading, close: (() -> Void)? = nil) {
        self.init(title, leading: leading, close: close) { NWSheetSubtitle(subtitle) }
    }
}

/// A sheet's subtitle: 13/1.5 `textSecondary`.
public struct NWSheetSubtitle: View {
    let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .nwText(size: NWPiSignInMetrics.sheetSubtitleSize, lineHeight: 1.5)
            .foregroundStyle(Color.nw.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A sheet's footer: on `bgSunken` over a hairline, its leading part, then its actions trailing.
public struct NWSheetFooter<Leading: View, Actions: View>: View {
    let leading: Leading
    let actions: Actions

    public init(@ViewBuilder leading: () -> Leading, @ViewBuilder actions: () -> Actions) {
        self.leading = leading()
        self.actions = actions()
    }

    public var body: some View {
        let M = NWPiSignInMetrics.self
        HStack(spacing: NW.Space.m) {
            leading
            Spacer(minLength: NW.Space.l)
            HStack(spacing: NW.Space.m) { actions }.fixedSize()
        }
        .padding(.top, M.footerTop)
        .padding(.bottom, M.footerBottom)
        .padding(.leading, M.sheetInset)
        .padding(.trailing, M.footerTrailing)
        .frame(maxWidth: .infinity)
        .background(Color.nw.bgSunken)
        .overlay(alignment: .top) { NWHairline() }
    }
}

extension NWSheetFooter where Leading == EmptyView {
    public init(@ViewBuilder actions: () -> Actions) {
        self.init(leading: { EmptyView() }, actions: actions)
    }
}

/// A card of rows: `bgSunken`, radius 10, a `lineSubtle` line, hairlines between.
public struct NWSheetCard<Content: View>: View {
    let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        let M = NWPiSignInMetrics.self
        VStack(alignment: .leading, spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { NWHairline() }
                    row
                }
            }
        }
        .background(Color.nw.bgSunken, in: RoundedRectangle(cornerRadius: M.cardRadius))
        .nwBorder(Color.nw.lineSubtle, radius: M.cardRadius)
    }
}

/// A step's mark: done, now, pending, failed (the import's and the sign-in's).
public enum NWStepState: Equatable, Sendable {
    case done, now, pending, failed
}

/// An 18pt step mark: a check on `doneTint`, a `running` ring and dot, a `lineStrong` ring, a
/// cross on `failedTint`.
public struct NWStepMark: View {
    let state: NWStepState

    public init(_ state: NWStepState) {
        self.state = state
    }

    public var body: some View {
        let nw = Color.nw
        let M = NWPiSignInMetrics.self
        ZStack {
            switch state {
            case .done:
                Circle().fill(nw.doneTint)
                Image(systemName: "checkmark").font(.nwSans(9, .bold)).foregroundStyle(nw.done)
            case .failed:
                Circle().fill(nw.failedTint)
                Image(systemName: "xmark").font(.nwSans(9, .bold)).foregroundStyle(nw.failed)
            case .now:
                Circle().strokeBorder(nw.running, lineWidth: 1.5)
                Circle().fill(nw.running).frame(width: 6, height: 6)
            case .pending:
                Circle().strokeBorder(nw.lineStrong, lineWidth: 1.5)
            }
        }
        .frame(width: M.stepMark, height: M.stepMark)
        .accessibilityHidden(true)
    }
}

/// One item of the first launch's copy (`PiImportStepRow(item, step)`): its mark, the title over
/// its detail, and, once done, a count in mono trailing. Now shimmers; nothing spins.
public struct NWImportStepRow: View, Equatable {
    let title: String
    let detail: String?
    let count: String?
    let state: NWStepState

    public init(_ title: String, detail: String? = nil, count: String? = nil, state: NWStepState) {
        self.title = title
        self.detail = detail
        self.count = count
        self.state = state
    }

    public var body: some View {
        let nw = Color.nw
        let M = NWPiSignInMetrics.self
        HStack(spacing: M.rowGap) {
            NWStepMark(state)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.nwSans(M.stepTitleSize, state == .now ? .medium : .regular))
                    .nwShimmer(active: state == .now)
                    .foregroundStyle(state == .pending ? nw.textTertiary : nw.textPrimary)
                if let detail {
                    Text(detail)
                        .font(.nwSans(M.stepDetailSize))
                        .foregroundStyle(state == .failed ? nw.failed : nw.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let count {
                Text(count)
                    .font(.nwMono(M.stepCountSize))
                    .foregroundStyle(state == .done ? nw.textSecondary : nw.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.vertical, NW.Space.s)
        .padding(.horizontal, 14)
        .frame(minHeight: M.stepMinHeight)
        .nwAnimation(.content, value: state)
        .accessibilityElement(children: .combine)
        .accessibilityValue(Self.word(state))
    }

    static func word(_ state: NWStepState) -> String {
        switch state {
        case .done: "brought over"
        case .now: "bringing over"
        case .pending: "waiting"
        case .failed: "failed"
        }
    }
}

/// What came over, in one line (`PiImportSummary(result)`): counts in 600 `textPrimary`, the rest
/// `textSecondary`, "·" in `textTertiary` between.
public struct NWImportSummary: View {
    public struct Part: Equatable, Sendable {
        public var count: Int?
        public var words: String
        /// A mono value after the words ("default model `claude-opus`").
        public var value: String?

        public init(_ words: String, count: Int? = nil, value: String? = nil) {
            self.count = count
            self.words = words
            self.value = value
        }
    }

    let parts: [Part]
    let size: CGFloat
    let quiet: Bool

    /// `quiet` draws it smaller and tertiary (Something missing's line under the card).
    public init(_ parts: [Part], size: CGFloat = NWPiSignInMetrics.sheetSubtitleSize, quiet: Bool = false) {
        self.parts = parts
        self.size = size
        self.quiet = quiet
    }

    public var body: some View {
        text
            .font(.nwSans(size))
            .lineSpacing(size * (NWPiSignInMetrics.summaryLineHeight - 1.2))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var text: Text {
        let nw = Color.nw
        let rest = quiet ? nw.textTertiary : nw.textSecondary
        var result = Text("")
        for (index, part) in parts.enumerated() {
            if index > 0 { result = result + Text(" · ").foregroundColor(nw.textTertiary) }
            if let count = part.count {
                result = result + Text("\(count)").fontWeight(.semibold).foregroundColor(nw.textPrimary) + Text(" ")
            }
            result = result + Text(part.words).foregroundColor(rest)
            if let value = part.value {
                result = result + Text(" ") + Text(value).font(.nwMono(size - 0.5)).foregroundColor(nw.textPrimary)
            }
        }
        return result
    }
}

/// A provider that still needs a sign-in (`PiImportSignInRow(provider)`): its badge, name, why,
/// and Sign in; once signed in, a check and "Signed in".
public struct NWImportSignInRow: View {
    let name: String
    let badge: String
    let detail: String
    let signedIn: Bool
    let signingIn: Bool
    let signIn: () -> Void

    public init(_ name: String, badge: String, detail: String, signedIn: Bool = false, signingIn: Bool = false, signIn: @escaping () -> Void) {
        self.name = name
        self.badge = badge
        self.detail = detail
        self.signedIn = signedIn
        self.signingIn = signingIn
        self.signIn = signIn
    }

    public var body: some View {
        let nw = Color.nw
        let M = NWPiSignInMetrics.self
        HStack(spacing: M.rowGap) {
            NWProviderBadge(badge, size: M.badgeSmall)
            VStack(alignment: .leading, spacing: NW.Space.xxs) {
                Text(name).font(.nwSans(M.nameSize, .medium)).foregroundStyle(nw.textPrimary)
                Text(signedIn ? "Signed in" : signingIn ? "Signing in…" : detail)
                    .font(.nwSans(M.stepDetailSize))
                    .nwShimmer(active: signingIn)
                    .foregroundStyle(signedIn ? nw.done : nw.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if signedIn {
                NWStepMark(.done)
            } else {
                Button("Sign in", action: signIn)
                    .buttonStyle(.nw(.primary, size: .s))
                    .disabled(signingIn)
                    .accessibilityLabel("Sign in to \(name)")
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .nwAnimation(.content, value: signedIn)
    }
}

/// A new user's choice (PiImportNew): a provider's badge (or a glyph), its name over its plan, and
/// a chevron; the API-key tile is dashed.
public struct NWSignInChoiceTile: View {
    let title: String
    let detail: String
    let badge: String?
    let glyph: String?
    @State private var hovering = false

    public init(_ title: String, detail: String, badge: String? = nil, glyph: String? = nil) {
        self.title = title
        self.detail = detail
        self.badge = badge
        self.glyph = glyph
    }

    public var body: some View {
        let nw = Color.nw
        let M = NWPiSignInMetrics.self
        let dashed = badge == nil
        HStack(spacing: M.rowGap) {
            if let badge {
                NWProviderBadge(badge)
            } else {
                Image(systemName: glyph ?? "key")
                    .font(.nwSans(13))
                    .foregroundStyle(nw.textSecondary)
                    .frame(width: M.badge, height: M.badge)
                    .overlay(RoundedRectangle(cornerRadius: M.badgeRadius).strokeBorder(nw.lineStrong, lineWidth: 1))
            }
            VStack(alignment: .leading, spacing: NW.Space.xxs) {
                Text(title).font(.nwSans(M.nameSize, .medium)).foregroundStyle(nw.textPrimary)
                Text(detail).font(.nwSans(M.stepDetailSize)).foregroundStyle(nw.textTertiary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right").font(.nwSans(11, .medium)).foregroundStyle(nw.textTertiary)
        }
        .padding(.vertical, 11)
        .padding(.horizontal, NW.Space.l)
        .background(dashed ? Color.clear : (hovering ? nw.bgHover : nw.bgSunken), in: RoundedRectangle(cornerRadius: M.cardRadius))
        .nwBorder(dashed ? nw.lineStrong : nw.lineSubtle, in: RoundedRectangle(cornerRadius: M.cardRadius), dash: dashed ? [4, 3] : [])
        .contentShape(RoundedRectangle(cornerRadius: M.cardRadius))
        .onHover { hovering = $0 }
        .nwAnimation(.hover, value: hovering)
    }
}

/// One step of a sign-in (`SignInSheet`): its mark, its title (shimmering while it's the live one),
/// and a note under it.
public struct NWSignInStepRow: View {
    let title: String
    let note: String?
    let state: NWStepState

    public init(_ title: String, note: String? = nil, state: NWStepState) {
        self.title = title
        self.note = note
        self.state = state
    }

    public var body: some View {
        let nw = Color.nw
        let M = NWPiSignInMetrics.self
        HStack(alignment: .top, spacing: M.rowGap) {
            NWStepMark(state)
            VStack(alignment: .leading, spacing: NW.Space.xxs) {
                Text(title)
                    .font(.nwSans(M.stepTitleSize, state == .now ? .medium : .regular))
                    .nwShimmer(active: state == .now)
                    .foregroundStyle(state == .pending ? nw.textTertiary : nw.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let note {
                    Text(note)
                        .font(state == .failed ? .nwMono(11.5) : .nwSans(M.stepDetailSize))
                        .foregroundStyle(state == .failed ? nw.failed : nw.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .padding(.top, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The sign-in's steps in a card, 14 apart.
public struct NWSignInSteps<Content: View>: View {
    let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        let M = NWPiSignInMetrics.self
        VStack(alignment: .leading, spacing: 14) { content }
            .padding(.vertical, 14)
            .padding(.horizontal, NW.Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.nw.bgSunken, in: RoundedRectangle(cornerRadius: M.cardRadius))
            .nwBorder(Color.nw.lineSubtle, radius: M.cardRadius)
    }
}

/// A device sign-in's code, large: mono 26/600, tracked, centered in a `bgSunken` box.
public struct NWDeviceCode: View {
    let code: String
    let dimmed: Bool

    public init(_ code: String, dimmed: Bool = false) {
        self.code = code
        self.dimmed = dimmed
    }

    public var body: some View {
        let M = NWPiSignInMetrics.self
        Text(code)
            .font(.nwMono(M.deviceCodeSize, .semibold))
            .tracking(M.deviceCodeSize * M.deviceCodeTracking)
            .foregroundStyle(dimmed ? Color.nw.textTertiary : Color.nw.textPrimary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity)
            .padding(.vertical, NW.Space.xl)
            .background(Color.nw.bgSunken, in: RoundedRectangle(cornerRadius: M.cardRadius))
            .nwBorder(Color.nw.lineSubtle, radius: M.cardRadius)
            .accessibilityLabel("Code \(code.map(String.init).joined(separator: " "))")
    }
}

/// What failed, in a `failed` box: a line in `textPrimary` (a path in mono, or a title) and the
/// reason under it.
public struct NWFailureBox: View {
    let title: String
    let detail: String?
    let monoTitle: Bool
    let monoDetail: Bool

    public init(_ title: String, detail: String? = nil, monoTitle: Bool = false, monoDetail: Bool = false) {
        self.title = title
        self.detail = detail
        self.monoTitle = monoTitle
        self.monoDetail = monoDetail
    }

    public var body: some View {
        let nw = Color.nw
        let M = NWPiSignInMetrics.self
        VStack(alignment: .leading, spacing: NW.Space.s) {
            Text(title)
                .font(monoTitle ? .nwMono(12) : .nwSans(13, .medium))
                .foregroundStyle(nw.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .font(monoDetail ? .nwMono(11.5) : .nwSans(12.5))
                    .foregroundStyle(monoDetail ? nw.failed : nw.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .textSelection(.enabled)
        .padding(.vertical, 10)
        .padding(.horizontal, NW.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(nw.failedTint.opacity(M.failureFillOpacity), in: RoundedRectangle(cornerRadius: 9))
        .nwBorder(nw.failed.opacity(M.failureLineOpacity), radius: 9)
    }
}

/// A note in a quiet card: a glyph, then its text and an optional link under it.
public struct NWNoteCard<Text_: View>: View {
    let glyph: String
    let text: Text_
    let link: String?
    let action: (() -> Void)?

    public init(glyph: String, link: String? = nil, action: (() -> Void)? = nil, @ViewBuilder text: () -> Text_) {
        self.glyph = glyph
        self.text = text()
        self.link = link
        self.action = action
    }

    public var body: some View {
        let nw = Color.nw
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: glyph).font(.nwSans(13)).foregroundStyle(nw.textSecondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: NW.Space.xs) {
                text
                if let link, let action {
                    Button(link, action: action).buttonStyle(.nwLink)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, NW.Space.l)
        .background(nw.bgSunken, in: RoundedRectangle(cornerRadius: 9))
        .nwBorder(nw.lineSubtle, radius: 9)
    }
}

/// A field's label over it: 11.5/500 `textSecondary`, 6 above.
public struct NWFieldLabel: View {
    let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(.nwSans(NWPiSignInMetrics.fieldLabelSize, .medium))
            .foregroundStyle(Color.nw.textSecondary)
    }
}
