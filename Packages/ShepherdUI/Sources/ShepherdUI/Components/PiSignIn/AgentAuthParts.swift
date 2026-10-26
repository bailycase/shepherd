import SwiftUI

// An agent's thread while the first launch's copy holds it, and once it can't start because it
// isn't signed in (PiAuthStates, PiImportProgress, AgentNotSignedIn).

/// "Waiting to continue" (`AgentWaitingLine(restoredAt:)`): one static line at the end of a
/// restored agent's thread while the first launch's copy holds it.
public struct SHAgentWaitingLine: View, Equatable {
    let message: String
    let trailing: String?

    public init(message: String, trailing: String? = nil) {
        self.message = message
        self.trailing = trailing
    }

    public var body: some View {
        let sh = Color.sh
        HStack(spacing: 10) {
            Image(systemName: "clock")
                .font(.shSans(14))
                .foregroundStyle(sh.textSecondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text("Waiting to continue").font(.shSans(13, .medium)).foregroundStyle(sh.textPrimary)
                Text(message)
                    .font(.shSans(SHPiSignInMetrics.statusSize))
                    .foregroundStyle(sh.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let trailing {
                Text(trailing).font(.shMono(SHPiSignInMetrics.timeSize)).foregroundStyle(sh.textTertiary).fixedSize()
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(sh.bgSunken, in: RoundedRectangle(cornerRadius: SHPiSignInMetrics.cardRadius))
        .shBorder(sh.lineSubtle, radius: SHPiSignInMetrics.cardRadius)
        .accessibilityElement(children: .combine)
    }
}

/// "Not signed in to Anthropic" (`AgentNotSignedInCard(provider:)`): a lantern card at the end of
/// the thread with Sign in to <provider> and Use another model.
public struct SHAgentNotSignedInCard<Models: View>: View {
    let provider: String
    let model: String?
    let reason: String
    let time: String?
    let signIn: () -> Void
    let models: Models?

    /// `reason` follows "This agent uses `model`." ("Anthropic’s sign-in was skipped when your pi
    /// came over, so the agent is waiting for you. Your message is kept."). `models` is Use another
    /// model's menu; nil leaves the button out.
    public init(provider: String, model: String?, reason: String, time: String? = nil, signIn: @escaping () -> Void,
                @ViewBuilder models: () -> Models) {
        self.provider = provider
        self.model = model
        self.reason = reason
        self.time = time
        self.signIn = signIn
        self.models = models()
    }

    public var body: some View {
        let sh = Color.sh
        let M = SHPiSignInMetrics.self
        VStack(alignment: .leading, spacing: SH.Space.l) {
            HStack(alignment: .top, spacing: SH.Space.l) {
                Image(systemName: "key")
                    .font(.shSans(M.cardGlyph - 3, .medium))
                    .foregroundStyle(sh.lanternText)
                    .frame(width: M.cardTile, height: M.cardTile)
                    .background(sh.lanternTint, in: RoundedRectangle(cornerRadius: M.cardRadius))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: M.lineGap) {
                    Text("Not signed in to \(provider)")
                        .font(.shSans(M.cardTitleSize, .semibold))
                        .foregroundStyle(sh.textPrimary)
                    message
                        .shText(size: 13, lineHeight: 1.5)
                        .foregroundStyle(sh.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(.top, SH.Space.xxs)
                .frame(maxWidth: .infinity, alignment: .leading)
                if let time {
                    Text(time).font(.shMono(M.timeSize)).foregroundStyle(sh.textTertiary).fixedSize()
                }
            }
            HStack(spacing: SH.Space.m) {
                Button(action: signIn) { Label("Sign in to \(provider)", systemImage: "key") }
                    .buttonStyle(.sh(.primary, size: .s))
                if let models {
                    Menu { models } label: {
                        Label("Use another model", systemImage: "arrow.triangle.swap")
                            .font(.shSans(12, .medium))
                            .foregroundStyle(sh.textSecondary)
                            .padding(.horizontal, SH.Space.m)
                            .frame(height: SH.Height.controlS)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
            .padding(.leading, M.cardTile + SH.Space.l)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, SH.Space.xl)
        .background(sh.lantern.opacity(M.cardFillOpacity), in: RoundedRectangle(cornerRadius: M.cardRadius))
        .shBorder(sh.lantern.opacity(M.cardLineOpacity), radius: M.cardRadius)
    }

    private var message: Text {
        guard let model else { return Text(reason) }
        return Text("This agent uses ") + Text(model).font(.shMono(12.5)).foregroundColor(Color.sh.textPrimary) + Text(". ") + Text(reason)
    }
}

extension SHAgentNotSignedInCard where Models == EmptyView {
    /// With no other model to offer.
    public init(provider: String, model: String?, reason: String, time: String? = nil, signIn: @escaping () -> Void) {
        self.provider = provider
        self.model = model
        self.reason = reason
        self.time = time
        self.signIn = signIn
        self.models = nil
    }
}
