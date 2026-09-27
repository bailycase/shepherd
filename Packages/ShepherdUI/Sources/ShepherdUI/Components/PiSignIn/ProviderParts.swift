import SwiftUI

/// The measures the sign-in surfaces draw (PiAuthStates, SettingsPiSignIn, the SignIn* and
/// PiImport* boards).
public enum NWPiSignInMetrics {
    public static let badge: CGFloat = 30
    public static let badgeSmall: CGFloat = 28
    public static let badgeLarge: CGFloat = 38
    public static let badgeRadius: CGFloat = 8
    public static let badgeTextSize: CGFloat = 11
    public static let rowVertical: CGFloat = 12
    public static let rowSides: CGFloat = 16
    public static let rowGap: CGFloat = 12
    public static let nameSize: CGFloat = 13.5
    public static let statusSize: CGFloat = 12.5
    public static let statusMonoSize: CGFloat = 12
    public static let statusSmallMonoSize: CGFloat = 11.5
    public static let noteSize: CGFloat = 11.5
    public static let lineGap: CGFloat = 3
    public static let dot: CGFloat = 7
    public static let dotStroke: CGFloat = 1.5
    public static let menuButton: CGFloat = 26
    public static let menuGlyph: CGFloat = 13
    public static let cardRadius: CGFloat = 10
    /// The sheets.
    public static let sheetWidth: CGFloat = 500
    public static let importWidth: CGFloat = 540
    public static let importWideWidth: CGFloat = 600
    public static let sheetTile: CGFloat = 38
    public static let sheetTileRadius: CGFloat = 10
    public static let sheetTitleSize: CGFloat = 17
    public static let sheetSubtitleSize: CGFloat = 13
    public static let sheetInset: CGFloat = 22
    public static let sheetTrailing: CGFloat = 20
    public static let closeButton: CGFloat = 28
    public static let footerTop: CGFloat = 14
    public static let footerBottom: CGFloat = 16
    public static let footerTrailing: CGFloat = 18
    /// A step: its mark, its least height, its words.
    public static let stepMark: CGFloat = 18
    public static let stepMinHeight: CGFloat = 40
    public static let stepTitleSize: CGFloat = 13
    public static let stepDetailSize: CGFloat = 12
    public static let stepCountSize: CGFloat = 11.5
    public static let deviceCodeSize: CGFloat = 26
    public static let deviceCodeTracking: CGFloat = 0.12
    public static let cardTitleSize: CGFloat = 14
    public static let cardTile: CGFloat = 30
    public static let cardGlyph: CGFloat = 18
    public static let cardLineOpacity: Double = 0.28
    public static let cardFillOpacity: Double = 0.05
    public static let failureFillOpacity: Double = 0.5
    public static let failureLineOpacity: Double = 0.25
    public static let summaryLineHeight: CGFloat = 1.7
    public static let timeSize: CGFloat = 11
    public static let fieldLabelSize: CGFloat = 11.5
}

/// A provider's monogram tile: "An", "Cx", "Gh" in Geist 11/600 `textSecondary`, on `bgRaised` in
/// a `lineStrong` line at radius 8.
public struct NWProviderBadge: View {
    let letters: String
    let size: CGFloat

    public init(_ letters: String, size: CGFloat = NWPiSignInMetrics.badge) {
        self.letters = letters
        self.size = size
    }

    public var body: some View {
        let nw = Color.nw
        Text(letters)
            .font(.nwSans(NWPiSignInMetrics.badgeTextSize, .semibold))
            .tracking(-0.1)
            .foregroundStyle(nw.textSecondary)
            .frame(width: size, height: size)
            .background(nw.bgRaised, in: RoundedRectangle(cornerRadius: NWPiSignInMetrics.badgeRadius))
            .nwBorder(nw.lineStrong, radius: NWPiSignInMetrics.badgeRadius)
            .accessibilityHidden(true)
    }
}

/// What a provider row's status line says: a dot, a word, then details after "·".
public struct NWProviderStatus: Equatable, Sendable {
    public enum Dot: Sendable {
        /// `done`, filled: signed in, a key, a variable.
        case on
        /// `lantern`, filled: expired.
        case attention
        /// A hollow `textTertiary` ring: not signed in, no key needed.
        case off
        /// A `running` ring with a dot: signing in.
        case live
    }

    public enum Tone: Sendable { case primary, secondary, tertiary, attention }

    public struct Part: Equatable, Sendable {
        public var text: String
        public var mono: Bool
        public var small: Bool
        public var tone: Tone
        /// Starts a new "·" group; false joins the part before (a key and its source label).
        public var separated: Bool
        /// Truncate in the middle: a command.
        public var middle: Bool

        public init(_ text: String, mono: Bool = false, small: Bool = false, tone: Tone = .secondary, separated: Bool = true,
                    middle: Bool = false) {
            self.text = text
            self.mono = mono
            self.small = small
            self.tone = tone
            self.separated = separated
            self.middle = middle
        }
    }

    public var dot: Dot
    public var word: String
    public var wordTone: Tone
    public var parts: [Part]
    /// The word shimmers (signing in).
    public var live: Bool

    public init(dot: Dot, word: String, wordTone: Tone = .primary, parts: [Part] = [], live: Bool = false) {
        self.dot = dot
        self.word = word
        self.wordTone = wordTone
        self.parts = parts
        self.live = live
    }
}

extension NWProviderStatus.Tone {
    @MainActor var color: Color {
        switch self {
        case .primary: .nw.textPrimary
        case .secondary: .nw.textSecondary
        case .tertiary: .nw.textTertiary
        case .attention: .nw.lanternText
        }
    }
}

/// Where a key comes from, after its mask (`NWKeySourceLabel`).
public enum NWKeySource: Equatable, Sendable {
    /// The key the import copied from the user's pi.
    case copiedFromYourPi
    /// A `$NAME` reference, read from the login shell when an agent starts.
    case variable(String)
    /// A `!command`, run when the key is first needed.
    case command(String)

    /// The status line's parts for it, joined to the key before them.
    public var parts: [NWProviderStatus.Part] {
        switch self {
        case .copiedFromYourPi: [.init("copied from your pi", tone: .tertiary, separated: false)]
        case .variable(let name): [.init("reads", tone: .tertiary, separated: false),
                                   .init("$" + name, mono: true, small: true, separated: false)]
        case .command(let command): [.init("runs a command", tone: .tertiary, separated: false),
                                     .init(command, mono: true, small: true, separated: false, middle: true)]
        }
    }
}

/// The dot at the head of a provider's status line.
public struct NWProviderDot: View {
    let dot: NWProviderStatus.Dot

    public init(_ dot: NWProviderStatus.Dot) {
        self.dot = dot
    }

    public var body: some View {
        let nw = Color.nw
        let M = NWPiSignInMetrics.self
        ZStack {
            switch dot {
            case .on: Circle().fill(nw.done)
            case .attention: Circle().fill(nw.lantern)
            case .off: Circle().strokeBorder(nw.textTertiary, lineWidth: M.dotStroke)
            case .live:
                Circle().strokeBorder(nw.running, lineWidth: M.dotStroke)
                Circle().fill(nw.running).padding(M.dotStroke + 0.5)
            }
        }
        .frame(width: M.dot, height: M.dot)
        .accessibilityHidden(true)
    }
}

/// A provider's one status line: the dot, the word, and its details, each group after "·".
public struct NWProviderStatusLine: View {
    let status: NWProviderStatus

    public init(_ status: NWProviderStatus) {
        self.status = status
    }

    public var body: some View {
        let nw = Color.nw
        let M = NWPiSignInMetrics.self
        HStack(spacing: NW.Space.s) {
            NWProviderDot(status.dot)
            Text(status.word)
                .font(.nwSans(M.statusSize))
                .nwShimmer(active: status.live)
                .foregroundStyle(status.wordTone.color)
                .lineLimit(1)
                .fixedSize()
            ForEach(Array(status.parts.enumerated()), id: \.offset) { _, part in
                if part.separated { Text("·").font(.nwSans(M.statusSize)).foregroundStyle(nw.textTertiary) }
                Text(part.text)
                    .font(part.mono ? .nwMono(part.small ? M.statusSmallMonoSize : M.statusMonoSize) : .nwSans(M.statusSize))
                    .foregroundStyle(part.tone.color)
                    .lineLimit(1)
                    .truncationMode(part.middle ? .middle : .tail)
                    .help(part.middle ? part.text : "")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// A key's source after its mask: "copied from your pi", "reads `$NAME`", "runs a command `…`".
public struct NWKeySourceLabel: View {
    let source: NWKeySource

    public init(_ source: NWKeySource) {
        self.source = source
    }

    public var body: some View {
        let M = NWPiSignInMetrics.self
        HStack(spacing: NW.Space.s) {
            ForEach(Array(source.parts.enumerated()), id: \.offset) { _, part in
                Text(part.text)
                    .font(part.mono ? .nwMono(M.statusSmallMonoSize) : .nwSans(M.statusSize))
                    .foregroundStyle(part.tone.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// "Signing in here and in your terminal pi can sign one of them out." Quiet: 11.5 `textTertiary`,
/// under Anthropic, OpenAI Codex, Kimi and Radius.
public struct NWSharedLoginNote: View {
    public init() {}

    public var body: some View {
        HStack(spacing: NW.Space.s) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.nwSans(NWPiSignInMetrics.noteSize - 1))
                .accessibilityHidden(true)
            Text("Signing in here and in your terminal pi can sign one of them out.")
                .font(.nwSans(NWPiSignInMetrics.noteSize))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Color.nw.textTertiary)
    }
}

/// The ⋯ button that opens a provider's menu: a 26pt circle, "More for Anthropic".
public struct NWProviderMenuButton<Items: View>: View {
    let name: String
    let items: Items
    @State private var hovering = false

    public init(for name: String, @ViewBuilder items: () -> Items) {
        self.name = name
        self.items = items()
    }

    public var body: some View {
        let nw = Color.nw
        let M = NWPiSignInMetrics.self
        Menu {
            items
        } label: {
            Image(systemName: "ellipsis")
                .font(.nwSans(M.menuGlyph, .medium))
                .foregroundStyle(nw.textSecondary)
                .frame(width: M.menuButton, height: M.menuButton)
                .background(hovering ? nw.bgHover : Color.clear, in: Circle())
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .nwAnimation(.hover, value: hovering)
        .accessibilityLabel("More for \(name)")
    }
}

/// One provider in Settings ▸ Pi ▸ Sign-in (`ProviderRow(provider, auth)`): its badge, its name
/// over its status line (and the shared-login note), its trailing action and ⋯ menu.
public struct NWProviderRow<Trailing: View>: View {
    let name: String
    let badge: String
    let mono: Bool
    let status: NWProviderStatus
    let sharedLoginNote: Bool
    let problem: String?
    let trailing: Trailing

    /// `mono` sets a custom provider's id as its title.
    public init(_ name: String, badge: String, mono: Bool = false, status: NWProviderStatus, sharedLoginNote: Bool = false,
                problem: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.name = name
        self.badge = badge
        self.mono = mono
        self.status = status
        self.sharedLoginNote = sharedLoginNote
        self.problem = problem
        self.trailing = trailing()
    }

    public var body: some View {
        let M = NWPiSignInMetrics.self
        HStack(alignment: .center, spacing: M.rowGap) {
            NWProviderBadge(badge)
            VStack(alignment: .leading, spacing: M.lineGap) {
                Text(name)
                    .font(mono ? .nwMono(M.nameSize - 0.5, .semibold) : .nwSans(M.nameSize, .medium))
                    .foregroundStyle(Color.nw.textPrimary)
                    .lineLimit(1)
                NWProviderStatusLine(status)
                if sharedLoginNote { NWSharedLoginNote() }
                if let problem {
                    NWInlineProblem(problem).nwTransition(.disclosure)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: NW.Space.xs) { trailing }
                .nwControlScale(.standard)
                .fixedSize()
        }
        .padding(.vertical, M.rowVertical)
        .padding(.horizontal, M.rowSides)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nwAnimation(.content, value: status)
        .nwAnimation(.disclosure, value: problem)
    }
}
