import SwiftUI

/// The measures of a provider's saved accounts, under its row in Settings ▸ Pi ▸ Sign-in.
public enum SHPiAccountMetrics {
    /// The accounts line up with the provider's name: the row's side, its badge, the gap after it.
    public static let inset: CGFloat = SHPiSignInMetrics.rowSides + SHPiSignInMetrics.badge + SHPiSignInMetrics.rowGap
    public static let nameSize: CGFloat = 13
}

/// How a saved account stands.
public struct SHAccountState: Equatable, Sendable {
    /// The account in pi's auth.json: agents use it.
    public var active: Bool
    /// "3:42 PM": rotation skips it until then.
    public var limitedUntil: String?

    public init(active: Bool, limitedUntil: String? = nil) {
        self.active = active
        self.limitedUntil = limitedUntil
    }
}

/// One saved account under its provider: a dot, its name, "Active", "Limited until 3:42 PM",
/// then its actions (Use, ⋯). Compact: 6pt above and below, inset to the provider's name.
public struct SHProviderAccountRow<Trailing: View>: View {
    let name: String
    let state: SHAccountState
    let trailing: Trailing

    public init(_ name: String, state: SHAccountState, @ViewBuilder trailing: () -> Trailing) {
        self.name = name
        self.state = state
        self.trailing = trailing()
    }

    public var body: some View {
        let sh = Color.sh
        let M = SHPiSignInMetrics.self
        HStack(spacing: SH.Space.m) {
            HStack(spacing: SH.Space.m) {
                SHProviderDot(state.limitedUntil != nil ? .attention : state.active ? .on : .off)
                Text(name)
                    .font(.shSans(SHPiAccountMetrics.nameSize, state.active ? .medium : .regular))
                    .foregroundStyle(sh.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(name)
                if state.active { SHTag("Active", foreground: sh.textPrimary) }
                if let until = state.limitedUntil {
                    Text("Limited until \(until)")
                        .font(.shSans(M.statusSize))
                        .foregroundStyle(sh.lanternText)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: SH.Space.l)
            HStack(spacing: SH.Space.xs) { trailing }
                .shControlScale(.standard)
                .fixedSize()
        }
        .padding(.vertical, SH.Space.s)
        .padding(.leading, SHPiAccountMetrics.inset)
        .padding(.trailing, M.rowSides)
        .frame(maxWidth: .infinity, alignment: .leading)
        .shAnimation(.content, value: state)
    }
}

/// "Switch accounts when one hits its limit", its switch, and what it does, under a provider's accounts.
public struct SHAccountRotationRow: View {
    let provider: String
    @Binding var isOn: Bool

    public init(provider: String, isOn: Binding<Bool>) {
        self.provider = provider
        self._isOn = isOn
    }

    static let title = "Switch accounts when one hits its limit"
    static let note = "Shepherd moves to the next account when a request is rate limited, skipping any account for an hour after it hits a limit. Check that your provider’s terms allow using several accounts."

    public var body: some View {
        let sh = Color.sh
        let M = SHPiSignInMetrics.self
        HStack(alignment: .top, spacing: SH.Space.xxl) {
            VStack(alignment: .leading, spacing: M.lineGap) {
                Text(Self.title)
                    .font(.shSans(SHPiAccountMetrics.nameSize))
                    .foregroundStyle(sh.textPrimary)
                Text(Self.note)
                    .font(.shSans(M.noteSize))
                    .foregroundStyle(sh.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityHidden(true)
            Toggle("\(Self.title) (\(provider))", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.shSwitch)
                .accessibilityHint(Self.note)
        }
        .padding(.top, SH.Space.m)
        .padding(.bottom, M.rowVertical)
        .padding(.leading, SHPiAccountMetrics.inset)
        .padding(.trailing, M.rowSides)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
