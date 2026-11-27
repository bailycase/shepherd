import SwiftUI

// The first launch's sheet (PiImport*) and the sign-in sheet (SignIn*): their header and footer,
// the import's steps and summary, and the sign-in's steps, code and boxes.

/// A sheet's header: a 38pt tile (a state's glyph, or a provider's badge), the title in 17/600
/// over the subtitle, and a close button when it has one.
public struct SHSheetHeader<Subtitle: View>: View {
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
        let sh = Color.sh
        let M = SHPiSignInMetrics.self
        // The boards' sheet header: the title over its line, nothing beside them. Esc still closes.
        VStack(alignment: .leading, spacing: SH.Space.xs) {
            Text(title)
                .font(.shSans(M.sheetTitleSize, .semibold))
                .foregroundStyle(sh.textPrimary)
                .frame(minHeight: M.sheetTitleLine, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            subtitle
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, M.sheetTop)
        .padding(.horizontal, M.sheetInset)
        .background {
            if let close {
                Button("Close", action: close).keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder private var tile: some View {
        let sh = Color.sh
        let M = SHPiSignInMetrics.self
        switch leading {
        case .badge(let letters):
            SHProviderBadge(letters, size: M.sheetTile)
        case .glyph(let name, let tone):
            let (fill, ink, line): (Color, Color, Color?) = switch tone {
            case .neutral: (sh.bgRaised, sh.textSecondary, sh.lineStrong)
            case .done: (sh.doneTint, sh.done, nil)
            case .attention: (sh.lanternTint, sh.lanternText, nil)
            case .failed: (sh.failedTint, sh.failed, nil)
            }
            Image(systemName: name)
                .font(.shSans(17, .medium))
                .foregroundStyle(ink)
                .frame(width: M.sheetTile, height: M.sheetTile)
                .background(fill, in: RoundedRectangle(cornerRadius: M.sheetTileRadius))
                .overlay { if let line { RoundedRectangle(cornerRadius: M.sheetTileRadius).strokeBorder(line, lineWidth: 1) } }
                .accessibilityHidden(true)
        }
    }
}

extension SHSheetHeader where Subtitle == SHSheetSubtitle {
    public init(_ title: String, subtitle: String, leading: Leading, close: (() -> Void)? = nil) {
        self.init(title, leading: leading, close: close) { SHSheetSubtitle(subtitle) }
    }
}

/// A sheet's subtitle: 13/1.5 `textSecondary`.
public struct SHSheetSubtitle: View {
    let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .shSheetText(size: SHPiSignInMetrics.sheetSubtitleSize, lineHeight: SHPiSignInMetrics.sheetSubtitleLine)
            .foregroundStyle(Color.sh.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A sheet's footer: over a rule, its leading words, then its actions trailing.
public struct SHSheetFooter<Leading: View, Actions: View>: View {
    let leading: Leading
    let actions: Actions

    public init(@ViewBuilder leading: () -> Leading, @ViewBuilder actions: () -> Actions) {
        self.leading = leading()
        self.actions = actions()
    }

    public var body: some View {
        let M = SHPiSignInMetrics.self
        // The boards' foot: words 18 apart (the leading ones left, the actions right), the way out dim, the one action an
        // ink pill, over a rule, 56pt at least.
        HStack(spacing: M.footerGap) {
            HStack(spacing: M.footerGap) { leading }
            Spacer(minLength: SH.Space.l)
            HStack(spacing: M.footerGap) { actions }.fixedSize()
        }
        .shControlScale(.settings)
        .padding(.horizontal, M.sheetInset)
        .frame(maxWidth: .infinity, minHeight: M.footerHeight)
        .overlay(alignment: .top) { SHHairline(color: Color.sh.lineStrong, width: SHSettingsNavMetrics.borderWidth) }
    }
}

extension SHSheetFooter where Leading == EmptyView {
    public init(@ViewBuilder actions: () -> Actions) {
        self.init(leading: { EmptyView() }, actions: actions)
    }
}

/// The boards' list of rows: a rule above it and a rule under each row.
public struct SHSheetCard<Content: View>: View {
    let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { SHHairline(color: Color.sh.lineStrong, width: SHSettingsNavMetrics.borderWidth) }
    }
}

/// A step's mark: done, now, pending, failed (the import's and the sign-in's).
public enum SHStepState: Equatable, Sendable {
    case done, now, pending, failed
}

/// An 18pt step mark: a check on `doneTint`, a `running` ring and dot, a `lineStrong` ring, a
/// cross on `failedTint`.
public struct SHStepMark: View {
    let state: SHStepState

    public init(_ state: SHStepState) {
        self.state = state
    }

    public var body: some View {
        let sh = Color.sh
        let M = SHPiSignInMetrics.self
        ZStack {
            switch state {
            case .done:
                Circle().fill(sh.doneTint)
                Image(systemName: "checkmark").font(.shSans(9, .bold)).foregroundStyle(sh.done)
            case .failed:
                Circle().fill(sh.failedTint)
                Image(systemName: "xmark").font(.shSans(9, .bold)).foregroundStyle(sh.failed)
            case .now:
                Circle().strokeBorder(sh.running, lineWidth: 1.5)
                Circle().fill(sh.running).frame(width: 6, height: 6)
            case .pending:
                Circle().strokeBorder(sh.lineStrong, lineWidth: 1.5)
            }
        }
        .frame(width: M.stepMark, height: M.stepMark)
        .accessibilityHidden(true)
    }
}

/// One item of the first launch's copy (`PiImportStepRow(item, step)`): the title over its detail, and at the right a
/// count once it is done, "Copying" while it is the live one, "Not copied" when it failed. A pending one is dimmed.
public struct SHImportStepRow: View, Equatable {
    let title: String
    let detail: String?
    let count: String?
    let state: SHStepState

    public init(_ title: String, detail: String? = nil, count: String? = nil, state: SHStepState) {
        self.title = title
        self.detail = detail
        self.count = count
        self.state = state
    }

    public var body: some View {
        let sh = Color.sh
        let M = SHPiSignInMetrics.self
        HStack(alignment: .center, spacing: SH.Space.xl) {
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(title)
                    .font(.shSans(M.stepTitleSize))
                    .shShimmer(active: state == .now)
                    .foregroundStyle(state == .pending ? sh.textTertiary : sh.textPrimary)
                if let detail {
                    Text(detail)
                        .font(.shSans(M.stepDetailSize))
                        .foregroundStyle(state == .failed ? sh.failed : sh.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let word = right {
                Text(word)
                    .font(.shSans(M.stepTitleSize))
                    .foregroundStyle(state == .failed ? sh.failed : state == .now ? sh.textPrimary : sh.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.vertical, M.stepVertical)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { SHHairline(color: sh.lineStrong, width: SHSettingsNavMetrics.borderWidth) }
        .shAnimation(.content, value: state)
        .accessibilityElement(children: .combine)
        .accessibilityValue(Self.word(state))
    }

    private var right: String? {
        switch state {
        case .done: count
        case .now: "Copying"
        case .failed: "Not copied"
        case .pending: nil
        }
    }

    static func word(_ state: SHStepState) -> String {
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
public struct SHImportSummary: View {
    public struct Part: Equatable, Sendable {
        public var count: Int?
        public var words: String
        /// A mono value after the words ("default model `claude-opus`").
        public var value: String?
        /// Joined to the part before with a comma, not "·" ("instructions, 12 skills, 5 prompts").
        public var comma: Bool

        public init(_ words: String, count: Int? = nil, value: String? = nil, comma: Bool = false) {
            self.count = count
            self.words = words
            self.value = value
            self.comma = comma
        }
    }

    let parts: [Part]
    let size: CGFloat
    let quiet: Bool

    /// `quiet` draws it smaller and tertiary (Something missing's line under the card).
    public init(_ parts: [Part], size: CGFloat = SHPiSignInMetrics.sheetSubtitleSize, quiet: Bool = false) {
        self.parts = parts
        self.size = size
        self.quiet = quiet
    }

    public var body: some View {
        text
            .font(.shSans(size))
            .lineSpacing(size * (SHPiSignInMetrics.summaryLineHeight - 1.2))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var text: Text {
        let sh = Color.sh
        let rest = quiet ? sh.textTertiary : sh.textSecondary
        var result = Text("")
        for (index, part) in parts.enumerated() {
            if index > 0 { result = result + (part.comma ? Text(", ").foregroundColor(rest) : Text(" · ").foregroundColor(sh.textTertiary)) }
            if let count = part.count {
                result = result + Text("\(count)").fontWeight(.semibold).foregroundColor(sh.textPrimary) + Text(" ")
            }
            result = result + Text(part.words).foregroundColor(rest)
            if let value = part.value {
                result = result + Text(" ") + Text(value).font(.shMono(size - 0.5)).foregroundColor(sh.textPrimary)
            }
        }
        return result
    }
}

/// A provider that still needs a sign-in (`PiImportSignInRow(provider)`): its badge, name, why,
/// and Sign in; once signed in, a check and "Signed in".
public struct SHImportSignInRow: View {
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
        let sh = Color.sh
        let M = SHPiSignInMetrics.self
        HStack(spacing: SH.Space.xl) {
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(name).font(.shSans(M.stepTitleSize)).foregroundStyle(sh.textPrimary)
                Text(signedIn ? "Signed in" : signingIn ? "Signing in…" : detail)
                    .font(.shSans(M.stepDetailSize))
                    .shShimmer(active: signingIn)
                    .foregroundStyle(signedIn ? sh.done : sh.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if signedIn {
                Text("Signed in").font(.shSans(M.stepTitleSize)).foregroundStyle(sh.textSecondary)
            } else {
                Button("Sign in", action: signIn)
                    .buttonStyle(.sh(.secondary, size: .s))
                    .shControlScale(.settings)
                    .disabled(signingIn)
                    .accessibilityLabel("Sign in to \(name)")
            }
        }
        .padding(.vertical, M.stepVertical)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { SHHairline(color: sh.lineStrong, width: SHSettingsNavMetrics.borderWidth) }
        .shAnimation(.content, value: signedIn)
    }
}

/// A new user's choice (PiImportNew): its name over its plan and a chevron, a row in the list.
public struct SHSignInChoiceTile: View {
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
        let sh = Color.sh
        let M = SHPiSignInMetrics.self
        HStack(spacing: SH.Space.xl) {
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(title).font(.shSans(M.stepTitleSize)).foregroundStyle(sh.textPrimary)
                Text(detail).font(.shSans(M.stepDetailSize)).foregroundStyle(sh.textTertiary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right").font(.shSans(11, .medium)).foregroundStyle(sh.textTertiary)
        }
        .padding(.vertical, M.stepVertical)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? sh.bgHover : Color.clear)
        .overlay(alignment: .bottom) { SHHairline(color: sh.lineStrong, width: SHSettingsNavMetrics.borderWidth) }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .shAnimation(.hover, value: hovering)
    }
}

/// One step of a sign-in (`SignInSheet`): its title (shimmering while it's the live one) with a note under it, and
/// the step's state in a word at the right: Done, Now, Next, or Failed. Nothing spins, nothing ticks.
public struct SHSignInStepRow: View {
    let title: String
    let note: String?
    let state: SHStepState

    public init(_ title: String, note: String? = nil, state: SHStepState) {
        self.title = title
        self.note = note
        self.state = state
    }

    public var body: some View {
        let sh = Color.sh
        let M = SHPiSignInMetrics.self
        HStack(alignment: .top, spacing: M.stepGap) {
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(title)
                    .font(.shSans(M.stepTitleSize, state == .now ? .medium : .regular))
                    .shShimmer(active: state == .now)
                    .foregroundStyle(state == .pending ? sh.textTertiary : sh.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let note {
                    Text(note)
                        .font(state == .failed ? .shMono(M.stepDetailSize) : .shSans(M.stepDetailSize))
                        .foregroundStyle(state == .failed ? sh.failed : sh.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(Self.word(state))
                .font(.shSans(M.stepWordSize, state == .now || state == .failed ? .medium : .regular))
                .foregroundStyle(state == .now ? sh.textPrimary : state == .failed ? sh.failed : sh.textTertiary)
                .fixedSize()
        }
        .padding(.vertical, M.stepVertical)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { SHHairline(color: sh.lineStrong, width: SHSettingsNavMetrics.borderWidth) }
        .accessibilityElement(children: .combine)
        .accessibilityValue(Self.word(state))
    }

    static func word(_ state: SHStepState) -> String {
        switch state {
        case .done: "Done"
        case .now: "Now"
        case .pending: "Next"
        case .failed: "Failed"
        }
    }
}

/// The sign-in's steps: a rule above them, each step over its own rule.
public struct SHSignInSteps<Content: View>: View {
    let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { SHHairline(color: Color.sh.lineStrong, width: SHSettingsNavMetrics.borderWidth) }
    }
}

/// A device sign-in's code, large: mono 26/600, tracked.
public struct SHDeviceCode: View {
    let code: String
    let dimmed: Bool

    public init(_ code: String, dimmed: Bool = false) {
        self.code = code
        self.dimmed = dimmed
    }

    public var body: some View {
        let M = SHPiSignInMetrics.self
        Text(code)
            .font(.shMono(M.deviceCodeSize, .semibold))
            .tracking(M.deviceCodeSize * M.deviceCodeTracking)
            .foregroundStyle(dimmed ? Color.sh.textTertiary : Color.sh.textPrimary)
            .textSelection(.enabled)
            .accessibilityLabel("Code \(code.map(String.init).joined(separator: " "))")
    }
}

/// The box a device code sits in with its actions under it: `bgHover`, radius 12, the contents centered 10pt apart.
public struct SHDeviceCodeBox<Content: View>: View {
    let content: Content

    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        let M = SHPiSignInMetrics.self
        VStack(spacing: SH.Space.m + SH.Space.xxs) { content }
            .frame(maxWidth: .infinity)
            .padding(.top, M.deviceCodeTop)
            .padding(.bottom, M.deviceCodeBottom)
            .background(Color.sh.bgHover, in: RoundedRectangle(cornerRadius: M.deviceCodeRadius))
    }
}

/// What failed, in a `failed` box: a line in `textPrimary` (a path in mono, or a title) and the
/// reason under it.
public struct SHFailureBox: View {
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
        let sh = Color.sh
        let M = SHPiSignInMetrics.self
        VStack(alignment: .leading, spacing: SH.Space.xxs) {
            Text(title)
                .font(monoTitle ? .shMono(M.stepDetailSize) : .shSans(M.stepTitleSize, .medium))
                .foregroundStyle(sh.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .font(monoDetail ? .shMono(M.stepDetailSize) : .shSans(M.stepTitleSize))
                    .foregroundStyle(monoDetail ? sh.failed : sh.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .textSelection(.enabled)
        .padding(.vertical, 10)
        .padding(.horizontal, SH.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(sh.bgHover, in: RoundedRectangle(cornerRadius: M.failureRadius))
        .overlay(alignment: .leading) { Rectangle().fill(sh.failed).frame(width: M.failureBar) }
        .clipShape(RoundedRectangle(cornerRadius: M.failureRadius))
    }
}

/// A note in a quiet card: a glyph, then its text and an optional link under it.
public struct SHNoteCard<Text_: View>: View {
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
        let sh = Color.sh
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: glyph).font(.shSans(13)).foregroundStyle(sh.textSecondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SH.Space.xs) {
                text
                if let link, let action {
                    Button(link, action: action).buttonStyle(.shLink)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, SH.Space.l)
        .background(sh.bgSunken, in: RoundedRectangle(cornerRadius: 9))
        .shBorder(sh.lineSubtle, radius: 9)
    }
}

/// A field's label over it: 11.5/500 `textSecondary`, 6 above.
public struct SHFieldLabel: View {
    let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(.sh(.caption, weight: .semibold))
            .foregroundStyle(Color.sh.textSecondary)
    }
}
