import SwiftUI

// Settings ▸ Pi ▸ From your pi (SettingsPiFromPi, SettingsPiExtensions): what came over, each
// with Re-import, and the user's extensions with their switches.

/// How Shepherd's copy of an item stands (`ReimportRow(item)`).
public enum SHFreshness: Equatable, Sendable {
    case same
    case newer
    case changed
    case reimporting
    case reimported

    var word: String {
        switch self {
        case .same: "Same as your pi"
        case .newer: "Newer in your pi"
        case .changed: "Changed here"
        case .reimporting: "Re-importing"
        case .reimported: "Re-imported just now"
        }
    }

    /// Newer and Changed make Re-import a real button; Same keeps it quiet.
    var differs: Bool { self == .newer || self == .changed }
}

/// One item that came over, with Re-import (`ReimportRow(item)`): its badge, title and detail
/// (the key masked, a path in mono), a second line saying why it differs, and its freshness.
public struct SHReimportRow: View {
    public struct Detail: Equatable, Sendable {
        public var text: String
        public var mono: Bool
        public init(_ text: String, mono: Bool = false) {
            self.text = text
            self.mono = mono
        }
    }

    let title: String
    let badge: String?
    let detail: [Detail]
    let why: String?
    let freshness: SHFreshness?
    let problem: String?
    let reimport: (() -> Void)?

    public init(_ title: String, badge: String? = nil, detail: [Detail] = [], why: String? = nil, freshness: SHFreshness?,
                problem: String? = nil, reimport: (() -> Void)?) {
        self.title = title
        self.badge = badge
        self.detail = detail
        self.why = why
        self.freshness = freshness
        self.problem = problem
        self.reimport = reimport
    }

    public var body: some View {
        let sh = Color.sh
        let M = SHPiSignInMetrics.self
        HStack(spacing: M.rowGap) {
            if let badge { SHProviderBadge(badge) }
            VStack(alignment: .leading, spacing: M.lineGap) {
                Text(title).font(.shSans(M.nameSize, .medium)).foregroundStyle(sh.textPrimary)
                if !detail.isEmpty {
                    HStack(spacing: SH.Space.xs) {
                        ForEach(Array(detail.enumerated()), id: \.offset) { _, part in
                            Text(part.text)
                                .font(part.mono ? .shMono(M.statusSmallMonoSize) : .shSans(M.statusSize))
                                .foregroundStyle(part.mono ? sh.textPrimary : sh.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                if let why {
                    Text(why).font(.shSans(M.stepDetailSize)).foregroundStyle(sh.textTertiary).fixedSize(horizontal: false, vertical: true)
                }
                if let problem { SHInlineProblem(problem).shTransition(.disclosure) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let freshness {
                Text(freshness.word)
                    .font(.shSans(SHTextStyle.caption.size))
                    .shShimmer(active: freshness == .reimporting)
                    .foregroundStyle(color(freshness))
                    .fixedSize()
            }
            if let reimport {
                Button("Re-import", action: reimport)
                    .buttonStyle(.sh(freshness?.differs == true ? .secondary : .ghost, size: .s))
                    .disabled(freshness == .reimporting)
                    .shControlScale(.standard)
                    .accessibilityLabel("Re-import \(title.lowercased()) from your pi")
            }
        }
        .padding(.vertical, M.rowVertical)
        .padding(.horizontal, M.rowSides)
        .frame(maxWidth: .infinity, alignment: .leading)
        .shAnimation(.content, value: freshness)
        .shAnimation(.disclosure, value: problem)
    }

    private func color(_ freshness: SHFreshness) -> Color {
        switch freshness {
        case .same: .sh.textTertiary
        case .newer: .sh.lanternText
        case .changed: .sh.textSecondary
        case .reimporting: .sh.textSecondary
        case .reimported: .sh.done
        }
    }
}

/// A sub-label inside a card ("Logins", "Settings"): 11/600 caps `textTertiary`.
public struct SHCardLabel: View {
    let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text.uppercased())
            .font(.shSans(11, .semibold))
            .tracking(11 * 0.06)
            .foregroundStyle(Color.sh.textTertiary)
            .padding(.horizontal, SH.Space.xl)
            .padding(.top, 10)
            .padding(.bottom, SH.Space.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One of the user's extensions (`ExtensionRow(extension)`): off by default; on adds the
/// full-access note; failed keeps the switch on and says why it didn't load.
public struct SHExtensionRow: View {
    public enum Status: Equatable, Sendable {
        case off
        case on
        /// pi's reason, and the lines it wrote.
        case failed(String, lines: [String])
    }

    let name: String
    let path: String
    let summary: String?
    let state: Status
    let isOn: Binding<Bool>
    let tryAgain: () -> Void
    @State private var showsLog = false

    public init(_ name: String, path: String, summary: String?, state: Status, isOn: Binding<Bool>, tryAgain: @escaping () -> Void) {
        self.name = name
        self.path = path
        self.summary = summary
        self.state = state
        self.isOn = isOn
        self.tryAgain = tryAgain
    }

    public var body: some View {
        let sh = Color.sh
        let M = SHPiSignInMetrics.self
        HStack(alignment: .top, spacing: M.rowGap) {
            VStack(alignment: .leading, spacing: M.lineGap) {
                HStack(spacing: SH.Space.m) {
                    Text(name).font(.shMono(13, .medium)).foregroundStyle(sh.textPrimary)
                    Text(path).font(.shMono(M.statusSmallMonoSize)).foregroundStyle(sh.textTertiary).lineLimit(1).truncationMode(.middle)
                }
                if let summary, !summary.isEmpty {
                    Text(summary).font(.shSans(M.statusSize)).foregroundStyle(sh.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
                switch state {
                case .off:
                    EmptyView()
                case .on:
                    HStack(alignment: .firstTextBaseline, spacing: SH.Space.s) {
                        Image(systemName: "exclamationmark.shield").font(.shSans(M.noteSize - 0.5)).accessibilityHidden(true)
                        Text("Runs with full access to your files, shell and network, like it does in your terminal. New agents load it; running ones on /reload.")
                            .font(.shSans(M.noteSize))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(sh.textTertiary)
                    .padding(.top, SH.Space.xxs)
                    .shTransition(.disclosure)
                case .failed(let reason, let lines):
                    VStack(alignment: .leading, spacing: SH.Space.s) {
                        HStack(alignment: .firstTextBaseline, spacing: SH.Space.s) {
                            Text("Didn’t load:").font(.shSans(M.statusSize, .medium)).foregroundStyle(sh.failed)
                            Text(reason).font(.shMono(M.statusSmallMonoSize)).foregroundStyle(sh.textPrimary)
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                        HStack(spacing: SH.Space.s) {
                            Button("Try again", action: tryAgain).buttonStyle(.sh(.secondary, size: .s))
                            if !lines.isEmpty {
                                Button(showsLog ? "Hide log" : "Show log") { showsLog.toggle() }.buttonStyle(.sh(.ghost, size: .s))
                            }
                        }
                        .shControlScale(.standard)
                        if showsLog {
                            Text(lines.joined(separator: "\n"))
                                .font(.shMono(11))
                                .foregroundStyle(sh.textSecondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(SH.Space.m)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(sh.bgSunken, in: RoundedRectangle(cornerRadius: SH.Radius.s))
                                .shTransition(.disclosure)
                        }
                    }
                    .padding(.top, SH.Space.xxs)
                    .shTransition(.disclosure)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(name, isOn: isOn).toggleStyle(.shSwitch).labelsHidden()
        }
        .padding(.vertical, M.rowVertical)
        .padding(.horizontal, M.rowSides)
        .frame(maxWidth: .infinity, alignment: .leading)
        .shAnimation(.disclosure, value: state)
        .shAnimation(.disclosure, value: showsLog)
    }
}
