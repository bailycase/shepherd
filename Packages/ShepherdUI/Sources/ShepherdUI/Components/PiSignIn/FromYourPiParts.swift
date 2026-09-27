import SwiftUI

// Settings ▸ Pi ▸ From your pi (SettingsPiFromPi, SettingsPiExtensions): what came over, each
// with Re-import, and the user's extensions with their switches.

/// How Shepherd's copy of an item stands (`ReimportRow(item)`).
public enum NWFreshness: Equatable, Sendable {
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
public struct NWReimportRow: View {
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
    let freshness: NWFreshness?
    let problem: String?
    let reimport: (() -> Void)?

    public init(_ title: String, badge: String? = nil, detail: [Detail] = [], why: String? = nil, freshness: NWFreshness?,
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
        let nw = Color.nw
        let M = NWPiSignInMetrics.self
        HStack(spacing: M.rowGap) {
            if let badge { NWProviderBadge(badge) }
            VStack(alignment: .leading, spacing: M.lineGap) {
                Text(title).font(.nwSans(M.nameSize, .medium)).foregroundStyle(nw.textPrimary)
                if !detail.isEmpty {
                    HStack(spacing: NW.Space.xs) {
                        ForEach(Array(detail.enumerated()), id: \.offset) { _, part in
                            Text(part.text)
                                .font(part.mono ? .nwMono(M.statusSmallMonoSize) : .nwSans(M.statusSize))
                                .foregroundStyle(part.mono ? nw.textPrimary : nw.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                if let why {
                    Text(why).font(.nwSans(M.stepDetailSize)).foregroundStyle(nw.textTertiary).fixedSize(horizontal: false, vertical: true)
                }
                if let problem { NWInlineProblem(problem).nwTransition(.disclosure) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let freshness {
                Text(freshness.word)
                    .font(.nwSans(NWTextStyle.caption.size))
                    .nwShimmer(active: freshness == .reimporting)
                    .foregroundStyle(color(freshness))
                    .fixedSize()
            }
            if let reimport {
                Button("Re-import", action: reimport)
                    .buttonStyle(.nw(freshness?.differs == true ? .secondary : .ghost, size: .s))
                    .disabled(freshness == .reimporting)
                    .nwControlScale(.standard)
                    .accessibilityLabel("Re-import \(title.lowercased()) from your pi")
            }
        }
        .padding(.vertical, M.rowVertical)
        .padding(.horizontal, M.rowSides)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nwAnimation(.content, value: freshness)
        .nwAnimation(.disclosure, value: problem)
    }

    private func color(_ freshness: NWFreshness) -> Color {
        switch freshness {
        case .same: .nw.textTertiary
        case .newer: .nw.lanternText
        case .changed: .nw.textSecondary
        case .reimporting: .nw.textSecondary
        case .reimported: .nw.done
        }
    }
}

/// A sub-label inside a card ("Logins", "Settings"): 11/600 caps `textTertiary`.
public struct NWCardLabel: View {
    let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text.uppercased())
            .font(.nwSans(11, .semibold))
            .tracking(11 * 0.06)
            .foregroundStyle(Color.nw.textTertiary)
            .padding(.horizontal, NW.Space.xl)
            .padding(.top, 10)
            .padding(.bottom, NW.Space.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One of the user's extensions (`ExtensionRow(extension)`): off by default; on adds the
/// full-access note; failed keeps the switch on and says why it didn't load.
public struct NWExtensionRow: View {
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
        let nw = Color.nw
        let M = NWPiSignInMetrics.self
        HStack(alignment: .top, spacing: M.rowGap) {
            VStack(alignment: .leading, spacing: M.lineGap) {
                HStack(spacing: NW.Space.m) {
                    Text(name).font(.nwMono(13, .medium)).foregroundStyle(nw.textPrimary)
                    Text(path).font(.nwMono(M.statusSmallMonoSize)).foregroundStyle(nw.textTertiary).lineLimit(1).truncationMode(.middle)
                }
                if let summary, !summary.isEmpty {
                    Text(summary).font(.nwSans(M.statusSize)).foregroundStyle(nw.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
                switch state {
                case .off:
                    EmptyView()
                case .on:
                    HStack(alignment: .firstTextBaseline, spacing: NW.Space.s) {
                        Image(systemName: "exclamationmark.shield").font(.nwSans(M.noteSize - 0.5)).accessibilityHidden(true)
                        Text("Runs with full access to your files, shell and network, like it does in your terminal. New agents load it; running ones on /reload.")
                            .font(.nwSans(M.noteSize))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(nw.textTertiary)
                    .padding(.top, NW.Space.xxs)
                    .nwTransition(.disclosure)
                case .failed(let reason, let lines):
                    VStack(alignment: .leading, spacing: NW.Space.s) {
                        HStack(alignment: .firstTextBaseline, spacing: NW.Space.s) {
                            Text("Didn’t load:").font(.nwSans(M.statusSize, .medium)).foregroundStyle(nw.failed)
                            Text(reason).font(.nwMono(M.statusSmallMonoSize)).foregroundStyle(nw.textPrimary)
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                        HStack(spacing: NW.Space.s) {
                            Button("Try again", action: tryAgain).buttonStyle(.nw(.secondary, size: .s))
                            if !lines.isEmpty {
                                Button(showsLog ? "Hide log" : "Show log") { showsLog.toggle() }.buttonStyle(.nw(.ghost, size: .s))
                            }
                        }
                        .nwControlScale(.standard)
                        if showsLog {
                            Text(lines.joined(separator: "\n"))
                                .font(.nwMono(11))
                                .foregroundStyle(nw.textSecondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(NW.Space.m)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(nw.bgSunken, in: RoundedRectangle(cornerRadius: NW.Radius.s))
                                .nwTransition(.disclosure)
                        }
                    }
                    .padding(.top, NW.Space.xxs)
                    .nwTransition(.disclosure)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(name, isOn: isOn).toggleStyle(.nwSwitch).labelsHidden()
        }
        .padding(.vertical, M.rowVertical)
        .padding(.horizontal, M.rowSides)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nwAnimation(.disclosure, value: state)
        .nwAnimation(.disclosure, value: showsLog)
    }
}
