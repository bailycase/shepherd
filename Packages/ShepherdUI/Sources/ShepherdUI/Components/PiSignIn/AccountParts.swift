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

/// One saved account under its provider: its name (and email), "Active" or "Limited until 3:42 PM"
/// as a pill, its actions (Use, ⋯), and under them its own usage on one line. The active account
/// sits on `bgSunken`. Inset to the provider's name.
public struct SHProviderAccountRow<Trailing: View>: View {
    let name: String
    let detail: String?
    let state: SHAccountState
    let usage: [SHUsageWindow]
    let asOf: String?
    let trailing: Trailing

    /// `detail` (the account's email beside a name the user chose) trails the name in `textTertiary`;
    /// `asOf` ("as of 2 hr. ago") follows an old reading of `usage`.
    public init(_ name: String, detail: String? = nil, state: SHAccountState, usage: [SHUsageWindow] = [], asOf: String? = nil,
                @ViewBuilder trailing: () -> Trailing) {
        self.name = name
        self.detail = detail
        self.state = state
        self.usage = usage
        self.asOf = asOf
        self.trailing = trailing()
    }

    public var body: some View {
        let sh = Color.sh
        let M = SHPiSignInMetrics.self
        VStack(alignment: .leading, spacing: M.lineGap) {
            HStack(spacing: SH.Space.m) {
                HStack(spacing: SH.Space.m) {
                    Text(name)
                        .font(.shSans(SHPiAccountMetrics.nameSize, state.active ? .medium : .regular))
                        .foregroundStyle(sh.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                        .help(name)
                    if let detail {
                        Text(detail)
                            .font(.shSans(M.statusSize))
                            .foregroundStyle(sh.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if state.active { SHStatusPill(.done, label: "Active").fixedSize() }
                    if let until = state.limitedUntil { SHStatusPill(.attention, label: "Limited until \(until)").fixedSize() }
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: SH.Space.l)
                HStack(spacing: SH.Space.xs) { trailing }
                    .shControlScale(.standard)
                    .fixedSize()
            }
            .frame(minHeight: M.menuButton)
            if !usage.isEmpty { SHUsageStrip(usage, asOf: asOf) }
        }
        .padding(.vertical, SH.Space.s)
        .padding(.horizontal, SH.Space.m)
        .background(state.active ? sh.bgSunken : .clear, in: RoundedRectangle(cornerRadius: SH.Radius.s))
        .padding(.leading, SHPiAccountMetrics.inset - SH.Space.m)
        .padding(.trailing, M.rowSides - SH.Space.m)
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
    static let note = "An account that hits a limit sits out for an hour. Check that your provider’s terms allow several accounts."

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
        .padding(.vertical, M.rowVertical)
        .padding(.leading, SHPiAccountMetrics.inset)
        .padding(.trailing, M.rowSides)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
